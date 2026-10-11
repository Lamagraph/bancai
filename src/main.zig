const std = @import("std");
const Io = std.Io;

const AST = @import("ast");
const SharedRuntime = @import("shared_runtime");
const VM = @import("vm");

const clap = @import("clap");

const help =
    \\-h, --help                     Display this help and exit.
    \\-t, --threads <usize>          Specify number of threads to be run on (this does not work yet).
    \\-m, --heap-size <usize>        Specify the initial size of the heap. Default: 1024
    \\-f, --filepath <str>           Specify file to be interpreted. Default: ./tests/list_sorting.in
    \\-w, --warmup                   In multiThread mode, have the main core take a first pass at reducing equations before handing off to the worker cores.
    \\
;
const params = clap.parseParamsComptime(help);

const DEFAULT_HEAP_SIZE: usize = 1024;
const DEFAULT_CORES_NUM: usize = 1;

// TODO: make it less cramped
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var sthreaded = Io.Threaded.init_single_threaded;
    defer sthreaded.deinit();
    const io = sthreaded.io();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        var stdio = std.Io.File.stdin().writer(io, &.{});
        try stdio.interface.print("{s}", .{help});
        return;
    }

    if (res.args.threads) |n|
        std.debug.print("you specified -t {}, but it is not yet developed.\n", .{n});
    const filepath = res.args.filepath orelse {
        std.debug.print("File not specified. \nConsider using \"--help\".\n", .{});
        std.process.exit(1);
    };

    const contents = try Io.Dir.readFileAllocOptions(
        Io.Dir.cwd(),
        io,
        filepath,
        gpa,
        .unlimited,
        .of(u8),
        0,
    );
    defer gpa.free(contents);

    const tokens = try AST.Lexer.tokenize(gpa, contents);

    const main_file = SharedRuntime.File{
        .path = filepath,
        .contents = contents,
        .tokens = tokens,
    };

    defer gpa.free(tokens);
    var parser = try AST.Parser.init(tokens, gpa, std.heap.page_allocator);
    defer parser.deinit(gpa);
    const program = parser.parseProgram() catch |err| {
        if (err == error.ErrorDuringParsing) {
            const prettyLines = try parser.err.?.getPrettyLine(&parser, contents);
            const messageLine = try parser.err.?.messageLine(&parser);
            std.debug.print("{s}\n\n{s}\n{s}\n", .{ messageLine, prettyLines[0], prettyLines[1] });
            std.process.exit(1);
        }
        return err;
    };

    var runtime = try SharedRuntime.init(gpa, std.heap.page_allocator, main_file);
    defer runtime.deinit();

    const vm_cfg: VM.Config = .{
        .heap_size = res.args.@"heap-size" orelse DEFAULT_HEAP_SIZE,
        .cores_num = DEFAULT_CORES_NUM,
        .warmup = res.args.warmup != 0,
    };

    var vm = try VM.init(&runtime, vm_cfg);
    defer vm.deinit();

    vm.runProgram(program) catch |err| {
        if (err == error.CompilationError or err == error.ErrorDuringParsing) {
            std.process.exit(1);
        }

        return err;
    };
}

test "test modules" {
    _ = .{
        AST,
        SharedRuntime,
        @import("compilation"),
        @import("printing"),
        VM,
    };
}

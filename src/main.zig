const std = @import("std");
const Io = std.Io;

const AST = @import("ast");
const SharedRuntime = @import("shared_runtime");
const VM = @import("vm");
const Profiler = @import("profiler");
const Config = @import("config");

const clap = @import("clap");

const profile_heap_structure = Config.heap == .basic and Config.debug_printing.benchmark and Config.debug_printing.print_memory_usage;

const interaction_profiler = if (profile_heap_structure) "--profiling-window <usize>     Specify window between profiling prints." else "";

const help =
    \\-h, --help                     Display this help and exit.
    \\-t, --threads <usize>          Specify number of threads to be run on (this does not work yet).
    \\-m, --heap-size <usize>        Specify the initial size of the heap. Default: 1024
    \\-f, --filepath <str>           Specify file to be interpreted. Default: ./tests/list_sorting.in
    \\-w, --warmup                   In multiThread mode, have the master core take a first pass at reducing equations before handing off to the worker cores.
    \\
++ interaction_profiler ++ "\n";
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

    const profiling_window: ?usize = profiling_window: {
        if (profile_heap_structure) {
            break :profiling_window res.args.@"profiling-window";
        } else break :profiling_window null;
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

    var vm_profiler: Profiler = .init(&runtime, profiling_window);
    defer vm_profiler.deinit();

    var vm = try VM.init(&runtime, vm_cfg, &vm_profiler);
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
        Profiler,
        VM,
    };
}

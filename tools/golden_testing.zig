const std = @import("std");

const assert = std.debug.assert;

const stdout_tests_path = "tests";
const stderr_tests_path = "tests_errors";
const golden_subdir = "golden";
const nested_subdir = "nested";
const golden_ext = ".golden";

const concurrent_thread_counts = [_][]const u8{ "2", "4", "8" };
const concurrent_repeats = 20;

const single_run = [_][]const []const u8{&.{}};

/// Extra arguments for every run of a stdout test: one single-threaded run, then
/// multi-threaded ones. Each run must produce the golden output, which is
/// generated single-threaded.
const stdout_runs = runs: {
    var runs: [1 + concurrent_repeats * concurrent_thread_counts.len][]const []const u8 = undefined;
    runs[0] = &.{};
    for (0..concurrent_repeats) |repeat| {
        for (concurrent_thread_counts, 0..) |threads, idx| {
            runs[1 + repeat * concurrent_thread_counts.len + idx] = &.{ "-t", threads };
        }
    }
    break :runs runs;
};

pub const Lines = struct {
    lines: [][]const u8,

    pub fn init(gpa: std.mem.Allocator, contents: []const u8) !Lines {
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(gpa);

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            try list.append(gpa, line);
        }

        return .{
            .lines = try list.toOwnedSlice(gpa),
        };
    }

    pub fn deinit(self: Lines, gpa: std.mem.Allocator) void {
        gpa.free(self.lines);
    }

    test "single line" {
        const gpa = std.testing.allocator;
        const file = "hello world";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit(gpa);

        try std.testing.expectEqualStrings("hello world", lines.lines[0]);
    }

    test "multiple lines" {
        const gpa = std.testing.allocator;
        const file = "hello\nworld\n";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit(gpa);

        try std.testing.expectEqualStrings("hello", lines.lines[0]);
        try std.testing.expectEqualStrings("world", lines.lines[1]);
        try std.testing.expectEqualStrings("", lines.lines[2]);
    }
};

const Command = struct {
    args: []const []const u8,
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: Stream,
};

const InvocationResult = union(enum) {
    zig_error: std.process.RunError,
    unsuccessful_termination: struct { term: std.process.Child.Term, stderr: []u8 },
    stderr_on_stdout_only: []u8,
    success: []u8,

    fn stringFailure(self: InvocationResult, command: []const []const u8, gpa: std.mem.Allocator) ![]u8 {
        const command_str = try concatWithSep(gpa, command, " ");
        defer gpa.free(command_str);

        const err_str = switch (self) {
            .zig_error => |zig_error| try std.fmt.allocPrint(gpa, "returned zig error {s}.", .{@errorName(zig_error)}),
            .unsuccessful_termination => |unsuccessful_termination| err_str: {
                const term_str = try stringTermination(gpa, unsuccessful_termination.term);
                defer gpa.free(term_str);

                if (unsuccessful_termination.stderr.len != 0) {
                    break :err_str try std.fmt.allocPrint(gpa, "{s}. Stderr output:\n{s}", .{ term_str, unsuccessful_termination.stderr });
                } else {
                    break :err_str try std.fmt.allocPrint(gpa, "{s}. No stderr output.", .{term_str});
                }
            },
            .stderr_on_stdout_only => |stderr| try std.fmt.allocPrint(
                gpa,
                "collected stderr output when only stdout expected. Stderr output:\n{s}",
                .{stderr},
            ),
            .success => unreachable,
        };
        defer gpa.free(err_str);

        return try std.fmt.allocPrint(gpa, "Invocation failure: command {{ {s} }} {s}\n", .{ command_str, err_str });
    }
};

/// Gets command name and its arguments as an array and
/// tries to launch. The caller owns the memory.
pub fn invokeAndCollect(command: Command) !InvocationResult {
    assert(command.args.len > 0);

    const result = std.process.run(command.gpa, command.io, .{ .argv = command.args }) catch |err| {
        return .{ .zig_error = err };
    };
    defer {
        command.gpa.free(result.stdout);
        command.gpa.free(result.stderr);
    }

    if (!terminationSuccessful(result.term) and
        !(command.stream == .stderr and result.term == .exited and result.term.exited == 1))
    {
        return .{
            .unsuccessful_termination = .{
                .term = result.term,
                .stderr = try command.gpa.dupe(u8, result.stderr),
            },
        };
    }

    if (command.stream == .stdout) {
        if (result.stderr.len != 0) {
            return .{ .stderr_on_stdout_only = try command.gpa.dupe(u8, result.stderr) };
        }
        return .{ .success = try command.gpa.dupe(u8, result.stdout) };
    } else {
        return .{ .success = try command.gpa.dupe(u8, result.stderr) };
    }
}

const Mode = enum {
    generate,
    compare,
};

const Stream = enum {
    stderr,
    stdout,
};

const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    program_path: []const u8,
    mode: Mode,
};

/// Null means eof.
const LineDiff = struct {
    number: usize,
    expected: ?[]const u8,
    actual: ?[]const u8,

    pub fn writeMessage(self: LineDiff, writer: *std.Io.Writer, input_path: []const u8, golden_path: []const u8) !void {
        try writer.print(
            \\|{s} <> {s}| line {} difference:
            \\
            \\Expected: {s}
            \\  Actual: {s}
            \\
            \\
        ,
            .{ input_path, golden_path, self.number + 1, self.expected orelse eof_marker, self.actual orelse eof_marker },
        );
    }
};

const eof_marker = "<EOF>";

const ComparisonResult = union(enum) {
    correct,
    invocation_failure,
    file_does_not_exist,
    /// The lines are duped. The caller owns the memory.
    line_diff: LineDiff,

    pub fn deinit(self: *ComparisonResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .correct, .file_does_not_exist, .invocation_failure => {},
            .line_diff => |line_diff| {
                if (line_diff.actual) |actual| {
                    gpa.free(actual);
                }
                if (line_diff.expected) |expected| {
                    gpa.free(expected);
                }
            },
        }
    }
};

const Query = struct {
    input_path: []const u8,
    goldenpath: []const u8,
    args: [][]const u8,
    program_output: InvocationResult,

    pub fn init(
        ctx: *const Context,
        filepath: []const u8,
        goldenpath: []const u8,
        stream: Stream,
        extra_args: []const []const u8,
    ) !Query {
        var arg_list: std.ArrayList([]const u8) = .empty;
        errdefer arg_list.deinit(ctx.gpa);
        try arg_list.append(ctx.gpa, ctx.program_path);
        try arg_list.appendSlice(ctx.gpa, extra_args);
        try arg_list.appendSlice(ctx.gpa, &.{ "-f", filepath });
        const args = try arg_list.toOwnedSlice(ctx.gpa);

        const output = try invokeAndCollect(.{
            .args = args,
            .gpa = ctx.gpa,
            .io = ctx.io,
            .stream = stream,
        });

        return .{
            .input_path = filepath,
            .goldenpath = goldenpath,
            .program_output = output,
            .args = args,
        };
    }

    pub fn deinit(self: *const Query, gpa: std.mem.Allocator) void {
        switch (self.program_output) {
            .success, .stderr_on_stdout_only => |output| gpa.free(output),
            .unsuccessful_termination => |unsuccessful_termination| gpa.free(unsuccessful_termination.stderr),
            else => {},
        }
        gpa.free(self.args);
    }
};

fn compare(ctx: *const Context, query: *const Query) !ComparisonResult {
    const cwd = std.Io.Dir.cwd();

    const output = switch (query.program_output) {
        .success => |output| output,
        else => return .invocation_failure,
    };

    const golden = cwd.readFileAllocOptions(ctx.io, query.goldenpath, ctx.gpa, .unlimited, .of(u8), 0) catch |err| {
        if (err == error.FileNotFound) {
            return ComparisonResult.file_does_not_exist;
        } else {
            return err;
        }
    };
    defer ctx.gpa.free(golden);

    const golden_lines = try Lines.init(ctx.gpa, golden);
    defer golden_lines.deinit(ctx.gpa);
    const output_lines = try Lines.init(ctx.gpa, output);
    defer output_lines.deinit(ctx.gpa);
    for (0..@min(golden_lines.lines.len, output_lines.lines.len)) |idx| {
        if (!std.mem.eql(u8, output_lines.lines[idx], golden_lines.lines[idx])) {
            return ComparisonResult{
                .line_diff = .{
                    .number = idx,
                    .actual = try ctx.gpa.dupe(u8, output_lines.lines[idx]),
                    .expected = try ctx.gpa.dupe(u8, golden_lines.lines[idx]),
                },
            };
        }
    }

    if (golden_lines.lines.len < output_lines.lines.len) {
        return ComparisonResult{
            .line_diff = .{
                .number = golden_lines.lines.len,
                .actual = try ctx.gpa.dupe(u8, output_lines.lines[golden_lines.lines.len]),
                .expected = null,
            },
        };
    } else if (output_lines.lines.len < golden_lines.lines.len) {
        return ComparisonResult{
            .line_diff = .{
                .number = output_lines.lines.len,
                .actual = null,
                .expected = try ctx.gpa.dupe(u8, golden_lines.lines[output_lines.lines.len]),
            },
        };
    } else {
        return ComparisonResult.correct;
    }
}

const GenerateResult = enum {
    created,
    updated,
    unchanged,
};

pub fn generate(ctx: *const Context, query: *const Query) !GenerateResult {
    const cwd = std.Io.Dir.cwd();

    var compare_result = try compare(ctx, query);
    defer compare_result.deinit(ctx.gpa);

    const result: GenerateResult = switch (compare_result) {
        .correct => .unchanged,
        .invocation_failure => .unchanged,
        .file_does_not_exist => .created,
        .line_diff => .updated,
    };

    if (result != .unchanged) {
        const output = query.program_output;

        try cwd.writeFile(ctx.io, .{
            .data = output.success,
            .sub_path = query.goldenpath,
            .flags = .{},
        });
    }

    return result;
}

const ComparisonSummary = struct {
    failed: u32 = 0,
    succeeded: u32 = 0,
};

const GeneratedSummary = struct {
    created: u32 = 0,
    updated: u32 = 0,
    unchanged: u32 = 0,
};

const Summary = union(enum) {
    generated: GeneratedSummary,
    comparison: ComparisonSummary,

    pub fn getText(self: Summary, gpa: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .generated => |generated| try std.fmt.allocPrint(
                gpa,
                "created: {}; updated: {}; unchanged: {}; total: {}\n",
                .{
                    generated.created,
                    generated.updated,
                    generated.unchanged,
                    generated.created + generated.updated + generated.unchanged,
                },
            ),
            .comparison => |comparison| try std.fmt.allocPrint(
                gpa,
                "passed: {}; failed: {}; total: {}\n",
                .{
                    comparison.succeeded,
                    comparison.failed,
                    comparison.succeeded + comparison.failed,
                },
            ),
        };
    }

    pub fn merge(self: *Summary, another: Summary) void {
        switch (self.*) {
            .generated => |*generated| {
                generated.created += another.generated.created;
                generated.updated += another.generated.updated;
                generated.unchanged += another.generated.unchanged;
            },
            .comparison => |*comparison| {
                comparison.failed += another.comparison.failed;
                comparison.succeeded += another.comparison.succeeded;
            },
        }
    }
};

/// Runs the program once and compares its output with the golden file.
/// Prints the reason and returns false on any mismatch.
fn compareRun(
    ctx: *const Context,
    filepath: []const u8,
    golden_path: []const u8,
    stream: Stream,
    extra_args: []const []const u8,
    stderr: *std.Io.Writer,
) !bool {
    const query = try Query.init(ctx, filepath, golden_path, stream, extra_args);
    defer query.deinit(ctx.gpa);

    if (query.program_output != .success)
        try stderr.print("{s}\n", .{try query.program_output.stringFailure(query.args, ctx.gpa)});

    var result = try compare(ctx, &query);
    defer result.deinit(ctx.gpa);
    switch (result) {
        .correct => return true,
        .invocation_failure => return false,
        .file_does_not_exist => {
            try stderr.print("Missing golden file for {s}: {s}\n", .{ query.input_path, query.goldenpath });
            return false;
        },
        .line_diff => |line_diff| {
            if (extra_args.len != 0) {
                const extra = try concatWithSep(ctx.gpa, extra_args, " ");
                defer ctx.gpa.free(extra);
                try stderr.print("Run with: {s}\n", .{extra});
            }
            try line_diff.writeMessage(stderr, query.input_path, query.goldenpath);
            return false;
        },
    }
}

pub fn processDirectory(
    ctx: *const Context,
    path_to_dir: []const u8,
    stream: Stream,
    runs: []const []const []const u8,
) !Summary {
    var _arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer _arena.deinit();
    const arena = _arena.allocator();

    const path_to_dir_resolved = try std.fs.path.resolve(ctx.gpa, &.{path_to_dir});
    defer ctx.gpa.free(path_to_dir_resolved);

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(ctx.io, path_to_dir_resolved, .{ .access_sub_paths = false, .iterate = true });
    defer dir.close(ctx.io);

    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &.{});
    const stderr = &stderr_writer.interface;

    const golden_dir_path = try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, golden_subdir });
    if (ctx.mode == .generate) {
        const golden_dir = dir.openDir(ctx.io, golden_subdir, .{}) catch |err| err_blk: {
            if (err == error.FileNotFound) {
                try stderr.print("{s} directory not found. Creating it.\n", .{golden_dir_path});
                try dir.createDir(ctx.io, golden_subdir, std.Io.Dir.Permissions.default_dir);
                break :err_blk try dir.openDir(ctx.io, golden_subdir, .{});
            }
            try stderr.print("Error when opening {s}: {s}\n", .{ golden_dir_path, @errorName(err) });
            return err;
        };
        golden_dir.close(ctx.io);
    }

    var iter = dir.iterate();

    var summary: Summary = switch (ctx.mode) {
        .compare => .{ .comparison = .{} },
        .generate => .{ .generated = .{} },
    };

    while (try iter.next(ctx.io)) |entry| {
        // skip "nested" and "golden" directories
        if (entry.kind == .directory and
            !std.mem.eql(u8, entry.name, nested_subdir) and
            !std.mem.eql(u8, entry.name, golden_subdir))
        {
            const nested_directory_resolved = try std.fs.path.resolve(ctx.gpa, &.{ path_to_dir_resolved, entry.name });
            defer ctx.gpa.free(nested_directory_resolved);
            const nested_summary = try processDirectory(ctx, nested_directory_resolved, stream, runs);
            summary.merge(nested_summary);
        } else if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".in")) {
            const golden_path = blk: {
                const basename_without_extension = std.fs.path.stem(entry.name);
                const golden_basename = try std.fmt.allocPrint(arena, "{s}{s}", .{ basename_without_extension, golden_ext });
                break :blk try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, golden_subdir, golden_basename });
            };
            const filepath = try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, entry.name });

            switch (summary) {
                .comparison => |*comparison| {
                    const passed = for (runs) |extra_args| {
                        if (!try compareRun(ctx, filepath, golden_path, stream, extra_args, stderr)) break false;
                    } else true;

                    if (passed) {
                        comparison.succeeded += 1;
                    } else {
                        comparison.failed += 1;
                    }
                },
                .generated => |*generated| {
                    const query = try Query.init(ctx, filepath, golden_path, stream, &.{});
                    defer query.deinit(ctx.gpa);

                    if (query.program_output != .success)
                        try stderr.print("{s}\n", .{try query.program_output.stringFailure(query.args, ctx.gpa)});

                    const result = try generate(ctx, &query);
                    switch (result) {
                        .created => generated.created += 1,
                        .updated => generated.updated += 1,
                        .unchanged => generated.unchanged += 1,
                    }
                },
            }
        }
    }

    if (summary == .comparison and summary.comparison.failed != 0) {
        try stderr.print("Consider `zig build golden-test -Dgenerate` or fix your code.\n\n", .{});
    }
    return summary;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var stderr = std.Io.File.stderr().writer(init.io, &.{});
    var stdout = std.Io.File.stdout().writer(init.io, &.{});

    const args = init.minimal.args.vector;
    if (args.len < 2) {
        try stderr.interface.print("Golden test runner requires a path to the executable.\n", .{});
        std.process.exit(1);
    }
    const program_path = args[1];

    const mode = mode: {
        if (args.len > 2) {
            const arg = std.mem.span(args[2]);
            if (std.mem.eql(u8, arg, "generate")) {
                try stderr.interface.print("Generating new golden tests\n", .{});
                break :mode Mode.generate;
            } else if (std.mem.eql(u8, arg, "compare")) {
                break :mode Mode.compare;
            }
            try stderr.interface.print("Unknown mode: {s}. Expected `compare` or `generate`.\n", .{arg});
            std.process.exit(1);
        }
        break :mode Mode.compare;
    };

    const ctx: Context = .{
        .io = init.io,
        .gpa = gpa,
        .program_path = std.mem.span(program_path),
        .mode = mode,
    };

    const stdout_summary = try processDirectory(&ctx, stdout_tests_path, .stdout, &stdout_runs);
    const stdout_summary_text = try stdout_summary.getText(ctx.gpa);
    defer ctx.gpa.free(stdout_summary_text);

    const stderr_summary = try processDirectory(&ctx, stderr_tests_path, .stderr, &single_run);
    const stderr_summary_text = try stderr_summary.getText(ctx.gpa);
    defer ctx.gpa.free(stderr_summary_text);

    try stdout.interface.print(
        "{s: <12}| {s}{s: <12}| {s}",
        .{
            stdout_tests_path,
            stdout_summary_text,
            stderr_tests_path,
            stderr_summary_text,
        },
    );
    if (ctx.mode == .compare) {
        if (stdout_summary.comparison.failed != 0 or stderr_summary.comparison.failed != 0) {
            std.process.exit(1);
        }
    }
}

/// The caller owns the resulting slice.
fn concatWithSep(gpa: std.mem.Allocator, strings: []const []const u8, comptime sep: []const u8) ![]u8 {
    if (strings.len == 0) return &.{};

    const size = size: {
        var size: usize = strings[0].len;
        for (strings[1..]) |str| {
            size += str.len + sep.len;
        }
        break :size size;
    };

    var list: std.ArrayList(u8) = try .initCapacity(gpa, size);
    list.appendSliceAssumeCapacity(strings[0]);
    for (strings[1..]) |str| {
        list.appendSliceAssumeCapacity(sep);
        list.appendSliceAssumeCapacity(str);
    }

    return list.toOwnedSliceAssert();
}

test "concatWithSep" {
    const gpa = std.testing.allocator;

    const data1 = &.{ "hello", "world" };
    const data_empty = &.{};
    const data2 = &.{ "a", "", "3" };

    const s1 = try concatWithSep(gpa, data1, " ");
    const s2 = try concatWithSep(gpa, data_empty, "    ");
    const s3 = try concatWithSep(gpa, data2, " | ");
    defer {
        gpa.free(s1);
        gpa.free(s2);
        gpa.free(s3);
    }

    try std.testing.expectEqualStrings(s1, "hello world");
    try std.testing.expectEqualStrings(s2, "");
    try std.testing.expectEqualStrings(s3, "a |  | 3");
}

fn stringTermination(gpa: std.mem.Allocator, termination: std.process.Child.Term) ![]u8 {
    return switch (termination) {
        .exited => |code| try std.fmt.allocPrint(gpa, "exited with code {}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(gpa, "terminated by signal {}", .{signal}),
        .stopped => |signal| try std.fmt.allocPrint(gpa, "stopped by signal {}", .{signal}),
        .unknown => |code| try std.fmt.allocPrint(gpa, "terminated for unknown reason ({})", .{code}),
    };
}

fn terminationSuccessful(termination: std.process.Child.Term) bool {
    return switch (termination) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "sub-modules" {
    _ = .{
        Lines,
    };
}

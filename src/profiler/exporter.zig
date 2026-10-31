//! Exporting profiling data to .csv tables.

const Self = @This();

const std = @import("std");
const Io = std.Io;

const Runtime = @import("shared_runtime");

const Profiler = @import("profiler.zig");
const RunResult = Profiler.RunResult;
const ProfilingResult = Profiler.ProfilingResult;
const Usage = Runtime.Memory.Usage;

export_dir: Io.Dir,

stmt_dir: ?Io.Dir = null,

runtime: *const Runtime,

pub fn getStatementName(self: *const Self, stmt: Profiler.Statement) ![]u8 {
    return std.fmt.allocPrint(self.runtime.gpa, "{}{s}~{s}", .{
        stmt.id,
        self.runtime.getAgentName(stmt.interaction.lhs).?,
        self.runtime.getAgentName(stmt.interaction.rhs).?,
    });
}

pub fn exportStatement(self: *Self, stmt: Profiler.Statement) !void {
    const statement_name = try self.getStatementName(stmt);
    defer self.runtime.gpa.free(statement_name);

    self.stmt_dir = try self.export_dir.createDirPathOpen(self.runtime.io, statement_name, .{});
}

pub fn stopExport(self: *Self) void {
    self.stmt_dir.?.close(self.runtime.io);
    self.stmt_dir = null;
}

const benchmark_file_name = "bench.csv";
const profiling_file_name = "agent_structure.csv";
const memory_file_name = "memory.csv";

/// If the file exists, append result to the end.
pub fn exportRunResult(self: *Self, result: RunResult) !void {
    const stmt_dir = self.stmt_dir.?;
    const bench_file = if (stmt_dir.openFile(self.runtime.io, benchmark_file_name, .{ .mode = .write_only })) |bench_file| bench_file else |err| blk: {
        if (err != std.Io.File.OpenError.FileNotFound) {
            return err;
        }

        const bench_file = try stmt_dir.createFile(self.runtime.io, benchmark_file_name, .{});
        var writer = bench_file.writer(self.runtime.io, &.{});
        try writer.interface.writeAll(RunResult.getHeader());
        break :blk bench_file;
    };
    defer bench_file.close(self.runtime.io);
    var writer = bench_file.writer(self.runtime.io, &.{});
    try writer.seekTo(try bench_file.length(self.runtime.io));
    const data = try result.getResultLine(self.runtime.gpa);
    defer self.runtime.gpa.free(data);

    try writer.interface.writeAll(data);
}

pub fn exportProfilingResult(self: *Self, result: ProfilingResult) !void {
    const header, var map = try result.getHeader(self.runtime);
    defer {
        ProfilingResult.deinitCountMap(&map, self.runtime);
        self.runtime.gpa.free(header);
    }
    try result.fillCountMap(self.runtime, &map);
    const data = try result.getResultData(self.runtime, &map);
    defer self.runtime.gpa.free(data);

    const stmt_dir = self.stmt_dir.?;
    const profiling_file = try stmt_dir.createFile(self.runtime.io, profiling_file_name, .{});
    defer profiling_file.close(self.runtime.io);
    var writer = profiling_file.writer(self.runtime.io, &.{});
    try writer.interface.print("{s}{s}", .{ header, data });
}

pub fn exportUsage(self: *Self, agent_usage: Usage, name_usage: Usage) !void {
    const header = "Type,used,free,peak\n";
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const gpa = fixed.allocator();

    const data = gpa.print("{s}Agent,{},{},{}\nName,{},{},{}\n", .{
        header,
        agent_usage.used,
        agent_usage.free,
        agent_usage.peak,
        name_usage.used,
        name_usage.free,
        name_usage.peak,
    }) catch unreachable;

    const stmt_dir = self.stmt_dir.?;
    const memory_file = try stmt_dir.createFile(self.runtime.io, memory_file_name, .{});
    defer memory_file.close(self.runtime.io);

    var writer = memory_file.writer(self.runtime.io, &.{});
    try writer.interface.writeAll(data);
}

/// Expects export_path to be resolved.
pub fn init(export_path: []const u8, runtime: *const Runtime) !Self {
    const export_dir = try std.Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), runtime.io, export_path, .{});

    return .{
        .export_dir = export_dir,
        .runtime = runtime,
    };
}

pub fn deinit(self: *Self) void {
    self.export_dir.close(self.runtime.io);
}

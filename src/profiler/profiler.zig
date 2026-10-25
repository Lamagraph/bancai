//! A struct, that handles interaction debug/analysis related functionality.
//! Completely unrelated to the usual external tools.
const Self = @This();

const std = @import("std");

pub const Printing = @import("printing.zig");
const Exporter = @import("exporter.zig");

const Config = @import("config");

const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const Types = Runtime.Types;
const Heap = Memory.Heap;

const Agent = Types.Agent;
const Name = Types.Name;
const AgentCount = Memory.AgentCount;

pub const profile_memory = Config.heap == .basic and Config.debug_printing.benchmark and Config.debug_printing.print_memory_usage;
pub const any_analysis = Config.debug_printing.benchmark or Config.debug_printing.print_memory_usage;

pub const Interaction = struct {
    lhs: Agent.Id,
    rhs: Agent.Id,
};

const Timer = struct {
    st: std.Io.Timestamp,
    io: std.Io,

    fn start(self: *Timer) void {
        self.st = std.Io.Clock.awake.now(self.io);
    }

    fn stop(self: *Timer) std.Io.Duration {
        const end = std.Io.Clock.awake.now(self.io);
        return self.st.durationTo(end);
    }

    fn init(io: std.Io) Timer {
        return .{
            .io = io,
            .st = undefined,
        };
    }
};

pub const RunResult = struct {
    elapsed_time: f64,
    interaction_count: u64,

    fn debugPrint(self: RunResult) void {
        std.debug.print("{} interaction{s} in {}s\n", .{
            self.interaction_count,
            if (self.interaction_count != 1) "s" else "",
            self.elapsed_time,
        });
    }

    // csv

    pub fn getResultLine(self: RunResult, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{},{}\n", .{ self.interaction_count, self.elapsed_time });
    }

    pub fn getHeader() []const u8 {
        return "Interactions,Time(s)\n";
    }
};

pub const ProfilingSingle = struct {
    interaction_count: u64,
    total_agents: u64,
    agent_count_list: []AgentCount,

    fn debugPrint(self: ProfilingSingle, runtime: *const Runtime) void {
        std.debug.print("Profiling data after {} interaction{s}\n", .{ self.interaction_count, if (self.interaction_count != 1) "s" else "" });

        for (0..self.agent_count_list.len) |agent_idx| {
            const agent_id = self.agent_count_list[agent_idx].id;
            const agent_cnt = self.agent_count_list[agent_idx].cnt;
            const name = runtime.getAgentName(agent_id).?;

            std.debug.print("#{:0>4} - {s: >40} {: >9}\n", .{ agent_id, name, agent_cnt });
        }

        std.debug.print("\n", .{});
    }
};

pub const ProfilingResult = struct {
    profiling_invocations: []ProfilingSingle,

    fn debugPrint(self: ProfilingResult, runtime: *const Runtime) void {
        for (self.profiling_invocations) |invocation| {
            invocation.debugPrint(runtime);
        }
    }

    // csv

    pub const CountMap = std.AutoHashMap(Agent.Id, std.ArrayList(u64));

    pub fn getHeader(self: ProfilingResult, runtime: *const Runtime) !struct { []u8, CountMap } {
        var map: CountMap = .init(runtime.gpa);
        for (self.profiling_invocations) |invocation| {
            for (invocation.agent_count_list) |agent_count| {
                if (!map.contains(agent_count.id)) {
                    try map.put(agent_count.id, .empty);
                }
            }
        }
        var string_builder: std.ArrayList(u8) = .empty;
        defer string_builder.deinit(runtime.gpa);

        var iter = map.keyIterator();
        while (iter.next()) |agent_id| {
            if (string_builder.items.len != 0) {
                try string_builder.appendSlice(runtime.gpa, ",");
            }
            try string_builder.appendSlice(runtime.gpa, runtime.getAgentName(agent_id.*).?);
        }
        return .{ try runtime.gpa.print("Interactions,Total,{s}\n", .{string_builder.items}), map };
    }

    pub fn fillCountMap(self: ProfilingResult, runtime: *const Runtime, map: *CountMap) !void {
        for (self.profiling_invocations, 0..) |invocation, invocation_idx| {
            for (invocation.agent_count_list) |agent_count| {
                const lst = map.getPtr(agent_count.id).?;
                try lst.append(runtime.gpa, agent_count.cnt);
            }
            var iter = map.valueIterator();
            while (iter.next()) |lst| {
                if (lst.items.len < invocation_idx + 1) {
                    try lst.append(runtime.gpa, 0);
                }
            }
        }
    }

    pub fn getResultData(self: ProfilingResult, runtime: *const Runtime, map: *CountMap) ![]u8 {
        var string_builder: std.ArrayList(u8) = .empty;
        for (self.profiling_invocations, 0..) |invocation, invocation_idx| {
            try string_builder.print(runtime.gpa, "{},{}", .{ invocation.interaction_count, invocation.total_agents });
            var iter = map.valueIterator();
            while (iter.next()) |count_lst| {
                try string_builder.print(runtime.gpa, ",{}", .{count_lst.items[invocation_idx]});
            }
            try string_builder.appendSlice(runtime.gpa, "\n");
        }
        return string_builder.toOwnedSlice(runtime.gpa);
    }

    pub fn deinitCountMap(map: *CountMap, runtime: *const Runtime) void {
        var iter = map.valueIterator();

        while (iter.next()) |count_lst| {
            count_lst.deinit(runtime.gpa);
        }
        map.deinit();
    }
};

pub const Statement = struct {
    interaction: Interaction,
    id: u32,

    duration: ?std.Io.Duration,
    profiling_invocations: ?std.ArrayList(ProfilingSingle),

    fn debugPrint(self: Statement, runtime: *const Runtime) void {
        std.debug.print("analyzed data for ({s} ~ {s}) begin\n", .{
            runtime.getAgentName(self.interaction.lhs).?,
            runtime.getAgentName(self.interaction.rhs).?,
        });
    }

    fn debugEndStatementPrint() void {
        std.debug.print("end.\n", .{});
    }

    fn reset(self: *Statement, gpa: std.mem.Allocator) void {
        if (self.profiling_invocations) |*invocations| {
            for (invocations.items) |data| {
                gpa.free(data.agent_count_list);
            }
            invocations.clearAndFree(gpa);
        }
    }

    fn deinit(self: *Statement, gpa: std.mem.Allocator) void {
        if (self.profiling_invocations) |*invocations| {
            invocations.clearAndFree(gpa);
        }
    }
};

interaction_count: u64,
profiling_window: ?u64,
profiling_cnt: u64,
stmt_cnt: u32,

current_statement: Statement,
timer: Timer,

exporter: ?Exporter,

runtime: *const Runtime,

pub fn incInteraction(self: *Self) void {
    // very atomic operation.
    self.interaction_count += 1;
}

pub fn incProfiling(self: *Self) void {
    self.profiling_cnt += 1;
}

pub fn resetInteractions(self: *Self) void {
    self.interaction_count = 0;
    self.profiling_cnt = 0;
}

pub fn shouldGetAgentStructure(self: *const Self) bool {
    if (self.profiling_window) |profiling_window| {
        return self.interaction_count % profiling_window == 0 and self.interaction_count != 0;
    } else {
        return false;
    }
}

pub fn collectAgentStructure(self: *Self, agent_heap: Heap(Agent)) std.mem.Allocator.Error!void {
    const invocations = &(self.current_statement.profiling_invocations.?);

    const max_agent_id = 512;
    var agent_count_lst: [max_agent_id]AgentCount = undefined;

    const ids_count = agent_heap.getAgentStructure(&agent_count_lst);

    const total_agent_count = blk: {
        var cnt: u64 = 0;
        for (agent_count_lst[0..ids_count]) |agent_count| {
            cnt += agent_count.cnt;
        }
        break :blk cnt;
    };

    const data: ProfilingSingle = .{
        .interaction_count = self.interaction_count,
        .total_agents = total_agent_count,
        .agent_count_list = try self.runtime.gpa.dupe(AgentCount, agent_count_lst[0..ids_count]),
    };

    try invocations.append(self.runtime.gpa, data);
}

pub fn startInteraction(self: *Self, interaction: Interaction) void {
    self.current_statement = .{
        .interaction = interaction,
        .id = self.stmt_cnt,
        .duration = null,
        .profiling_invocations = null,
    };
    if (profile_memory) {
        self.current_statement.profiling_invocations = .empty;
    }
    if (Config.debug_printing.benchmark) {
        self.timer.start();
    }
}

pub fn endInteraction(self: *Self, ctx: Context) void {
    if (Config.debug_printing.benchmark) {
        self.current_statement.duration = self.timer.stop();
    }

    if (profile_memory) {
        self.collectAgentStructure(ctx.agent_heap) catch |err| {
            std.debug.print("Couldn't collect post-interaction agent structure: {s}\n", .{@errorName(err)});
        };
    }

    self.analyzeStatement(self.current_statement, ctx);

    self.current_statement.reset(self.runtime.gpa);

    self.resetInteractions();

    self.stmt_cnt += 1;
}

fn analyzeStatement(self: *Self, stmt: Statement, ctx: Context) void {
    if (any_analysis) {
        stmt.debugPrint(self.runtime);

        if (self.exporter) |*exporter| {
            exporter.exportStatement(stmt) catch |err| {
                std.debug.print("Couldn't export statement: {s}\n", .{@errorName(err)});
            };
        }
    }

    if (Config.debug_printing.benchmark) {
        const run: RunResult = .{
            .interaction_count = self.interaction_count,
            .elapsed_time = @as(f64, @floatFromInt(stmt.duration.?.toMicroseconds())) / 1e6,
        };
        run.debugPrint();

        if (self.exporter) |*exporter| {
            exporter.exportRunResult(run) catch |err| {
                std.debug.print("Couldn't export run result: {s}\n", .{@errorName(err)});
            };
        }

        if (profile_memory) {
            const invocations = stmt.profiling_invocations.?;

            const profiling_result: ProfilingResult = .{ .profiling_invocations = invocations.items };

            profiling_result.debugPrint(self.runtime);

            if (self.exporter) |*exporter| {
                if (profiling_result.profiling_invocations.len > 0) {
                    exporter.exportProfilingResult(profiling_result) catch |err| {
                        std.debug.print("Couldn't export profiling_result: {s}\n", .{@errorName(err)});
                    };
                }
            }
        }
    }

    if (Config.debug_printing.print_memory_usage) {
        self.analyzeContext(ctx);
    }

    if (any_analysis) {
        Statement.debugEndStatementPrint();

        if (self.exporter) |*exporter| {
            exporter.stopExport();
        }
    }
}

pub const Context = struct {
    agent_heap: Heap(Agent),
    name_heap: Heap(Name),
};

pub fn analyzeContext(_: *const Self, ctx: Context) void {
    if (Config.debug_printing.print_memory_usage) {
        const agent_usage = ctx.agent_heap.getUsage();
        const name_usage = ctx.name_heap.getUsage();

        agent_usage.debugPrint("Agent");
        name_usage.debugPrint("Name");
    }
}

pub fn init(runtime: *const Runtime, profiling_window: ?u64, export_path: ?[]const u8) Self {
    return .{
        .interaction_count = 0,
        .profiling_window = profiling_window,
        .profiling_cnt = 0,
        .stmt_cnt = 0,
        .exporter = if (export_path) |epath| Exporter.init(epath, runtime) catch |err| err_blk: {
            std.debug.print("Couldn't initialize exporter: {s}", .{@errorName(err)});
            break :err_blk null;
        } else null,
        .current_statement = undefined,
        .runtime = runtime,
        .timer = .init(runtime.io),
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

test {
    _ = .{
        Printing,
    };
}

//! A struct, that handles interaction debug/analysis related functionality.
//! Completely unrelated to the usual external tools.
const Self = @This();

const std = @import("std");

pub const Printing = @import("printing.zig");

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

const RunResult = struct {
    elapsed_time: f64,
    interaction_count: u64,

    fn debugPrint(self: RunResult) void {
        std.debug.print("{} interaction{s} in {}s\n", .{
            self.interaction_count,
            if (self.interaction_count != 1) "s" else "",
            self.elapsed_time,
        });
    }
};

const ProfilingSingle = struct {
    interaction_count: u64,
    agent_count_list: []AgentCount,

    fn debugPrint(self: ProfilingSingle, runtime: *const Runtime) void {
        std.debug.print("Profiling data after {} interactions\n", .{self.interaction_count});

        for (0..self.agent_count_list.len) |agent_idx| {
            const agent_id = self.agent_count_list[agent_idx].id;
            const agent_cnt = self.agent_count_list[agent_idx].cnt;
            const name = runtime.getAgentName(agent_id).?;

            std.debug.print("#{:0>4} - {s: >15} {: >9}\n", .{ agent_id, name, agent_cnt });
        }

        std.debug.print("\n", .{});
    }
};

const ProfilingResult = struct {
    profiling_invocations: []ProfilingSingle,

    fn debugPrint(self: ProfilingResult, runtime: *const Runtime) void {
        for (self.profiling_invocations) |invocation| {
            invocation.debugPrint(runtime);
        }
    }
};

const Statement = struct {
    interaction: Interaction,
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
            invocations.clearRetainingCapacity();
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

pub fn collectAgentStructure(self: *Self, agent_heap: Heap(Agent)) !void {
    const invocations = &(self.current_statement.profiling_invocations.?);

    const max_agent_id = 512;
    var agent_count_lst: [max_agent_id]AgentCount = undefined;

    const ids_count = agent_heap.getAgentStructure(&agent_count_lst);

    const data: ProfilingSingle = .{
        .interaction_count = self.interaction_count,
        .agent_count_list = try self.runtime.gpa.dupe(AgentCount, agent_count_lst[0..ids_count]),
    };

    try invocations.append(self.runtime.gpa, data);
}

pub fn startInteraction(self: *Self, interaction: Interaction) void {
    self.current_statement = .{
        .interaction = interaction,
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

    self.analyzeStatement(self.current_statement, ctx);

    self.current_statement.reset(self.runtime.gpa);

    self.resetInteractions();

    self.stmt_cnt += 1;
}

fn analyzeStatement(self: *Self, stmt: Statement, ctx: Context) void {
    if (any_analysis) {
        stmt.debugPrint(self.runtime);
    }

    if (Config.debug_printing.benchmark) {
        const run: RunResult = .{
            .interaction_count = self.interaction_count,
            .elapsed_time = @as(f64, @floatFromInt(stmt.duration.?.toMicroseconds())) / 1e6,
        };
        run.debugPrint();

        if (profile_memory) {
            const invocations = stmt.profiling_invocations.?;

            const profiling_result: ProfilingResult = .{ .profiling_invocations = invocations.items };

            profiling_result.debugPrint(self.runtime);
        }
    }

    if (Config.debug_printing.print_memory_usage) {
        self.analyzeContext(ctx);
    }

    if (any_analysis) {
        Statement.debugEndStatementPrint();
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

pub fn init(runtime: *const Runtime, profiling_window: ?u64) Self {
    return .{
        .interaction_count = 0,
        .profiling_window = profiling_window,
        .profiling_cnt = 0,
        .stmt_cnt = 0,

        .current_statement = undefined,
        .runtime = runtime,
        .timer = .init(runtime.io),
    };
}

pub fn deinit(self: *Self) void {
    self.current_statement.deinit(self.runtime.gpa);
}

test {
    _ = .{
        Printing,
    };
}

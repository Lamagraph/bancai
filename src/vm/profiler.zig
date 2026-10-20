//! A struct, that handles interaction debug/analysis related functionality.
//! Completely unrelated to the usual external tools.
const Self = @This();

const std = @import("std");

const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const Heap = Memory.Heap;

const Agent = Runtime.Types.Agent;
const AgentCount = Memory.AgentCount;

interactions_count: usize,
profiling_window: ?usize,
profiling_cnt: usize,

pub fn incInteraction(self: *Self) void {
    // very atomic operation.
    self.interactions_count += 1;
}

pub fn incProfiling(self: *Self) void {
    self.profiling_cnt += 1;
}

pub fn resetInteractions(self: *Self) void {
    self.interactions_count = 0;
    self.profiling_cnt = 0;
}

pub fn shouldPrintAgentStructure(self: *const Self) bool {
    if (self.profiling_window) |profiling_window| {
        return self.interactions_count % profiling_window == 0 and self.interactions_count != 0;
    } else {
        return false;
    }
}

pub fn printAgentStructure(self: *const Self, runtime: *const Runtime, agent_heap: Heap(Agent)) !void {
    std.debug.print("Profiling data {} time over {} interactions\n", .{ self.profiling_cnt, self.interactions_count });

    const max_ids = 1024;
    var structure_data_arr: [max_ids]AgentCount = undefined;

    const ids_count = agent_heap.getAgentStructure(&structure_data_arr);

    std.mem.sort(AgentCount, structure_data_arr[0..ids_count], {}, AgentCount.lessThan);

    for (0..ids_count) |agent_idx| {
        const agent_id = structure_data_arr[agent_idx].id;
        const agent_cnt = structure_data_arr[agent_idx].cnt;
        const name = runtime.getAgentName(agent_id).?;

        std.debug.print("#{:0>4} - {s: >15} {: >9}\n", .{ agent_id, name, agent_cnt });
    }

    std.debug.print("\n", .{});
}

pub fn init(profiling_window: ?usize) Self {
    return .{
        .interactions_count = 0,
        .profiling_window = profiling_window,
        .profiling_cnt = 0,
    };
}

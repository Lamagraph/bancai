//! A struct, that handles interaction debug/analysis related functionality.
//! Completely unrelated to the usual external tools.
const Self = @This();

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

pub fn init(profiling_window: ?usize) Self {
    return .{
        .interactions_count = 0,
        .profiling_window = profiling_window,
        .profiling_cnt = 0,
    };
}

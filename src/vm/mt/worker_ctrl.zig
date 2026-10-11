//! Shared state every Core (worker) can update without taking any lock -
//! specifically, whether it is currently busy reducing an equation.
const std = @import("std");

const Self = @This();

/// Caps concurrent cores at 64 - one bit each, fits in one word.
pub const max_cores = 64;

busy_mask: std.atomic.Value(u64),

pub fn init() Self {
    return .{ .busy_mask = std.atomic.Value(u64).init(0) };
}

/// Marks core_id as currently reducing an equation.
pub fn setBit(self: *Self, core_id: u32) void {
    std.debug.assert(core_id < max_cores);
    _ = self.busy_mask.fetchOr(@as(u64, 1) << @intCast(core_id), .release);
}

/// Marks core_id as idle - it found nothing left to reduce.
pub fn clearBit(self: *Self, core_id: u32) void {
    std.debug.assert(core_id < max_cores);
    _ = self.busy_mask.fetchAnd(~(@as(u64, 1) << @intCast(core_id)), .release);
}

/// Raw snapshot of which cores are currently busy.
pub fn read(self: *const Self) u64 {
    return self.busy_mask.load(.acquire);
}

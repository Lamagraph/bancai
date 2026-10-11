//! Control state of the main core; not used yet.
const std = @import("std");

const Self = @This();

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init() Self {
    return .{};
}

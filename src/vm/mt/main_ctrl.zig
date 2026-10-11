//! Shared state every Core (worker) can update without taking any lock -
//! specifically, whether it is currently busy reducing an equation.
const std = @import("std");

const Self = @This();

pub fn init() Self {
    return .{};
}

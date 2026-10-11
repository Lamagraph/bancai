//! Door-bell the VM sleeps on until some core changes its state.
const std = @import("std");

pub const Ring = u32;

pub const DoorBell = struct {
    const Self = @This();

    const Rings = std.atomic.Value(Ring);

    io: std.Io,
    rings: Rings align(std.atomic.cache_line) = Rings.init(0),

    pub fn init(io: std.Io) Self {
        return .{ .io = io };
    }

    pub fn ring(self: *Self) void {
        _ = self.rings.fetchAdd(1, .release);
        self.io.futexWake(Ring, &self.rings.raw, 1);
    }

    /// Must be taken before checking the cores, then handed to `sleep`.
    pub fn listen(self: *Self) Ring {
        return self.rings.load(.acquire);
    }

    /// Returns at once if the bell rang after `heard` was taken.
    pub fn sleep(self: *Self, heard: Ring) void {
        self.io.futexWaitUncancelable(Ring, &self.rings.raw, heard);
    }
};

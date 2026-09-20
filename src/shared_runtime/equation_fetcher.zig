//! Interface for fetching equations to the worker.
const std = @import("std");
const Types = @import("types.zig");
const Equation = Types.Equation;

const Error = std.mem.Allocator.Error;

pub const EquationFetcher = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    fetch: *const fn (*anyopaque) ?Equation,
    push: *const fn (*anyopaque, Equation) Error!void,
    pushUrgent: *const fn (*anyopaque, Equation) Error!void,
    pushLazy: *const fn (*anyopaque, Equation) Error!void,
};

pub inline fn fetch(self: EquationFetcher) ?Equation {
    return self.vtable.fetch(self.ptr);
}

pub inline fn push(self: EquationFetcher, eq: Equation) Error!void {
    return self.vtable.push(self.ptr, eq);
}

pub inline fn pushUrgent(self: EquationFetcher, eq: Equation) Error!void {
    return self.vtable.pushUrgent(self.ptr, eq);
}

pub inline fn pushLazy(self: EquationFetcher, eq: Equation) Error!void {
    return self.vtable.pushLazy(self.ptr, eq);
}

pub const LockedEquationFetcher = struct {
    const Self = @This();

    inner: EquationFetcher,
    mutex: std.atomic.Mutex = .unlocked,

    const vtable: VTable = .{
        .fetch = Self.fetch,
        .push = Self.push,
        .pushUrgent = Self.pushUrgent,
        .pushLazy = Self.pushLazy,
    };

    pub fn init(inner: EquationFetcher) Self {
        return .{ .inner = inner };
    }

    pub fn equationFetcher(self: *Self) EquationFetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn getUser(self: *Self) EquationFetcher {
        return self.equationFetcher();
    }

    // std.atomic.Mutex is lock-free (tryLock/unlock only) - spin until we
    // get it.
    fn lock(self: *Self) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn fetch(ctx: *anyopaque) ?Equation {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.lock();
        defer self.mutex.unlock();

        return self.inner.fetch();
    }

    fn push(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.lock();
        defer self.mutex.unlock();

        return self.inner.push(eq);
    }

    fn pushUrgent(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.lock();
        defer self.mutex.unlock();

        return self.inner.pushUrgent(eq);
    }
    fn pushLazy(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.lock();
        defer self.mutex.unlock();

        return self.inner.pushLazy(eq);
    }
};

/// Works like a queue. Single-threaded only on its own - see
/// LockedEquationFetcher for sharing one across cores.
pub const TwoDequeEquationFetcher = struct {
    const Self = @This();

    equation_deque: std.Deque(Equation),
    urgent_deque: std.Deque(Equation),
    lazy_deque: std.Deque(Equation),
    gpa: std.mem.Allocator,

    const vtable: VTable = .{
        .fetch = Self.fetch,
        .push = Self.push,
        .pushUrgent = Self.pushUrgent,
        .pushLazy = Self.pushLazy,
    };

    pub fn equationFetcher(self: *Self) EquationFetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn fetch(ctx: *anyopaque) ?Equation {
        const self: *Self = @ptrCast(@alignCast(ctx));

        return self.urgent_deque.popFront() orelse self.equation_deque.popFront() orelse self.lazy_deque.popFront();
    }

    pub fn push(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        try self.equation_deque.pushBack(self.gpa, eq);
    }

    pub fn pushUrgent(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        try self.urgent_deque.pushBack(self.gpa, eq);
    }

    pub fn pushLazy(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        try self.lazy_deque.pushBack(self.gpa, eq);
    }

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .equation_deque = .empty,
            .urgent_deque = .empty,
            .lazy_deque = .empty,
            .gpa = gpa,
        };
    }
    pub fn deinit(self: *Self) void {
        self.equation_deque.deinit(self.gpa);
        self.urgent_deque.deinit(self.gpa);
        self.lazy_deque.deinit(self.gpa);
    }
};

test "LockedEquationFetcher: wraps push/pushUrgent/fetch through to the inner fetcher" {
    const gpa = std.testing.allocator;

    var two_deque = TwoDequeEquationFetcher.init(gpa);
    defer two_deque.deinit();

    var locked = LockedEquationFetcher.init(two_deque.equationFetcher());
    const fetcher = locked.equationFetcher();

    try std.testing.expect(fetcher.fetch() == null);

    var lagent = Types.Agent{ .id = 1, .ports = @splat(null) };
    var ragent = Types.Agent{ .id = 2, .ports = @splat(null) };
    const eq = Equation{ .lhs = &lagent, .rhs = &ragent };

    try fetcher.push(eq);
    const fetched = fetcher.fetch() orelse return error.TestExpectedFetch;
    try std.testing.expectEqual(eq.lhs, fetched.lhs);
    try std.testing.expectEqual(eq.rhs, fetched.rhs);
    try std.testing.expect(fetcher.fetch() == null);

    // Urgent equations come back before normal ones.
    try fetcher.push(eq);
    try fetcher.pushUrgent(eq);
    _ = fetcher.fetch() orelse return error.TestExpectedFetch;
    _ = fetcher.fetch() orelse return error.TestExpectedFetch;
    try std.testing.expect(fetcher.fetch() == null);
}

test "LockedEquationFetcher: getUser hands back a working copy of the fetcher" {
    const gpa = std.testing.allocator;

    var two_deque = TwoDequeEquationFetcher.init(gpa);
    defer two_deque.deinit();

    var locked = LockedEquationFetcher.init(two_deque.equationFetcher());

    const fetcher = locked.getUser();
    try std.testing.expect(fetcher.fetch() == null);

    var lagent = Types.Agent{ .id = 1, .ports = @splat(null) };
    var ragent = Types.Agent{ .id = 2, .ports = @splat(null) };
    const eq = Equation{ .lhs = &lagent, .rhs = &ragent };

    try fetcher.push(eq);
    const fetched = fetcher.fetch() orelse return error.TestExpectedFetch;
    try std.testing.expectEqual(eq.lhs, fetched.lhs);
    try std.testing.expectEqual(eq.rhs, fetched.rhs);
}

//! Module that contains basic types for interaction nets logic.
const std = @import("std");

const Config = @import("config");

const memory = @import("memory.zig");

const number_of_ports = 10;

pub const Ports = [number_of_ports]Value;

pub const Agent = struct {
    id: Id,
    ports: Ports = undefined,
    pub const Id = u32;
    pub const Arity = u8;
};

pub const Name = struct {
    box: std.atomic.Value(usize),
    arrivals: if (count_arrivals) std.atomic.Value(u8) else void,

    pub const empty: Name = .{
        .box = .init(empty_box),
        .arrivals = if (count_arrivals) .init(0) else {},
    };

    const count_arrivals = Config.check_name_arrivals;

    const empty_box: usize = 0;
    const name_tag: usize = 1;

    comptime {
        std.debug.assert(@alignOf(Agent) > name_tag and @alignOf(Name) > name_tag);
        std.debug.assert(count_arrivals or @sizeOf(Name) == @sizeOf(usize));
    }

    fn encode(val: Value) usize {
        return switch (val) {
            .agent => |agent| @intFromPtr(agent),
            .name => |name| @intFromPtr(name) | name_tag,
            .special => unreachable,
        };
    }

    fn decode(word: usize) ?Value {
        if (word == empty_box) return null;
        if (word & name_tag != 0) return .{ .name = @ptrFromInt(word & ~name_tag) };
        return .{ .agent = @ptrFromInt(word) };
    }

    pub fn assertArrival(name: *Name) void {
        if (!count_arrivals) return;
        const prev = name.arrivals.fetchAdd(1, .monotonic);
        if (prev >= 2) @panic("name visited more than twice");
    }

    pub fn swap(name: *Name, val: Value) ?Value {
        return decode(name.box.swap(encode(val), .acq_rel));
    }

    pub fn load(name: *const Name) ?Value {
        return decode(name.box.load(.acquire));
    }

    /// This function is used to check if the name chain
    /// contains an agent at the end or not
    /// without changing the chain
    pub fn unwind(name: *const Name) ?*Agent {
        var node = name;
        while (node.load()) |val| {
            switch (val) {
                .name => |next| node = next,
                .agent => |agent| return agent,
                .special => unreachable,
            }
        }
        return null;
    }
};

pub const Special = union(enum) {
    float: f32,
    integer: i32,

    pub fn coerceFloat(self: Special) f32 {
        switch (self) {
            .float => |float| return float,
            .integer => |integer| return @floatFromInt(integer),
        }
    }

    pub fn add(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = self.integer + other.integer };
        } else {
            return .{ .float = self.coerceFloat() + other.coerceFloat() };
        }
    }
    pub fn sub(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = self.integer - other.integer };
        } else {
            return .{ .float = self.coerceFloat() - other.coerceFloat() };
        }
    }
    pub fn mul(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = self.integer * other.integer };
        } else {
            return .{ .float = self.coerceFloat() * other.coerceFloat() };
        }
    }
    pub fn div(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = @divFloor(self.integer, other.integer) };
        } else {
            return .{ .float = self.coerceFloat() / other.coerceFloat() };
        }
    }

    pub fn eq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer == other.integer;
        } else {
            // no guarantees
            return self.coerceFloat() == other.coerceFloat();
        }
    }
    pub fn neq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer != other.integer;
        } else {
            // no guarantees
            return self.coerceFloat() != other.coerceFloat();
        }
    }

    pub fn less(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer < other.integer;
        } else {
            return self.coerceFloat() < other.coerceFloat();
        }
    }
    pub fn leq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer <= other.integer;
        } else {
            return self.coerceFloat() <= other.coerceFloat();
        }
    }
    pub fn greater(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer > other.integer;
        } else {
            return self.coerceFloat() > other.coerceFloat();
        }
    }
    pub fn geq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer >= other.integer;
        } else {
            return self.coerceFloat() >= other.coerceFloat();
        }
    }

    pub fn parse(str: []const u8) !Special {
        return if (std.mem.findScalar(u8, str, '.')) |_|
            .{ .float = try std.fmt.parseFloat(f32, str) }
        else
            .{ .integer = try std.fmt.parseInt(i32, str, 10) };
    }
};

pub const Value = union(enum) {
    name: *Name,
    agent: *Agent,

    // specials are special in the fact that they can not interact directly
    special: Special,

    pub fn getAgent(val: Value) ?*Agent {
        return switch (val) {
            .name => |name| name.unwind(),
            .agent => |agent| agent,
            else => unreachable,
        };
    }

    pub fn resolve(val: Value, heap: memory.Heap(Name)) Value {
        var cur = val;
        while (cur == .name) {
            const parked = cur.name.load() orelse break;
            heap.freeOne(cur.name);
            cur = parked;
        }
        return cur;
    }
};

pub const EquationUnnormalized = struct {
    lhs: Value,
    rhs: Value,
};

pub const Equation = struct {
    lhs: *Agent,
    rhs: *Agent,
};

test "resolve" {
    const gpa = std.testing.allocator;

    var basic_name_heap: memory.BasicHeap(Name) = try .init(gpa, 20);
    defer basic_name_heap.deinit(gpa);

    var basic_agent_heap: memory.BasicHeap(Agent) = try .init(gpa, 20);
    defer basic_agent_heap.deinit(gpa);

    var name_heap = basic_name_heap.heap();
    var agent_heap = basic_agent_heap.heap();
    const Optional = memory.BasicHeap(Name).Optional;

    const a = try name_heap.allocOne();
    const b = try name_heap.allocOne();
    const agent = try agent_heap.allocOne();
    agent.* = .{ .id = 0 };
    a.* = .empty;
    b.* = .empty;
    try std.testing.expect(a.swap(.{ .name = b }) == null);
    try std.testing.expect(b.swap(.{ .agent = agent }) == null);
    try std.testing.expectEqual(agent, a.unwind().?);

    const resolved = (Value{ .name = a }).resolve(name_heap);
    try std.testing.expectEqual(agent, resolved.agent);
    try std.testing.expectEqual(.free, @as(*Optional, @fieldParentPtr("item", a)).*);
    try std.testing.expectEqual(.free, @as(*Optional, @fieldParentPtr("item", b)).*);

    const c = try name_heap.allocOne();
    c.* = .empty;
    try std.testing.expectEqual(c, (Value{ .name = c }).resolve(name_heap).name);
    try std.testing.expect(c.unwind() == null);
}

test "Name: second arrival gets the parked value" {
    var a: Agent = .{ .id = 0 };
    var b: Agent = .{ .id = 1 };
    var n: Name = .empty;

    try std.testing.expect(n.load() == null);
    try std.testing.expect(n.swap(.{ .agent = &a }) == null);
    try std.testing.expectEqual(&a, n.swap(.{ .agent = &b }).?.agent);
}

test "Name: arrivals are counted when enabled" {
    if (!Name.count_arrivals) return error.SkipZigTest;

    var n: Name = .empty;
    n.assertArrival();
    n.assertArrival();
    try std.testing.expectEqual(2, n.arrivals.load(.monotonic));
}

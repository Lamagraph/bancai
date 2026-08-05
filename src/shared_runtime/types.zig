//! Module that contains basic types for interaction nets logic.
const std = @import("std");

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
    port: ?Value,

    /// This procedure makes it so that the chain starting with
    /// "name" (argument) is shortened to a direct link (or null in case there is no agent).
    /// Intermediate names are freed.
    ///
    /// Example: a -> b -> c -> Agent() >> unchain(a); >> a -> Agent()
    ///          a -> b -> c -> null    >> unchain(a); >> a -> null
    pub fn unchain(name: *Name, heap: memory.Heap(Name)) void {
        var node = if ((name.port orelse return) == .name) name.port.?.name else return;
        while (node.port) |port| {
            if (port == .name) {
                heap.freeOne(node);
                node = port.name;
            } else break;
        }

        name.port = node.port;
        heap.freeOne(node);
    }

    /// This function is used to check if the name chain
    /// contains an agent at the end or not
    /// without changing the chain
    pub fn unwind(name: *Name) ?*Agent {
        var node = name;
        while (node.port) |port| {
            switch (port) {
                .name => |new_name| {
                    node = new_name;
                },
                .agent => |agent| return agent,
                else => unreachable,
            }
        }
        return null;
    }

    /// Like unchain, but instead returns the last in the chain, erasing every name before it.
    ///
    /// a -> b -> c -> Agent() >> traverseFree(a); >> c -> Agent()
    pub fn traverseFree(name: *Name, heap: memory.Heap(Name)) *Name {
        var node = name;
        while (node.port) |port| {
            if (port == .name) {
                heap.freeOne(node);
                node = port.name;
            } else {
                break;
            }
        }
        return node;
    }

    pub fn is_open(name: *Name) bool {
        return if (name.port) |_| false else true;
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
};

pub const EquationUnnormalized = struct {
    lhs: Value,
    rhs: Value,
};

pub const Equation = struct {
    lhs: *Agent,
    rhs: *Agent,
};

test "unchain" {
    const gpa = std.testing.allocator;

    var basic_name_heap: memory.BasicHeap(Name) = try .init(gpa, 20);
    defer basic_name_heap.deinit(gpa);

    var basic_agent_heap: memory.BasicHeap(Agent) = try .init(gpa, 20);
    defer basic_agent_heap.deinit(gpa);

    var name_heap = basic_name_heap.heap();
    var agent_heap = basic_agent_heap.heap();
    // a -> b -> c -> Agent() ===> a -> Agent()

    const a = try name_heap.allocOne();
    const b = try name_heap.allocOne();
    const c = try name_heap.allocOne();
    const agent = try agent_heap.allocOne();
    agent.* = .{ .id = 0 };
    a.port = .{ .name = b };
    b.port = .{ .name = c };
    c.port = .{ .agent = agent };
    a.unchain(name_heap);
    // b and c get cleaned, a -> agent
    const Optional = memory.BasicHeap(Name).Optional;
    try std.testing.expectEqual(.free, @as(*Optional, @fieldParentPtr("item", b)).*);
    try std.testing.expectEqual(.free, @as(*Optional, @fieldParentPtr("item", c)).*);
    try std.testing.expectEqual(a.port.?.agent, agent);
}

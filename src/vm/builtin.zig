//! Builtin agents logic.
const std = @import("std");
const Core = @import("core.zig");
const Types = @import("shared_runtime").Types;
const Printing = @import("printing");
const AST = @import("ast");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const EquationUnnormalized = Types.EquationUnnormalized;

const Config = @import("config");

pub const BuiltinAgentError = error{
    Exiter,
    ArityMismatch,
    NoRuleSpecified,
    BadSecondaryArgument,
} || std.mem.Allocator.Error;

const BuiltinSignature = *const fn (*Core, *Agent, *Agent) BuiltinAgentError!void;

pub var BuiltinTable: std.AutoHashMap(Agent.Id, BuiltinSignature) = undefined;

const BuiltinAgent = struct {
    name: []const u8,
    arity: Agent.Arity,
    impl: BuiltinSignature,
};

pub const BuiltinNameMap = comptime_init: {
    var kvs: [builtin_agents.len]struct { []const u8, Agent.Id } = undefined;
    for (builtin_agents, 0..) |builtin_ag, idx| {
        kvs[idx] = .{ builtin_ag.name, @as(Agent.Id, @intCast(idx)) };
    }
    break :comptime_init std.StaticStringMap(Agent.Id).initComptime(&kvs);
};

pub const user_agent_id_start = builtin_agents.len;

pub fn isBuiltinAgent(id: Agent.Id) bool {
    return id < user_agent_id_start;
}

pub fn init(allocator: std.mem.Allocator) !void {
    BuiltinTable = std.AutoHashMap(Agent.Id, BuiltinSignature).init(allocator);
    for (builtin_agents) |builtin_ag| {
        try BuiltinTable.put(BuiltinNameMap.get(builtin_ag.name).?, builtin_ag.impl);
    }
}
pub fn deinit() void {
    BuiltinTable.deinit();
}

pub const number_builtin_ident = AST.number_special_ident;

// Making this empty makes there be no
// builtin agents. TODO: use compile flag for that
//
// Maybe make the "Abc0" , ... , "Abc10" agents be placed here at compile time
pub const builtin_agents = [_]BuiltinAgent{
    .{ .name = "Exiter", .arity = 0, .impl = exiter },

    .{ .name = "Eraser", .arity = 0, .impl = eraser },

    // Dups
    .{ .name = "Dup", .arity = 2, .impl = dupReference },
    .{ .name = "Dup2", .arity = 2, .impl = dupReference },
    .{ .name = "Dup3", .arity = 3, .impl = dupReference },
    .{ .name = "Dup4", .arity = 4, .impl = dupReference },

    // Tuples
    .{ .name = "Tuple0", .arity = 0, .impl = tuple },
    .{ .name = "Tuple1", .arity = 1, .impl = tuple },
    .{ .name = "Tuple2", .arity = 2, .impl = tuple },
    .{ .name = "Tuple3", .arity = 3, .impl = tuple },
    .{ .name = "Tuple4", .arity = 4, .impl = tuple },
    .{ .name = "Tuple5", .arity = 5, .impl = tuple },
    .{ .name = "Tuple6", .arity = 6, .impl = tuple },

    // numbers
    .{ .name = number_builtin_ident, .arity = 1, .impl = number },
    .{ .name = "Add", .arity = 2, .impl = unbuiltin },
    .{ .name = "Sub", .arity = 2, .impl = unbuiltin },
    .{ .name = "Mul", .arity = 2, .impl = unbuiltin },
    .{ .name = "Div", .arity = 2, .impl = unbuiltin },

    // lists
    .{ .name = "Cons", .arity = 2, .impl = unbuiltin },
    .{ .name = "Nil", .arity = 0, .impl = unbuiltin },
    .{ .name = "MakeRandomList", .arity = 1, .impl = make_random_list },
};

// Add more builtin agents logic here

pub fn exiter(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    _ = c;
    _ = self;
    _ = other;
    return BuiltinAgentError.Exiter;
}

pub fn unbuiltin(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    _ = c;
    _ = self;
    _ = other;
    return BuiltinAgentError.NoRuleSpecified;
}

/// Module of functions used by the builtin eraser
pub const Eraser = struct {
    fn createEraser(c: *Core) !*Agent {
        return c.createAgent(BuiltinNameMap.get("Eraser").?);
    }

    pub fn erase(c: *Core, agent: *Agent) !void {
        if (agent.rc > 1) {
            agent.rc -= 1;
            return;
        }
        defer c.local_ctx.freeOneAgent(agent);
        // This unwrap may fail in case of (w, F(w)) net on "free w;"
        const ag_arity = c.runtime.agent_arities.arityOf(agent.id);
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx].?;
            port_switch: switch (port) {
                .name => |name| {
                    if (name.port) |name_port| {
                        defer c.local_ctx.name_heap.freeOne(name);
                        continue :port_switch name_port;
                    } else {
                        // If the name is free yet, create eraser on its port
                        name.port = Value{ .agent = try createEraser(c) };
                    }
                },
                .agent => |_agent| {
                    try erase(c, _agent);
                },
                .special => {},
            }
        }
    }
};

pub fn eraser(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    defer c.local_ctx.freeOneAgent(self);

    try Eraser.erase(c, other);
}

const copying_duplicator = struct {
    const CopyContext = struct {
        c: *Core,
        duplicator_arity: Agent.Arity,
        duplicator_id: Agent.Id,
        names_map: *std.AutoHashMap(*Name, DuplicatingName),
        arena: std.mem.Allocator,
    };

    pub const DuplicatingName = union(enum) {
        /// A name appearing twice inside the same subnet:
        /// (w, F(w))
        inner: struct { next_name: ?*Name },
        /// A name that connects two agents with their auxillary ports.
        outer: struct {
            original_port: *Value,
            dup_agent: *Agent,
        },
    };

    pub fn makeCopy(ctx: *const CopyContext, port_idx: usize, agent: *Agent) !*Agent {
        const ag_copy = try ctx.c.createAgent(agent.id);
        const ag_arity = ctx.c.runtime.agent_arities.arityOf(agent.id);
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx].?;
            switch (port) {
                .name => |connected_name| {
                    const stored_ptr = ctx.names_map.getPtr(connected_name).?;
                    switch (stored_ptr.*) {
                        .inner => |inner| {
                            if (inner.next_name) |next_name| {
                                stored_ptr.inner.next_name = null;
                                ag_copy.ports[idx] = .{ .name = next_name };
                            } else {
                                const next_name = try ctx.c.createEmptyName();
                                stored_ptr.inner.next_name = next_name;
                                ag_copy.ports[idx] = .{ .name = next_name };
                            }
                        },
                        .outer => |outer| {
                            const name = try ctx.c.createEmptyName();
                            ag_copy.ports[idx] = .{ .name = name };
                            outer.dup_agent.ports[port_idx] = .{ .name = name };
                        },
                    }
                },
                .agent => |connected_agent| {
                    ag_copy.ports[idx] = Value{ .agent = try makeCopy(ctx, port_idx, connected_agent) };
                },
                .special => |special| {
                    ag_copy.ports[idx] = Value{ .special = special };
                },
            }
        }
        return ag_copy;
    }
    pub fn copyNames(ctx: *const CopyContext, agent: *Agent) !*Agent {
        const ag_arity = ctx.c.runtime.agent_arities.arityOf(agent.id);
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx].?;
            port_switch: switch (port) {
                .name => |connected_name| {
                    const traversed = connected_name.traverseFree(ctx.c.local_ctx.name_heap);
                    // This means that after copyNames, there are no names that do not have null ports.
                    if (traversed.port) |traversed_port| {
                        ctx.c.local_ctx.name_heap.freeOne(traversed);
                        agent.ports[idx] = traversed_port;
                        continue :port_switch traversed_port;
                    } else {
                        agent.ports[idx] = Value{ .name = traversed };
                        if (ctx.names_map.getPtr(traversed)) |duplicating_name| {
                            duplicating_name.* = .{
                                .inner = .{
                                    .next_name = null,
                                },
                            };
                        } else {
                            try ctx.names_map.put(traversed, .{
                                .outer = .{
                                    .original_port = &agent.ports[idx].?,
                                    .dup_agent = try ctx.c.createAgent(ctx.duplicator_id),
                                },
                            });
                        }
                    }
                },
                .agent => |connected_agent| {
                    agent.ports[idx] = Value{ .agent = try copyNames(ctx, connected_agent) };
                },
                .special => {},
            }
        }
        return agent;
    }
};

pub fn dupCopy(c: *Core, self: *Agent, ag: *Agent) BuiltinAgentError!void {
    defer c.local_ctx.freeOneAgent(self);
    // This allocates :(

    var arena = std.heap.ArenaAllocator.init(c.runtime.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arity = c.runtime.agent_arities.arityOf(self.id);
    var names_map = std.AutoHashMap(*Name, copying_duplicator.DuplicatingName).init(allocator);
    defer names_map.deinit();

    const ctx: copying_duplicator.CopyContext = .{
        .arena = allocator,
        .c = c,
        .duplicator_arity = c.runtime.agent_arities.arityOf(self.id),
        .duplicator_id = self.id,
        .names_map = &names_map,
    };

    _ = try copying_duplicator.copyNames(&ctx, ag);

    if (self.ports[0].? == .name and self.ports[0].?.name.is_open()) {
        self.ports[0].?.name.port = Value{ .agent = ag };
    } else {
        try c.local_ctx.pushUrgent(EquationUnnormalized{
            .lhs = self.ports[0].?,
            .rhs = Value{ .agent = ag },
        });
    }

    for (1..arity) |port_idx| {
        const port = self.ports[port_idx].?;
        const copy = try copying_duplicator.makeCopy(&ctx, port_idx, ag);
        if (port == .name and port.name.is_open()) {
            port.name.port = Value{ .agent = copy };
        } else {
            const eq = EquationUnnormalized{
                .lhs = port,
                .rhs = Value{ .agent = copy },
            };
            try c.local_ctx.pushUrgent(eq);
        }
    }

    var it = names_map.iterator();

    while (it.next()) |entry| {
        const outer = if (entry.value_ptr.* == .outer) entry.value_ptr.outer else continue;
        const self_name = entry.key_ptr.*;
        const new_self_name = try c.createEmptyName();
        outer.original_port.name = new_self_name;
        self_name.port = .{ .agent = outer.dup_agent };
        outer.dup_agent.ports[0] = .{ .name = new_self_name };
    }
}

pub fn dupReference(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    defer c.local_ctx.freeOneAgent(self);
    const dup_arity = c.runtime.agent_arities.arityOf(self.id);
    other.rc += dup_arity - 1;
    for (0..dup_arity) |idx| {
        const eq = EquationUnnormalized{
            .lhs = self.ports[idx].?,
            .rhs = .{ .agent = other },
        };
        try c.local_ctx.pushEquation(eq);
    }
}

pub fn tuple(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    if (self.id != other.id) {
        return BuiltinAgentError.NoRuleSpecified;
    }
    defer c.local_ctx.freeOneAgent(self);
    defer c.local_ctx.freeOneAgent(other);
    const arity = c.runtime.agent_arities.arityOf(self.id);

    for (0..arity) |port_idx| {
        const eq = EquationUnnormalized{
            .lhs = self.ports[port_idx].?,
            .rhs = other.ports[port_idx].?,
        };

        try c.local_ctx.pushEquation(eq);
    }
}

pub fn number(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const adder_id = comptime BuiltinNameMap.get("Add").?;
    const mult_id = comptime BuiltinNameMap.get("Mul").?;
    const div_id = comptime BuiltinNameMap.get("Div").?;
    const sub_id = comptime BuiltinNameMap.get("Sub").?;

    if (other.id != adder_id and other.id != mult_id and other.id != div_id and other.id != sub_id)
        return BuiltinAgentError.NoRuleSpecified;

    const self_special = self.ports[0].?.special;

    const getSecondValue = struct {
        pub fn getSecondValue(val: Value, _c: *Core) ?Special {
            switch (val) {
                .name => |name| {
                    if (name.unwind()) |agent| {
                        name.unchain(_c.local_ctx.name_heap);
                        _c.local_ctx.freeOneName(name);
                        defer _c.local_ctx.freeOneAgent(agent);
                        return agent.ports[0].?.special;
                    } else {
                        return null;
                    }
                },
                .agent => |agent| {
                    return getSecondValue(agent.ports[0].?, _c);
                },
                .special => |special| return special,
            }
        }
    }.getSecondValue;

    const sv = getSecondValue(other.ports[1].?, c) orelse {
        // We switch places: self with secondary argument port
        const port = other.ports[1].?;
        other.ports[1] = .{ .agent = self };
        const eq = EquationUnnormalized{
            .lhs = .{ .agent = other },
            .rhs = port,
        };
        try c.local_ctx.pushEquation(eq);
        return;
    };
    defer c.local_ctx.freeOneAgent(self);
    defer c.local_ctx.freeOneAgent(other);

    const ret = switch (other.id) {
        adder_id => Special.add(sv, self_special),
        mult_id => Special.mul(sv, self_special),
        div_id => Special.div(sv, self_special),
        sub_id => Special.sub(sv, self_special),
        else => unreachable,
    };

    const ret_ag = try c.createAgent(self.id);
    ret_ag.ports[0] = Value{ .special = ret };

    const eq = EquationUnnormalized{
        .lhs = other.ports[0].?,
        .rhs = .{ .agent = ret_ag },
    };
    try c.local_ctx.pushUrgent(eq);
}

pub fn make_random_list(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const number_id = BuiltinNameMap.get(number_builtin_ident).?;
    if (other.id != number_id) return BuiltinAgentError.NoRuleSpecified;

    const num_special = other.ports[0].?.special;
    const num = switch (num_special) {
        .integer => |i| i,
        .float => return BuiltinAgentError.BadSecondaryArgument,
    };

    defer c.local_ctx.agent_heap.freeOne(self);
    defer c.local_ctx.agent_heap.freeOne(other);

    var prng: std.Random.DefaultPrng = .init(blk: {
        var buffer: [8]u8 = undefined;
        c.runtime.io.random(buffer[0..]);
        break :blk std.mem.readInt(u64, buffer[0..], .native);
    });
    const rand = prng.random();

    const lst = blk: {
        if (num > 0) {
            const ag = try c.createAgent(BuiltinNameMap.get("Cons").?);
            ag.ports[0] = Value{ .agent = try c.createNumberAgent(.{ .integer = rand.intRangeAtMost(i32, -10000, 10000) }) };
            break :blk ag;
        } else {
            break :blk try c.createAgent(BuiltinNameMap.get("Nil").?);
        }
    };

    var node = lst;
    for (1..@as(usize, @intCast(num))) |_| {
        var new_node = try c.createAgent(BuiltinNameMap.get("Cons").?);
        new_node.ports[0] = Value{ .agent = try c.createNumberAgent(.{ .integer = rand.intRangeAtMost(i32, -10000, 10000) }) };
        node.ports[1] = Value{ .agent = new_node };
        node = new_node;
    }

    if (num > 0) {
        node.ports[1] = Value{ .agent = try c.createAgent(BuiltinNameMap.get("Nil").?) };
    }

    const eq = EquationUnnormalized{
        .lhs = self.ports[0].?,
        .rhs = Value{ .agent = lst },
    };
    try c.local_ctx.pushEquation(eq);
}

//! Builtin agents logic.
const std = @import("std");
const Core = @import("core.zig");
const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
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

const dups = init: {
    const ref_max_arity = 4;
    const copy_max_arity = 4;
    const inpla_max_arity = 4;
    const default_impl = dupCopy;
    const default_arity = 2;
    const default_max_arity = 4;

    const default_name = "Dup";
    const ref_name = "DupRef";
    const copy_name = "DupCopy";
    const inpla_name = "DupInpla";

    // + 1 because default_arity..max_arity is end inclusive. + 1 for arityless name
    const dup_cnt =
        (ref_max_arity - default_arity + 1 + 1) +
        (copy_max_arity - default_arity + 1 + 1) +
        (default_max_arity - default_arity + 1 + 1) +
        (inpla_max_arity - default_arity + 1 + 1);

    var lst: [dup_cnt]BuiltinAgent = undefined;

    var item_idx: comptime_int = 0;

    {
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}", .{default_name}), .arity = default_arity, .impl = default_impl };
        item_idx += 1;
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}", .{ref_name}), .arity = default_arity, .impl = dupReference };
        item_idx += 1;
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}", .{copy_name}), .arity = default_arity, .impl = dupCopy };
        item_idx += 1;
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}", .{inpla_name}), .arity = default_arity, .impl = dupInpla };
        item_idx += 1;
    }

    for (default_arity..default_max_arity + 1) |arity_idx| {
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}{}", .{ default_name, arity_idx }), .arity = arity_idx, .impl = default_impl };
        item_idx += 1;
    }

    for (default_arity..ref_max_arity + 1) |arity_idx| {
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}{}", .{ ref_name, arity_idx }), .arity = arity_idx, .impl = dupReference };
        item_idx += 1;
    }

    for (default_arity..copy_max_arity + 1) |arity_idx| {
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}{}", .{ copy_name, arity_idx }), .arity = arity_idx, .impl = dupCopy };
        item_idx += 1;
    }

    for (default_arity..inpla_max_arity + 1) |arity_idx| {
        lst[item_idx] = .{ .name = std.fmt.comptimePrint("{s}{}", .{ inpla_name, arity_idx }), .arity = arity_idx, .impl = dupInpla };
        item_idx += 1;
    }

    std.debug.assert(item_idx == dup_cnt);

    break :init lst;
};

const predefined = [_]BuiltinAgent{
    .{ .name = "Exiter", .arity = 0, .impl = exiter },

    .{ .name = "Eraser", .arity = 0, .impl = eraser },

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
    // Order matters.
    .{ .name = "AddRev", .arity = 2, .impl = unbuiltin },
    .{ .name = "SubRev", .arity = 2, .impl = unbuiltin },
    .{ .name = "MulRev", .arity = 2, .impl = unbuiltin },
    .{ .name = "DivRev", .arity = 2, .impl = unbuiltin },

    // lists
    .{ .name = "Cons", .arity = 2, .impl = unbuiltin },
    .{ .name = "Nil", .arity = 0, .impl = unbuiltin },
    .{ .name = "MakeRandomList", .arity = 1, .impl = make_random_list },
};

pub fn isDuplicator(id: Agent.Id) bool {
    return id >= predefined.len and id < (predefined.len + dups.len);
}

pub const builtin_agents = predefined ++ dups;

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
            const port = agent.ports[idx];
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
        /// A link to the duplicator.
        names_map: *std.ArrayList(*Agent),
        /// As we traverse the subnet tree several time, the structure doesn't change and we meet
        /// duplicators in the exact order as they were created, thus we can use a basic index.
        dup_idx: u32,
        gpa: std.mem.Allocator,
    };

    fn updateDuplicator(ctx: *CopyContext, port_idx: usize) !*Name {
        const dup = ctx.names_map.items[ctx.dup_idx];

        const new_name = try ctx.c.createEmptyName();
        dup.ports[port_idx] = .{ .name = new_name };
        ctx.dup_idx += 1;
        return new_name;
    }

    pub fn makeCopy(ctx: *CopyContext, port_idx: usize, agent: *Agent) !*Agent {
        const ag_copy = try ctx.c.createAgent(agent.id);
        const ag_arity = ctx.c.runtime.agent_arities.arityOf(agent.id);
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx];
            switch (port) {
                .name => |connected_name| {
                    // The port is null.
                    std.debug.assert(connected_name.port == null);

                    ag_copy.ports[idx] = Value{ .name = try updateDuplicator(ctx, port_idx) };
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

    fn createDuplicatorReference(ctx: *const CopyContext, val: Value) !*Name {
        const new_name = try ctx.c.createEmptyName();
        const dup = try ctx.c.createAgent(ctx.duplicator_id);
        const eq = EquationUnnormalized{
            .lhs = .{ .agent = dup },
            .rhs = val,
        };
        // This equation is still uninitialized!!!
        try ctx.c.local_ctx.pushEquation(eq);
        try ctx.names_map.append(ctx.gpa, dup);
        dup.ports[0] = .{ .name = new_name };

        return new_name;
    }

    pub fn copyNames(ctx: *const CopyContext, agent: *Agent) !*Agent {
        const ag_arity = ctx.c.runtime.agent_arities.arityOf(agent.id);
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx];
            port_switch: switch (port) {
                .name => |connected_name| {
                    const traversed = connected_name.traverseFree(ctx.c.local_ctx.name_heap);
                    // This means that after copyNames, there are no names that do not have null ports.
                    if (traversed.port) |traversed_port| {
                        ctx.c.local_ctx.name_heap.freeOne(traversed);
                        agent.ports[idx] = traversed_port;
                        continue :port_switch traversed_port;
                    } else {
                        agent.ports[idx] = .{ .name = try createDuplicatorReference(ctx, .{ .name = traversed }) };
                    }
                },
                .agent => |connected_agent| {
                    agent.ports[idx] =
                        if (isDuplicator(connected_agent.id))
                            Value{ .name = try createDuplicatorReference(ctx, .{ .agent = connected_agent }) }
                        else
                            Value{ .agent = try copyNames(ctx, connected_agent) };
                },
                .special => {},
            }
        }
        return agent;
    }
};

/// We want to believe that whenever this is executing, the equation_fetcher is blocked. Otherwise,
/// the equation queue may have uninitialized equations. See copying_duplicator.copyNames.
/// However, we need to block it only when the names_map is nonempty.
pub fn dupCopy(c: *Core, self: *Agent, ag: *Agent) BuiltinAgentError!void {
    if (isDuplicator(ag.id)) {
        return delta_delta(c, self, ag);
    }

    defer c.local_ctx.freeOneAgent(self);
    // This allocates :(

    const gpa = c.runtime.gpa;

    const arity = c.runtime.agent_arities.arityOf(self.id);
    var names_map: std.ArrayList(*Agent) = .empty;
    defer names_map.deinit(gpa);

    var ctx: copying_duplicator.CopyContext = .{
        .c = c,
        .duplicator_arity = c.runtime.agent_arities.arityOf(self.id),
        .duplicator_id = self.id,
        .dup_idx = undefined,
        .names_map = &names_map,
        .gpa = gpa,
    };

    _ = try copying_duplicator.copyNames(&ctx, ag);

    try c.local_ctx.pushEquation(EquationUnnormalized{
        .lhs = self.ports[0],
        .rhs = Value{ .agent = ag },
    });

    for (1..arity) |port_idx| {
        ctx.dup_idx = 0;
        const port = self.ports[port_idx];
        const copy = try copying_duplicator.makeCopy(&ctx, port_idx, ag);
        const eq = EquationUnnormalized{
            .lhs = port,
            .rhs = Value{ .agent = copy },
        };
        try c.local_ctx.pushEquation(eq);
    }
}

pub const reference_duplicator = struct {
    /// Copy on write. We copy the agent. After that, all its
    /// ports are looked at by two agents (the original and the copy).
    /// If the original has an empty port, then it is a nested pattern matching
    /// problem.
    pub fn cow(c: *Core, agent: *Agent) !*Agent {
        std.debug.assert(agent.rc > 1);
        const dup_copy_id = comptime BuiltinNameMap.get("DupCopy2").?;
        const arity = c.runtime.agent_arities.arityOf(agent.id);

        agent.rc -= 1;
        const new_me = try c.createAgent(agent.id);

        for (0..arity) |port_idx| {
            if (agent.ports[port_idx] == .special) {
                new_me.ports[port_idx] = agent.ports[port_idx];
                break;
            }

            const possible_agent = agent.ports[port_idx].getAgent();
            if (possible_agent) |port_agent| {
                port_agent.rc += 1;
                new_me.ports[port_idx] = .{ .agent = port_agent };
            } else {
                @branchHint(.cold);
                const name = agent.ports[port_idx].name.traverseFree(c.local_ctx.name_heap);
                // Meaning, Tuple2(w, f(w)) type of net is impossible to be used with DupRef
                const dup_copy = try c.createAgent(dup_copy_id);
                name.port = .{ .agent = dup_copy };

                const orig_port_name = try c.createEmptyName();
                const copy_port_name = try c.createEmptyName();
                dup_copy.ports[0] = .{ .name = orig_port_name };
                dup_copy.ports[1] = .{ .name = copy_port_name };
                agent.ports[port_idx] = .{ .name = orig_port_name };
                new_me.ports[port_idx] = .{ .name = copy_port_name };
            }
        }

        return new_me;
    }
};

pub fn dupReference(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    defer c.local_ctx.freeOneAgent(self);
    const dup_arity = c.runtime.agent_arities.arityOf(self.id);
    other.rc += dup_arity - 1;
    for (0..dup_arity) |idx| {
        const eq = EquationUnnormalized{
            .lhs = self.ports[idx],
            .rhs = .{ .agent = other },
        };
        try c.local_ctx.pushEquation(eq);
    }
}

/// Clasisical interactions nets Delta~Delta agents interactions. It also needs to handle the case where
/// deltas have different arities, which has the semantic as if every delta was rewritten using Delta2.
pub fn delta_delta(c: *Core, _self: *Agent, _other: *Agent) BuiltinAgentError!void {
    var lagent = _self;
    var ragent = _other;

    const larity = c.runtime.agent_arities.arityOf(lagent.id);
    const rarity = c.runtime.agent_arities.arityOf(ragent.id);

    if (larity == rarity) {
        defer {
            c.local_ctx.freeOneAgent(lagent);
            c.local_ctx.freeOneAgent(ragent);
        }
        const arity = larity;

        for (0..arity) |port_idx| {
            const eq = EquationUnnormalized{
                .lhs = lagent.ports[port_idx],
                .rhs = ragent.ports[port_idx],
            };

            try c.local_ctx.pushEquation(eq);
        }
    } else {
        if (rarity < larity) {
            std.mem.swap(*Agent, &lagent, &ragent);
        }
        // larity < rarity

        const low_arity = larity;
        const high_arity = rarity;

        const weakness = high_arity - low_arity;
        for (1..larity) |port_idx| {
            const eq = EquationUnnormalized{
                .lhs = lagent.ports[port_idx],
                .rhs = ragent.ports[port_idx + weakness],
            };

            try c.local_ctx.pushEquation(eq);
        }
        const weaker_dup = try c.createAgent(getDupWeaker(rarity, ragent.id, weakness).?);

        for (0..weakness) |port_idx| {
            const eq = EquationUnnormalized{
                .lhs = ragent.ports[port_idx],
                .rhs = weaker_dup.ports[port_idx],
            };

            try c.local_ctx.pushEquation(eq);
        }

        const weakness_eq = EquationUnnormalized{
            .lhs = .{ .agent = weaker_dup },
            .rhs = lagent.ports[0],
        };
        try c.local_ctx.pushEquation(weakness_eq);
    }
}

inline fn nonNull(comptime T: type, f: anytype, args: anytype, generic_null: T) ?T {
    const val: T = @call(.auto, f, args);
    return if (val == generic_null) null else val;
}

fn getDupWeaker(arity: Agent.Arity, id: Agent.Id, weakness: Agent.Arity) ?Agent.Id {
    return if (arity - weakness < 2) null else id - weakness;
}

/// A variant semantically identical to inpla version of duplicators. That is, it is a left-eager duplicator:
/// it walks on the left-most ports of an agent tree, leaving a duplicator on the remaining ports.
pub fn dupInpla(c: *Core, self: *Agent, _other: *Agent) BuiltinAgentError!void {
    if (isDuplicator(_other.id)) {
        return delta_delta(c, self, _other);
    }
    defer c.local_ctx.freeOneAgent(self);

    const dup_arity = c.runtime.agent_arities.arityOf(self.id);

    var other = _other;

    var lookat: [Types.number_of_ports]*Agent = undefined;

    const FallbackArray = union(enum) {
        no_fallback,
        fallback: [Types.number_of_ports]*Agent,
    };

    var fallbacks: FallbackArray = .no_fallback;

    while (nonNull(Agent.Arity, Runtime.ArityMap.arityOf, .{ &c.runtime.agent_arities, other.id }, 0)) |arity| {
        lookat[0] = other;
        for (1..dup_arity) |dup_idx| {
            const previous = if (fallbacks == .fallback) lookat[dup_idx] else null;
            lookat[dup_idx] = try c.createAgent(other.id);
            if (previous) |agent| {
                agent.ports[0] = .{ .agent = lookat[dup_idx] };
            }
        }

        for (1..arity) |port_idx| {
            const dup = try c.createAgent(self.id);

            const eq = EquationUnnormalized{
                .lhs = .{ .agent = dup },
                .rhs = other.ports[port_idx],
            };
            try c.local_ctx.pushEquation(eq);

            for (0..dup_arity) |dup_idx| {
                lookat[dup_idx].ports[port_idx] = .{ .name = try c.createEmptyName() };
                dup.ports[dup_idx] = lookat[dup_idx].ports[port_idx];
            }
        }

        if (fallbacks == .no_fallback) {
            fallbacks = .{ .fallback = undefined };
            @memcpy(fallbacks.fallback[0..dup_arity], lookat[0..dup_arity]);
        }

        const possible_new_other = other.ports[0];
        new_other_switch: switch (possible_new_other) {
            .agent => |new_other| {
                other = new_other;
            },
            .name => |name| {
                if (name.port) |port| {
                    continue :new_other_switch port;
                } else {
                    const dup = try c.createAgent(self.id);

                    name.port = .{ .agent = dup };

                    for (0..dup_arity) |dup_idx| {
                        dup.ports[dup_idx] = .{ .name = try c.createEmptyName() };
                        lookat[dup_idx].ports[0] = dup.ports[dup_idx];
                    }
                    break;
                }
            },
            .special => |special| {
                for (0..dup_arity) |dup_idx|
                    lookat[dup_idx].ports[0] = .{ .special = special };
                break;
            },
        }

        if (isDuplicator(other.id)) {
            const dup = try c.createAgent(self.id);
            const eq = Types.Equation{
                .lhs = dup,
                .rhs = other,
            };
            try c.local_ctx.equation_fetcher.push(eq);
            const previous = fallbacks.fallback;
            for (0..dup_arity) |dup_idx| {
                const name = try c.createEmptyName();
                previous[dup_idx].ports[0] = .{ .name = name };
                dup.ports[dup_idx] = .{ .name = name };
            }
            break;
        }
    } else {
        lookat[0] = other;
        for (1..dup_arity) |dup_idx| {
            const previous = if (fallbacks == .fallback) lookat[dup_idx] else null;
            lookat[dup_idx] = try c.createAgent(other.id);
            if (previous) |agent| {
                agent.ports[0] = .{ .agent = lookat[dup_idx] };
            }
        }
    }

    const roots = switch (fallbacks) {
        .no_fallback => lookat[0..dup_arity],
        .fallback => |*fallback| fallback[0..dup_arity],
    };
    for (roots, 0..) |root, idx| {
        try c.local_ctx.pushEquation(.{
            .lhs = self.ports[idx],
            .rhs = .{ .agent = root },
        });
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
            .lhs = self.ports[port_idx],
            .rhs = other.ports[port_idx],
        };

        try c.local_ctx.pushEquation(eq);
    }
}

pub fn number(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const adder_id = comptime BuiltinNameMap.get("Add").?;
    const mult_id = comptime BuiltinNameMap.get("Mul").?;
    const div_id = comptime BuiltinNameMap.get("Div").?;
    const sub_id = comptime BuiltinNameMap.get("Sub").?;
    const adder_rev_id = comptime BuiltinNameMap.get("AddRev").?;
    const mult_rev_id = comptime BuiltinNameMap.get("MulRev").?;
    const div_rev_id = comptime BuiltinNameMap.get("DivRev").?;
    const sub_rev_id = comptime BuiltinNameMap.get("SubRev").?;
    const rev_diff = adder_rev_id - adder_id;

    const first_id = adder_id;
    const last_id = div_rev_id;

    if (other.id < first_id or other.id > last_id)
        return BuiltinAgentError.NoRuleSpecified;

    const self_special = self.ports[0].special;

    const getSecondValue = struct {
        pub fn getSecondValue(val: Value, _c: *Core) ?Special {
            switch (val) {
                .name => |name| {
                    if (name.unwind()) |agent| {
                        name.unchain(_c.local_ctx.name_heap);
                        _c.local_ctx.freeOneName(name);
                        defer _c.local_ctx.freeOneAgent(agent);
                        return agent.ports[0].special;
                    } else {
                        return null;
                    }
                },
                .agent => |agent| {
                    const result = getSecondValue(agent.ports[0], _c);
                    if (result != null) {
                        _c.local_ctx.freeOneAgent(agent);
                    }
                    return result;
                },
                .special => |special| return special,
            }
        }
    }.getSecondValue;

    const sv = getSecondValue(other.ports[1], c) orelse {
        // We switch places: self with secondary argument port. But we do need to use a reversed
        // agent, because of div and sub.

        if (other.id < first_id + rev_diff) {
            other.id += rev_diff;
        } else {
            other.id -= rev_diff;
        }

        const port = other.ports[1];
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
        adder_rev_id => Special.add(self_special, sv),
        mult_rev_id => Special.mul(self_special, sv),
        div_rev_id => Special.div(self_special, sv),
        sub_rev_id => Special.sub(self_special, sv),
        else => unreachable,
    };

    const ret_ag = try c.createAgent(self.id);
    ret_ag.ports[0] = Value{ .special = ret };

    const eq = EquationUnnormalized{
        .lhs = other.ports[0],
        .rhs = .{ .agent = ret_ag },
    };
    try c.local_ctx.pushUrgent(eq);
}

pub fn make_random_list(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const number_id = BuiltinNameMap.get(number_builtin_ident).?;
    if (other.id != number_id) return BuiltinAgentError.NoRuleSpecified;

    const num_special = other.ports[0].special;
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
        .lhs = self.ports[0],
        .rhs = Value{ .agent = lst },
    };
    try c.local_ctx.pushEquation(eq);
}

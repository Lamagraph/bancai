const std = @import("std");

const AST = @import("ast");
const Lexer = AST.Lexer;

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Condition = Compilation.Condition;

const Builtin = @import("builtin.zig");
const Core = @import("core.zig");
const Debug = @import("debug");

pub const Config = @import("config");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const Special = Types.Special;

const SimpleValue = union(enum) {
    bool: bool,
    special: Special,
};

const EvaluationError = error{
    BadSecondaryValue,
    WrongArgument,
};

fn evalCondition(c: *Core, lagent: *Agent, ragent: *Agent, instructions: []Condition.Instruction) !bool {
    const registers = &c.condition_registers;
    for (instructions) |instr| {
        switch (instr.tag) {
            .put_port => |port| {
                const owner = if (port.owner == .lhs) lagent else ragent;
                const value = if (port.idx) |idx| owner.ports[idx].? else Value{ .agent = owner };
                const agent = agent: {
                    switch (value) {
                        .name => |name| {
                            const traversed = name.unwind();
                            if (traversed) |agent| {
                                break :agent agent;
                            } else {
                                std.debug.print("No value on name\n", .{});
                                return EvaluationError.BadSecondaryValue;
                            }
                        },
                        .agent => |agent| break :agent agent,
                        else => unreachable,
                    }
                };

                registers[instr.result] = .{ .agent = agent };
            },
            .assert_id => |asserted_id| {
                if (registers[instr.lhs] == .agent) {
                    const agent = registers[instr.lhs].agent;
                    if (agent.id != asserted_id) {
                        return false;
                    }
                }
            },
            .get_special => {
                registers[instr.result] = Condition.Register.CondValue{ .special = registers[instr.lhs].agent.ports[0].?.special };
            },
            .put_constant => |special| {
                registers[instr.result] = Condition.Register.CondValue{ .special = special };
            },
            .apply_bin => |op| {
                const lhs = registers[instr.lhs];
                const rhs = registers[instr.rhs];
                if (lhs == .special and rhs == .special) {
                    registers[instr.result] = .{ .bool = switch (op) {
                        .eq => lhs.special.eq(rhs.special),
                        .geq => lhs.special.geq(rhs.special),
                        .leq => lhs.special.leq(rhs.special),
                        .less => lhs.special.less(rhs.special),
                        .greater => lhs.special.greater(rhs.special),
                        else => return error.WrongArgument,
                    } };
                } else if (lhs == .bool and rhs == .bool) {
                    registers[instr.result] = .{ .bool = switch (op) {
                        .logic_and => lhs.bool and rhs.bool,
                        .logic_or => lhs.bool and rhs.bool,
                        else => return error.WrongArgument,
                    } };
                } else {
                    return error.WrongArgument;
                }
            },
            .apply_un => unreachable,
            .get_result => {
                if (registers[instr.result] == .bool) {
                    return registers[instr.result].bool;
                }
                return false;
            },
        }
    }
    unreachable;
}

fn isDup2(id: Agent.Id) bool {
    return id == (comptime Builtin.BuiltinNameMap.get("Dup").?) or id == (comptime Builtin.BuiltinNameMap.get("DupCopy").?) or id == (comptime Builtin.BuiltinNameMap.get("Dup2").?);
}

/// Copy on write. We copy the agent. After that, all its
/// ports are looked at by two agents (the original and the copy).
/// If the original has an empty port, then it is a nested pattern matching
/// problem.
fn cow(c: *Core, agent: *Agent) !?*Agent {
    std.debug.assert(agent.rc > 1);
    const dup_copy_id = comptime Builtin.BuiltinNameMap.get("DupCopy").?;
    const arity = c.runtime.agent_arities.arityOf(agent.id);

    agent.rc -= 1;
    const new_me = try c.createAgent(agent.id);

    for (0..arity) |port_idx| {
        if (agent.ports[port_idx].? == .special) {
            new_me.ports[port_idx] = agent.ports[port_idx];
            break;
        }

        const possible_agent = agent.ports[port_idx].?.getAgent();
        if (possible_agent) |port_agent| {
            if (!isDup2(port_agent.id) or true) {
                port_agent.rc += 1;
                new_me.ports[port_idx] = .{ .agent = port_agent };
            } else {
                agent.ports[port_idx] = port_agent.ports[0];
                new_me.ports[port_idx] = port_agent.ports[1];
                c.local_ctx.freeOneAgent(port_agent);
            }
        } else {
            const name = agent.ports[port_idx].?.name.traverseFree(c.local_ctx.name_heap);
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

pub fn evalEquation(c: *Core, eq: Equation) !void {
    var lagent = eq.lhs;
    var ragent = eq.rhs;
    if (lagent.rc > 1) {
        lagent = try cow(c, lagent) orelse {
            try c.local_ctx.pushLazy(.{ .lhs = lagent, .rhs = ragent });
            return;
        };
    }
    if (ragent.rc > 1) {
        ragent = try cow(c, ragent) orelse {
            try c.local_ctx.pushLazy(.{ .lhs = lagent, .rhs = ragent });
            return;
        };
    }

    // TODO (KoGora): perf analysis
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} ~ {s}\n", .{
            c.runtime.getAgentName(lagent.id).?,
            c.runtime.getAgentName(ragent.id).?,
        });
    }
    if (Builtin.isBuiltinAgent(lagent.id)) {
        const handler = Builtin.BuiltinTable.get(lagent.id).?;
        if (handler(c, lagent, ragent)) {
            return;
        } else |err| {
            if (err != Builtin.BuiltinAgentError.NoRuleSpecified) {
                return err;
            }
        }
    }

    if (Builtin.isBuiltinAgent(ragent.id)) {
        const handler = Builtin.BuiltinTable.get(ragent.id).?;
        if (handler(c, ragent, lagent)) {
            return;
        } else |err| {
            if (err != Builtin.BuiltinAgentError.NoRuleSpecified) {
                return err;
            }
        }
    }

    // Not builtin
    const search_result = c.runtime.rule_table.get(.{ .lhs = lagent.id, .rhs = ragent.id }) catch |err| rule_blk: {
        if (err == error.UnknownRule) {
            // The rule may still be defined as wildcard
            if (c.runtime.wildcard_table.get(lagent.id)) |wildcard_rule| {
                break :rule_blk Runtime.RuleSearchResult{ .rules = wildcard_rule, .tag = .wildcard_lhs };
            } else if (c.runtime.wildcard_table.get(ragent.id)) |wildcard_rule| {
                break :rule_blk Runtime.RuleSearchResult{ .rules = wildcard_rule, .tag = .wildcard_rhs };
            }

            std.debug.print("Unknown rule {s} - {s}\n", .{
                c.runtime.getAgentName(lagent.id).?,
                c.runtime.getAgentName(ragent.id).?,
            });
        }

        return err;
    };

    var wildcarded: bool = false;

    evaluation: switch (search_result.tag) {
        .normal => {
            // We don't free the ragent in case it's wildcarded
            // because it functions like a name and will interact
            // later

            const conditioned_rules = search_result.rules;
            for (conditioned_rules) |conditioned| {
                if (conditioned.condition) |condition| {
                    const evaluated = evalCondition(c, lagent, ragent, condition) catch |err| {
                        if (Config.debug_printing.print_interactions)
                            std.debug.print("Caught an error {s}!\n", .{@errorName(err)});

                        try c.local_ctx.pushLazy(.{ .lhs = lagent, .rhs = ragent });
                        return;
                        // switch (err) {
                        //     EvaluationError.BadSecondaryValue => break :errblk false,
                        //     // There probably should be some other error handling in case of bad arguments
                        //     // but since many things can go badly, we can simply ignore it?
                        //     // TODO: research into more constraining conditions
                        //     EvaluationError.WrongArgument => break :errblk false,
                        // }
                    };
                    if (evaluated) {
                        try Core.execInstructions(c, conditioned.instructions, lagent, ragent, wildcarded);
                        c.local_ctx.agent_heap.freeOne(lagent);
                        if (!wildcarded) c.local_ctx.agent_heap.freeOne(ragent);
                        return;
                    }
                } else {
                    try Core.execInstructions(c, conditioned.instructions, lagent, ragent, wildcarded);
                    c.local_ctx.agent_heap.freeOne(lagent);
                    if (!wildcarded) c.local_ctx.agent_heap.freeOne(ragent);
                    return;
                }
            }
        },
        .swap => {
            std.mem.swap(*Agent, &lagent, &ragent);
            continue :evaluation .normal;
        },
        .wildcard_lhs => {
            wildcarded = true;
            continue :evaluation .normal;
        },
        .wildcard_rhs => {
            std.mem.swap(*Agent, &lagent, &ragent);
            continue :evaluation .wildcard_lhs;
        },
    }
}

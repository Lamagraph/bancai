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
    /// The needed net hasn't been evaluated yet. We can wait until there is an agent on that port.
    EmptyName,
    WrongType,
};

fn evalCondition(c: *Core, lagent: *Agent, ragent: *Agent, instructions: []Condition.Instruction) !bool {
    const registers = &c.condition_registers;
    for (instructions) |instr| {
        switch (instr.tag) {
            .put_port => |port| {
                const owner = if (port.owner == .lhs) lagent else ragent;
                const value = if (port.idx) |idx| owner.ports[idx] else Value{ .agent = owner };
                const agent = agent: {
                    switch (value) {
                        .name => |name| {
                            const traversed = name.unwind();
                            if (traversed) |agent| {
                                break :agent agent;
                            } else {
                                std.debug.print("No value on name\n", .{});
                                return EvaluationError.EmptyName;
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
                registers[instr.result] = Condition.Register.CondValue{ .special = registers[instr.lhs].agent.ports[0].special };
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
                        else => return error.WrongType,
                    } };
                } else if (lhs == .bool and rhs == .bool) {
                    registers[instr.result] = .{ .bool = switch (op) {
                        .logic_and => lhs.bool and rhs.bool,
                        .logic_or => lhs.bool and rhs.bool,
                        else => return error.WrongType,
                    } };
                } else {
                    return error.WrongType;
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

pub fn evalEquation(c: *Core, eq: Equation) !void {
    var lagent = eq.lhs;
    var ragent = eq.rhs;

    // TODO (KoGora): perf analysis
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} ~ {s}\n", .{
            c.runtime.agent_id_map.findKey(lagent.id).?,
            c.runtime.agent_id_map.findKey(ragent.id).?,
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
                c.runtime.agent_id_map.findKey(lagent.id).?,
                c.runtime.agent_id_map.findKey(ragent.id).?,
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

                        switch (err) {
                            EvaluationError.WrongType => return err,
                            EvaluationError.EmptyName => {
                                try c.local_ctx.pushLazy(eq);
                                return;
                            },
                        }
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
            return error.NoSuchRule;
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

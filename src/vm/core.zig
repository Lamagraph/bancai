//! Core is a thing that executes interactions.
//!
//! Anything shared between cores is in the
//! Runtime module.
const std = @import("std");

pub const Builtin = @import("builtin.zig");
pub const Interaction = @import("interactions.zig");
pub const Importer = @import("importer.zig");

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Condition = Compilation.Condition;

const CoreMasterCtrl = @import("core_master_ctrl.zig");
const CoreSlaveCtrl = @import("core_slave_ctrl.zig");
const Normalize = @import("normalize.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const EquationUnnormalized = Types.EquationUnnormalized;

const Core = @This();
const Self = Core;

const number_of_registers = 256;

id: CoreId,
mode: CoreMode,

// Execution only ever reads Runtime (rule/arity/id lookups) - everything
// that mutates it (rule registration, imports, associated_names) lives in
// VM's statement handling now, so this can be const.
runtime: *const Runtime,

core_ctrl: ?CoreCtrl,
local_ctx: LocalCtx,

registers: [number_of_registers]Value,
condition_registers: [number_of_registers]Condition.Register.CondValue,

pub const CoreMode = enum { singleThread, multiThread };
pub const CoreRole = enum { master, slave };

pub const CoreRc = enum(u8) {
    /// The core finished execution normally.
    finishRc = 0,
    /// The core was stopped for some reason.
    stopRc,
};

pub const CoreId = union(CoreRole) {
    master: void,
    slave: u32,
};

pub const CoreCtrl = union(CoreRole) {
    master: *CoreMasterCtrl,
    slave: *CoreSlaveCtrl,
};

/// Per-core state - the heap and fetcher a given Core exclusively works
/// with, as opposed to CoreCommon which every Core shares.
pub const LocalCtx = struct {
    name_heap: Memory.Heap(Name),
    agent_heap: Memory.Heap(Agent),
    equation_fetcher: EquationFetcher,

    pub inline fn allocOneAgent(self: LocalCtx) !*Agent {
        return self.agent_heap.allocOne();
    }

    pub inline fn freeOneAgent(self: LocalCtx, elem: *Agent) void {
        self.agent_heap.freeOne(elem);
    }

    pub inline fn allocOneName(self: LocalCtx) !*Name {
        return self.name_heap.allocOne();
    }

    pub inline fn freeOneName(self: LocalCtx, elem: *Name) void {
        self.name_heap.freeOne(elem);
    }

    pub inline fn fetchEquation(self: LocalCtx) ?Equation {
        return self.equation_fetcher.fetch();
    }

    pub inline fn pushEquation(self: *LocalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushEquation(self.name_heap, self.equation_fetcher, eq);
    }

    pub inline fn pushUrgent(self: *LocalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushUrgentEquation(self.name_heap, self.equation_fetcher, eq);
    }
};

pub fn createEmptyName(c: *Core) !*Name {
    const name = try c.local_ctx.allocOneName();
    name.port = null;
    return name;
}

pub fn createAgent(c: *Core, id: Agent.Id) !*Agent {
    const ag = try c.local_ctx.allocOneAgent();
    ag.* = .{ .id = id, .ports = @splat(null), .rc = 1 };
    return ag;
}

pub fn createNumberAgent(c: *Core, num: Types.Special) !*Agent {
    const ag = try createAgent(c, Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?);
    ag.ports[0] = Value{ .special = num };
    return ag;
}

/// Core owns none of these by allocation - the runtime, the heaps and the
/// equation fetcher are all created and destroyed by the VM, which is what
/// lets it hand out per-thread heaps in the multithreaded setup. Core just
/// holds onto what it's given.
pub fn init(
    core_id: CoreId,
    mode: CoreMode,
    runtime: *const Runtime,
    core_ctrl: ?CoreCtrl,
    local_ctx: LocalCtx,
) Self {
    return .{
        .id = core_id,
        .mode = mode,
        .runtime = runtime,
        .core_ctrl = core_ctrl,
        .local_ctx = local_ctx,

        // They are not meant to be used when undefiend by the design of compilation.
        .registers = @splat(undefined),
        .condition_registers = @splat(undefined),
    };
}

pub fn execInstructions(
    c: *Core,
    instrs: []Instruction,
    lagent: *Agent,
    ragent: *Agent,
    wildcarded: bool,
) !void {
    for (instrs) |instruction| {
        switch (instruction.tag) {
            .mk_agent => |id| {
                const ag = try c.local_ctx.allocOneAgent();
                ag.* = .{ .id = id, .ports = @splat(null) };
                c.registers[instruction.operand1] = .{ .agent = ag };
            },
            .mk_special => |special| {
                c.registers[instruction.operand1] = .{ .special = special };
            },
            .put_into_port => |port_idx| {
                c.registers[instruction.operand2].agent.ports[port_idx] = c.registers[instruction.operand1];
            },
            .push => {
                const eq = EquationUnnormalized{
                    .lhs = c.registers[instruction.operand1],
                    .rhs = c.registers[instruction.operand2],
                };
                try c.local_ctx.pushEquation(eq);
            },
            .mk_name => {
                const name = try c.local_ctx.allocOneName();
                name.* = .{ .port = null };
                c.registers[instruction.operand1] = .{ .name = name };
            },
            .load_arguments => {
                const larity = c.runtime.agent_arities.arityOf(lagent.id);
                var idx: u16 = 0;
                for (0..larity) |port_idx| {
                    c.registers[idx] = lagent.ports[port_idx].?;
                    idx += 1;
                }
                if (!wildcarded) {
                    const rarity = c.runtime.agent_arities.arityOf(ragent.id);
                    for (0..rarity) |port_idx| {
                        c.registers[idx] = ragent.ports[port_idx].?;
                        idx += 1;
                    }
                } else {
                    c.registers[idx] = .{ .agent = ragent };
                    idx += 1;
                }
            },
        }
    }
}

inline fn runEquationsSingleThread(c: *Core) !CoreRc {
    while (c.local_ctx.fetchEquation()) |eq| {
        try Interaction.evalEquation(c, eq);
    }

    return .finishRc;
}

inline fn runEquationsMaster(c: *Core) !CoreRc {
    // TODO:(kogora) add core_ctrl usage (as CoreMasterCtrl)
    while (c.local_ctx.fetchEquation()) |eq| {
        try Interaction.evalEquation(c, eq);
    }

    return .finishRc;
}

inline fn runEquationsSlave(c: *Core) !CoreRc {
    // TODO:(kogora) add core_ctrl usage (as CoreSlaveCtrl)
    while (c.local_ctx.fetchEquation()) |eq| {
        try Interaction.evalEquation(c, eq);
    }

    return .finishRc;
}

pub fn runEquations(c: *Core) !CoreRc {
    return switch (c.mode) {
        .singleThread => try runEquationsSingleThread(c),
        .multiThread => switch (c.id) {
            .master => try runEquationsMaster(c),
            .slave => try runEquationsSlave(c),
        },
    };
}

//! Core is a thing that executes interactions.
//!
//! Anything shared between cores is in the
//! Runtime module.
const std = @import("std");

pub const Builtin = @import("builtin.zig");
pub const Interaction = @import("interactions.zig");
pub const Importer = @import("importer.zig");
const Profiler = @import("profiler");

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Condition = Compilation.Condition;

const MainCtrl = @import("mt/main_ctrl.zig");
const WorkerCtrl = @import("mt/worker_ctrl.zig");
const Normalize = @import("normalize.zig");

const CoreMode = @import("core_types.zig").CoreMode;
const CoreId = @import("core_types.zig").CoreId;
const CoreRc = @import("core_types.zig").CoreRc;
const CoreRole = @import("core_types.zig").CoreRole;

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const EquationUnnormalized = Types.EquationUnnormalized;

const Core = @This();
const Self = Core;

const log = std.log.scoped(.core);

const number_of_registers = 256;

id: CoreId,
mode: CoreMode,

// Execution only ever reads Runtime (rule/arity/id lookups) - everything
// that mutates it (rule registration, imports, associated_names) lives in
// VM's statement handling now, so this can be const.
runtime: *const Runtime,

profiler: *Profiler,

core_ctrl: ?CoreCtrl,
local_ctx: LocalCtx,

registers: [number_of_registers]Value,
condition_registers: [number_of_registers]Condition.Register.CondValue,

pub const CoreCtrl = union(CoreRole) {
    main: *MainCtrl,
    worker: *WorkerCtrl,
};

inline fn workerCtrl(self: *Self) *WorkerCtrl {
    return self.core_ctrl.?.worker;
}

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

    /// This function will always be called in the context of two agents interacting.
    /// Hence, normalization is unnecessary.
    pub inline fn pushLazy(self: *LocalCtx, eq: Equation) !void {
        try self.equation_fetcher.pushLazy(eq);
    }
};

pub fn createEmptyName(c: *Core) !*Name {
    const name = try c.local_ctx.allocOneName();
    name.port = null;
    return name;
}

pub fn createAgent(c: *Core, id: Agent.Id) !*Agent {
    const ag = try c.local_ctx.allocOneAgent();
    ag.id = id;
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
    profiler: *Profiler,
) Self {
    return .{
        .id = core_id,
        .mode = mode,
        .runtime = runtime,
        .core_ctrl = core_ctrl,
        .local_ctx = local_ctx,
        .profiler = profiler,

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
                ag.* = .{ .id = id };
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
                    c.registers[idx] = lagent.ports[port_idx];
                    idx += 1;
                }
                if (!wildcarded) {
                    const rarity = c.runtime.agent_arities.arityOf(ragent.id);
                    for (0..rarity) |port_idx| {
                        c.registers[idx] = ragent.ports[port_idx];
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

inline fn evalAsSingleThread(c: *Core) !void {
    // NOTE:(kogora) dont use CoreCtrl at all
    while (c.local_ctx.fetchEquation()) |eq| {
        try Interaction.evalEquation(c, eq);
    }
}

inline fn evalAsMain(c: *Core) !void {
    // TODO:(kogora) add core_ctrl usage (as MainCtrl)
    while (c.local_ctx.fetchEquation()) |eq| {
        try Interaction.evalEquation(c, eq);
    }
}

inline fn evalAsWorker(c: *Core) !void {
    const ctrl = c.workerCtrl();

    { // Init work (newborn -> applicant)
        const new_state = ctrl.getStatePriv().applicantState();
        ctrl.putState(new_state);
    }
    defer { // Deinit work (goner -> corpse)
        const new_state = ctrl.getStatePriv().corpseState();
        ctrl.putState(new_state);
    }

    live: while (true) {
        var cur_state = ctrl.getStatePriv();

        if (cur_state != .goner) {
            if (ctrl.receiveSig()) |sig| {
                cur_state = cur_state.sigNextState(sig) orelse cur_state;

                // Must precede ackSig: the VM relies on it.
                ctrl.putState(cur_state);
                ctrl.ackSig();
            }
        }

        switch (cur_state) {
            .busy => {
                var new_state: WorkerCtrl.State = undefined;

                eval: {
                    const eq = c.local_ctx.fetchEquation() orelse {
                        new_state = cur_state.applicantState();
                        break :eval;
                    };

                    Interaction.evalEquation(c, eq) catch |err| {
                        log.err("core-{}: {s}", .{ c.id.worker, @errorName(err) });
                        new_state = cur_state.gonerState();
                        break :eval;
                    };

                    continue :live;
                }

                ctrl.putState(new_state);
            },
            .applicant => {
                std.atomic.spinLoopHint();
            },
            .goner => {
                log.debug("core-{} is a goner", .{c.id.worker});
                break :live;
            },
            .corpse, .newborn => unreachable,
        }
    }
}

pub fn eval(c: *Core) !void {
    return switch (c.mode) {
        .singleThread => try evalAsSingleThread(c),
        .multiThread => switch (c.id) {
            .main => try evalAsMain(c),
            .worker => try evalAsWorker(c),
        },
    };
}

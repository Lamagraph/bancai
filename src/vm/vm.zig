const std = @import("std");

const AST = @import("ast");
const BuildConfig = @import("config");
const Compilation = @import("compilation");
const Profiler = @import("profiler");
const Instruction = Compilation.Instruction;
const Diagnostic = Compilation.Diagnostic;
const Printing = Profiler.Printing;
const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const Types = Runtime.Types;
const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const EquationUnnormalized = Types.EquationUnnormalized;

pub const Core = @import("core.zig");
const CoreMode = @import("core_types.zig").CoreMode;
const CoreId = @import("core_types.zig").CoreId;
const CoreRc = @import("core_types.zig").CoreRc;
const CoreRole = @import("core_types.zig").CoreRole;

pub const Config = @import("config.zig").Config;

pub const MainCtrl = @import("mt/main_ctrl.zig");
pub const WorkerCtrl = @import("mt/worker_ctrl.zig");
pub const WorkerState = @import("mt/worker_ctrl.zig").State;

pub const GlobalCtx = @import("global_ctx.zig").GlobalCtx;
const Multi = @import("mt/multi.zig").Multi;
const Slot = @import("mt/slot.zig").Slot;

pub const Builtin = @import("builtin.zig");
pub const Importer = @import("importer.zig");
pub const Interaction = @import("interactions.zig");
const Link = @import("link.zig");

const VM = @This();
const Self = VM;

const log = std.log.scoped(.vm);

cfg: Config,
profiler: *Profiler,

global_ctx: GlobalCtx,
runtime: *Runtime,

main_core: Core,
vmode: VMode,

const VMode = union(enum) {
    const Single = void;

    s: Single,
    m: Multi,

    fn initS() VMode {
        return .{ .s = {} };
    }

    fn initM(
        cfg: Config,
        runtime: *Runtime,
        gpa: std.mem.Allocator,
        global_ctx: GlobalCtx,
        profiler: *Profiler,
    ) !VMode {
        return .{ .m = try Multi.init(
            cfg.cores_num,
            gpa,
            runtime,
            global_ctx,
            runtime.io,
            profiler,
        ) };
    }

    fn deinit(
        self: *VMode,
        gpa: std.mem.Allocator,
        global_ctx: GlobalCtx,
    ) void {
        switch (self.*) {
            .s => {},
            .m => |*m| {
                m.deinit(global_ctx, gpa);
            },
        }
    }
};

pub fn deinit(self: *Self) void {
    switch (self.vmode) {
        .s => {},
        .m => |*m| {
            std.debug.assert(!m.anyCoreThreadSpawned());

            m.deinit(self.global_ctx, self.runtime.gpa);
        },
    }

    self.global_ctx.deinit(self.runtime.gpa);
}

pub fn init(runtime: *Runtime, cfg: Config, profiler: *Profiler) !Self {
    try cfg.isValid();

    const mode = cfg.getMode();

    var main_core: Core = undefined;
    var vmode: VMode = undefined;

    var global_ctx = try GlobalCtx.init(runtime, cfg);
    errdefer global_ctx.deinit(runtime.gpa);

    switch (mode) {
        .singleThread => {
            vmode = VMode.initS();
            main_core = Core.init(
                CoreId{ .main = {} },
                mode,
                runtime,
                null,
                try global_ctx.createVmLocal(),
                profiler,
            );
        },
        .multiThread => {
            vmode = try VMode.initM(cfg, runtime, runtime.gpa, global_ctx, profiler);
            errdefer vmode.deinit(runtime.gpa, global_ctx);

            main_core = Core.init(
                CoreId{ .main = {} },
                mode,
                runtime,
                Core.CoreCtrl{ .main = vmode.m.main_ctrl },
                try global_ctx.createVmLocal(),
                profiler,
            );
        },
    }

    return .{
        .main_core = main_core,
        .vmode = vmode,
        .global_ctx = global_ctx,
        .runtime = runtime,
        .cfg = cfg,
        .profiler = profiler,
    };
}

fn objToValueNumber(agent_heap: Memory.Heap(Agent), num: AST.Object) !Value {
    const numtype = try Special.parse(num.name);
    const agent_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
    const agent = try agent_heap.allocOne();

    agent.* = .{ .id = agent_id };
    agent.ports[0] = Value{ .special = numtype };

    return .{ .agent = agent };
}

fn objToValueAgent(self: *Self, obj: AST.Object) anyerror!Value {
    const portlist = obj.portlist.?;
    const agent_id = try self.runtime.agent_id_map.get(obj.name);
    const arity = try self.runtime.agent_arities.get(agent_id, portlist.len);
    const agent = try self.global_ctx.agent_heap.allocOne();

    agent.* = .{ .id = agent_id };
    {
        var idx: u8 = 0;
        while (idx < arity) : (idx += 1) {
            // Temporary names are needed
            agent.ports[idx] = try self.objToValue(portlist[idx].val);
        }
    }

    return Value{ .agent = agent };
}

fn objToValueName(self: *Self, obj: AST.Object) !Value {
    const name = try self.global_ctx.name_heap.allocOne();

    name.* = .empty;
    try self.runtime.associated_names.put(obj.name, name);

    return .{ .name = name };
}

fn objToValue(
    self: *Self,
    obj: AST.Object,
) anyerror!Value {
    if (obj.isNumber()) {
        const num = obj.portlist.?[0].val;
        return objToValueNumber(self.global_ctx.agent_heap, num);
    }

    if (obj.portlist != null) {
        return self.objToValueAgent(obj);
    }

    if (self.runtime.associated_names.getPtr(obj.name)) |maybe_name| {
        if (maybe_name.*) |name| {
            maybe_name.* = null;
            return (Value{ .name = name }).resolve(self.global_ctx.name_heap);
        } else {
            // Implicitly reusing
        }
    }

    return self.objToValueName(obj);
}

inline fn printStmt(self: *Self, name_to_print: AST.Name) !void {
    if (self.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
        if (maybe_name) |name| {
            if (name.load()) |port| {
                try Printing.tryPrint(self.runtime, self.runtime.gpa, port);
            } else {
                std.debug.print("<MOVED>\n", .{});
            }
        } else {
            std.debug.print("<EMPTY>\n", .{});
        }
    } else {
        std.debug.print("<UNDEFINED>\n", .{});
    }
}

inline fn freeStmt(self: *Self, names: []const AST.Name) !void {
    for (names) |wrapped_name| {
        const name = wrapped_name.val;
        if (self.runtime.associated_names.get(name)) |maybe_wire| {
            defer _ = self.runtime.associated_names.remove(name);
            if (maybe_wire) |wire| {
                try Builtin.Eraser.eraseValue(&self.main_core, .{ .name = wire });
            }
        } else {
            std.debug.print("Trying to free non-existent name {s}\n", .{name});
        }
    }
}

inline fn useStmt(self: *Self, import_path: []const u8) !void {
    const final_import_path = if (std.fs.path.isAbsolute(import_path)) try self.runtime.gpa.dupe(u8, import_path) else blk: {
        const dirname = std.fs.path.dirname(self.runtime.main_file.path).?;
        break :blk try std.fs.path.resolve(self.runtime.gpa, &.{ dirname, import_path });
    };
    defer self.runtime.gpa.free(final_import_path);

    try self.runtime.importer.import(final_import_path, self.runtime);
}

inline fn ruleStmt(self: *Self, rule: AST.Rule) !void {
    var diag: Diagnostic = .{};
    const compiled_rule = Instruction.compileRule(self.runtime, rule, &diag) catch |err| {
        if (Diagnostic.isHandledError(err)) {
            const message =
                try diag.getPrettyMessage(
                    self.runtime.main_file.contents,
                    self.runtime.main_file.tokens,
                    self.runtime.gpa,
                );
            defer self.runtime.gpa.free(message);
            std.debug.print("{s}", .{message});
            return error.CompilationError;
        } else {
            return err;
        }
    };
    if (BuildConfig.debug_printing.print_compiled_instructions) {
        try Instruction.debugPrintInstruction(self.runtime, compiled_rule[1]);
        const guard_size = 40;
        const guard: [guard_size]u8 = comptime @splat('=');
        std.debug.print("{s}\n", .{&guard});
    }
    if (compiled_rule[0] == .agents) {
        try self.runtime.rule_table.map.put(compiled_rule[0].agents, compiled_rule[1]);
    } else {
        try self.runtime.wildcard_table.put(compiled_rule[0].wildcard, compiled_rule[1]);
    }
}

inline fn prepareActivePair(self: *Self, ap: AST.ActivePair) !?Profiler.Interaction {
    const lhs = try self.objToValue(ap.lhs.val);
    const rhs = try self.objToValue(ap.rhs.val);
    const eq = EquationUnnormalized{ .lhs = lhs, .rhs = rhs };

    const normalized = Link.link(self.global_ctx.name_heap, eq.lhs, eq.rhs) orelse return null;

    try self.global_ctx.pushEquationNormalized(normalized);

    return .{
        .lhs = normalized.lhs.id,
        .rhs = normalized.rhs.id,
    };
}

inline fn execActivePairVmCore(self: *Self) !void {
    try self.main_core.eval();
}

inline fn execActivePairMultiCores(self: *Self) !void {
    // TODO:(kogora) implement warmup
    std.debug.assert(!self.cfg.warmup);
    if (self.cfg.warmup) {
        try self.main_core.eval();
        self.global_ctx.balanceEquations();
        return;
    }

    try self.vmode.m.eval();
}

inline fn execActivePairMode(self: *Self, mode: CoreMode) !void {
    switch (mode) {
        .singleThread => try self.execActivePairVmCore(),
        .multiThread => try self.execActivePairMultiCores(),
    }
}

inline fn execActivePair(self: *Self, mode: CoreMode) !void {
    try self.execActivePairMode(mode);
}

fn startCores(self: *Self) !void {
    if (self.cfg.getMode() != .multiThread) {
        return;
    }

    const m: *Multi = &self.vmode.m;
    log.info("starting {} core(s)", .{m.slots.len});

    try m.start();

    log.info("{} core(s) started", .{m.slots.len});
}

fn stopCores(self: *Self) void {
    if (self.cfg.getMode() != .multiThread) {
        return;
    }

    const m: *Multi = &self.vmode.m;
    log.info("stopping {} core(s)", .{m.slots.len});

    m.exit();

    log.info("{} core(s) stopped", .{m.slots.len});
}

fn printCoreStats(self: *Self) void {
    if (!BuildConfig.debug_printing.print_core_stats) return;

    var total = self.main_core.interactions;
    const slots: []Slot = switch (self.vmode) {
        .s => &.{},
        .m => |m| m.slots,
    };
    for (slots) |*slot| total += slot.core.interactions;

    printCoreStat("main", self.main_core.interactions, total);
    for (slots) |*slot| {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{}", .{slot.rawId()}) catch unreachable;
        printCoreStat(name, slot.core.interactions, total);
    }
    std.debug.print("total: {} interactions\n", .{total});
}

fn printCoreStat(name: []const u8, interactions: u64, total: u64) void {
    const share = if (total == 0) 0 else @as(f64, @floatFromInt(interactions)) * 100 / @as(f64, @floatFromInt(total));
    std.debug.print("core-{s}: {} interactions ({d:.1}%)\n", .{ name, interactions, share });
}

pub fn runProgram(self: *Self, program: AST.Program) !void {
    defer self.printCoreStats();
    try self.startCores();
    defer self.stopCores();

    for (program.statements) |statement| {
        switch (statement.val) {
            .print_stmt => |name_to_print| try self.printStmt(name_to_print),
            .free_stmt => |names| try self.freeStmt(names),
            .use_stmt => |import_path| try self.useStmt(import_path),
            .rule => |rule| try self.ruleStmt(rule),
            .active_pair => |ap| {
                const interaction = try self.prepareActivePair(ap) orelse continue;
                self.profiler.startInteraction(interaction);
                try self.execActivePair(self.main_core.mode);
                self.profiler.endInteraction(.{
                    .agent_heap = self.global_ctx.agent_heap,
                    .name_heap = self.global_ctx.name_heap,
                });
            },
            else => unreachable,
        }
    }
}

test {
    _ = @import("mt/signals.zig");
}

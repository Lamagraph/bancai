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

pub const GlobalCtx = @import("global_ctx.zig").GlobalCtx;

pub const Builtin = @import("builtin.zig");
pub const Importer = @import("importer.zig");
pub const Interaction = @import("interactions.zig");
const Normalize = @import("normalize.zig");

pub const normalizeEquation = Normalize.normalizeEquation;

const VM = @This();
const Self = VM;

cfg: Config,
profiler: *Profiler,

global_ctx: GlobalCtx,
runtime: *Runtime,

main_ctrl: ?*MainCtrl,
worker_ctrl: ?*WorkerCtrl,

main_core: Core,
cores: []Core,

var available_core_id: usize = 0;

fn destroyWorkerCores(
    cores: []Core,
    global_ctx: *GlobalCtx,
    runtime: *Runtime,
) void {
    for (cores) |*c| global_ctx.destroyLocal(c.local_ctx, runtime.gpa);
    runtime.gpa.free(cores);
}

fn createWorkerCores(
    runtime: *Runtime,
    global_ctx: GlobalCtx,
    core_num: usize,
    worker_ctrl: *WorkerCtrl,
    profiler: *Profiler,
) ![]Core {
    const cores: []Core = try runtime.gpa.alloc(Core, core_num);
    errdefer runtime.gpa.free(cores);

    const start_id = available_core_id;
    for (cores, start_id..) |*c, core_id| {
        c.* = Core.init(
            CoreId{ .worker = @intCast(core_id) },
            CoreMode.singleThread,
            runtime,
            Core.CoreCtrl{ .worker = worker_ctrl },
            global_ctx.createLocal(runtime.gpa),
            profiler,
        );

        available_core_id += 1;
    }

    return cores;
}

pub fn deinit(self: *Self) void {
    destroyWorkerCores(self.cores, &self.global_ctx, self.runtime);
    self.global_ctx.deinit(self.runtime.gpa);
    if (self.worker_ctrl) |worker_ctrl| self.runtime.gpa.destroy(worker_ctrl);
    if (self.main_ctrl) |main_ctrl| self.runtime.gpa.destroy(main_ctrl);
}

pub fn init(runtime: *Runtime, cfg: Config, profiler: *Profiler) !Self {
    try cfg.isValid();

    const mode = cfg.getMode();
    std.debug.assert(mode == CoreMode.singleThread); // TODO:(kogora): multithread version

    var main_core: Core = undefined;
    var main_ctrl: ?*MainCtrl = null;

    var worker_ctrl: ?*WorkerCtrl = null;
    var cores: []Core = &.{};

    var global_ctx = try GlobalCtx.init(runtime, cfg);
    errdefer global_ctx.deinit(runtime.gpa);

    switch (mode) {
        .singleThread => {
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
            const created_main_ctrl = try runtime.gpa.create(MainCtrl);
            errdefer runtime.gpa.destroy(created_main_ctrl);
            created_main_ctrl.* = MainCtrl.init();
            main_ctrl = created_main_ctrl;

            main_core = Core.init(
                CoreId{ .main = {} },
                mode,
                runtime,
                Core.CoreCtrl{ .main = created_main_ctrl },
                try global_ctx.createVmLocal(),
                profiler,
            );

            const created_worker_ctrl = try runtime.gpa.create(WorkerCtrl);
            errdefer runtime.gpa.destroy(created_worker_ctrl);
            created_worker_ctrl.* = WorkerCtrl.init();
            worker_ctrl = created_worker_ctrl;

            cores = try createWorkerCores(runtime, global_ctx, cfg.cores_num, created_worker_ctrl, profiler);
            errdefer destroyWorkerCores(cores, &global_ctx, runtime);
        },
    }

    return .{
        .main_core = main_core,
        .cores = cores,
        .main_ctrl = main_ctrl,
        .worker_ctrl = worker_ctrl,
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

    name.* = .{ .port = null };
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
            if (name.port) |port| {
                defer self.global_ctx.name_heap.freeOne(name);

                return port;
            } else {
                return .{ .name = name };
            }
        } else {
            // Implicitly reusing
        }
    }

    return self.objToValueName(obj);
}

inline fn printStmt(self: *Self, name_to_print: AST.Name) !void {
    if (self.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
        if (maybe_name) |name| {
            if (name.port) |port| {
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
                const traversed = wire.traverseFree(self.main_core.local_ctx.name_heap);
                defer self.main_core.local_ctx.name_heap.freeOne(traversed);
                if (traversed.port) |port| {
                    // of course, there shouldn't be anything other than an agent
                    try Builtin.Eraser.erase(&self.main_core, port.agent);
                }
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

    const normalized = try Normalize.normalizeEquation(self.global_ctx.name_heap, eq) orelse return null;

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

    // TODO:(kogora): multithread version
    try self.cores[0].eval();
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

pub fn runProgram(self: *Self, program: AST.Program) !void {
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

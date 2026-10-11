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
const EquationFetcher = Runtime.EquationFetcher;
const Types = Runtime.Types;
const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const EquationUnnormalized = Types.EquationUnnormalized;

pub const Builtin = @import("builtin.zig");
pub const Core = @import("core.zig");
pub const MainCtrl = @import("mt/main_ctrl.zig");
pub const WorkerCtrl = @import("mt/worker_ctrl.zig");
pub const Importer = @import("importer.zig");
pub const Interaction = @import("interactions.zig");
const Normalize = @import("normalize.zig");

pub const normalizeEquation = Normalize.normalizeEquation;

const VM = @This();
const Self = VM;

const getUser = "getUser";

config: Config,
profiler: *Profiler,

global_ctx: GlobalCtx,
runtime: *Runtime,

main_ctrl: ?*MainCtrl,
worker_ctrl: ?*WorkerCtrl,

main_core: Core,
cores: []Core,

var available_core_id: usize = 0;

pub const Config = struct {
    pub const Error = error{
        NotSupported,
    };

    cores_num: usize,
    heap_size: usize,

    warmup: bool = false,

    pub fn isValid(cfg: *const Config) Error!void {
        // TODO:(kogora): multithread version
        if (cfg.cores_num != 1) {
            return Error.NotSupported;
        }
    }
};

pub const GlobalCtx = struct {
    agent_heap: Memory.Heap(Agent),
    name_heap: Memory.Heap(Name),
    equation_fetcher: EquationFetcher,

    fn HeapType(comptime T: type) type {
        switch (BuildConfig.heap) {
            .basic => return Memory.BasicHeap(T),
            .objpool => return Memory.ObjPool(T),
        }
    }

    fn heapInit(comptime T: type, heap_size: usize, gpa: std.mem.Allocator) !Memory.Heap(T) {
        const basic_heap = try gpa.create(HeapType(T));

        basic_heap.* = switch (BuildConfig.heap) {
            .basic => try Memory.BasicHeap(T).init(gpa, heap_size),
            .objpool => try Memory.ObjPool(T).init(gpa, heap_size),
        };

        return basic_heap.heap();
    }

    fn heapDeinit(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) void {
        const basic_heap: *HeapType(T) = @ptrCast(@alignCast(heap.ptr));

        basic_heap.deinit(gpa);
        gpa.destroy(basic_heap);
    }

    fn equationFetcherInit(gpa: std.mem.Allocator) !EquationFetcher {
        const FetcherType = EquationFetcher.ThreeDequeEquationFetcher;
        const three_deque_equation_fetcher = try gpa.create(FetcherType);
        three_deque_equation_fetcher.* = .init(gpa);

        return three_deque_equation_fetcher.equationFetcher();
    }

    fn equationFetcherDeinit(equation_fetcher: EquationFetcher, gpa: std.mem.Allocator) void {
        const FetcherType = EquationFetcher.ThreeDequeEquationFetcher;
        const three_deque_equation_fetcher: *FetcherType = @ptrCast(@alignCast(equation_fetcher.ptr));
        three_deque_equation_fetcher.deinit();
        gpa.destroy(three_deque_equation_fetcher);
    }

    fn getHeapUser(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) Memory.Heap(T) {
        _ = gpa;
        const Concrete = HeapType(T);
        if (@hasDecl(Concrete, getUser)) {
            const concrete: *Concrete = @ptrCast(@alignCast(heap.ptr));
            return concrete.getUser();
        }

        // TODO:(kogora) mb should be unreachable
        return heap;
    }

    fn getFetcherUser(fetcher: EquationFetcher, gpa: std.mem.Allocator) EquationFetcher {
        _ = gpa;
        const Concrete = EquationFetcher.ThreeDequeEquationFetcher;
        if (@hasDecl(Concrete, getUser)) {
            const concrete: *Concrete = @ptrCast(@alignCast(fetcher.ptr));
            return concrete.getUser();
        }
        return fetcher;
    }

    pub fn init(runtime: *Runtime, config: Config) !GlobalCtx {
        const agent_heap = try heapInit(Agent, config.heap_size, runtime.gpa);
        errdefer heapDeinit(Agent, agent_heap, runtime.gpa);

        const name_heap = try heapInit(Name, config.heap_size, runtime.gpa);
        errdefer heapDeinit(Name, name_heap, runtime.gpa);

        const equation_fetcher = try equationFetcherInit(runtime.gpa);
        errdefer equationFetcherDeinit(equation_fetcher, runtime.gpa);

        return .{
            .agent_heap = agent_heap,
            .name_heap = name_heap,
            .equation_fetcher = equation_fetcher,
        };
    }

    pub fn deinit(self: *GlobalCtx, gpa: std.mem.Allocator) void {
        equationFetcherDeinit(self.equation_fetcher, gpa);
        heapDeinit(Name, self.name_heap, gpa);
        heapDeinit(Agent, self.agent_heap, gpa);
    }

    pub fn createLocal(self: GlobalCtx, gpa: std.mem.Allocator) Core.LocalCtx {
        return .{
            .agent_heap = getHeapUser(Agent, self.agent_heap, gpa),
            .name_heap = getHeapUser(Name, self.name_heap, gpa),
            .equation_fetcher = getFetcherUser(self.equation_fetcher, gpa),
        };
    }

    pub fn createVmLocal(self: GlobalCtx) !Core.LocalCtx {
        const S = struct {
            var exist: bool = false;
        };

        if (S.exist) {
            return error.AccessDenied;
        }

        S.exist = true;
        return .{
            .agent_heap = self.agent_heap,
            .name_heap = self.name_heap,
            .equation_fetcher = self.equation_fetcher,
        };
    }

    pub fn destroyLocal(self: *GlobalCtx, local_ctx: Core.LocalCtx, gpa: std.mem.Allocator) void {
        _ = self;
        _ = local_ctx;
        _ = gpa;
    }

    pub fn balanceEquations(self: *GlobalCtx) void {
        _ = self;
        // TODO:(kogora) equation balancer should be implemented as a part (and responsibility)
        // of the concrete fetcher, but it should provide an endpoint for vm-using. The function
        // is a wrapper above that endpoint.
    }

    pub fn pushEquation(self: GlobalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushEquation(self.name_heap, self.equation_fetcher, eq);
    }

    pub fn pushEquationNormalized(self: GlobalCtx, eq: Types.Equation) !void {
        try self.equation_fetcher.push(eq);
    }

    pub fn pushUrgentEquation(self: GlobalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushUrgentEquation(self.name_heap, self.equation_fetcher, eq);
    }
};

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
            Core.CoreId{ .worker = @intCast(core_id) },
            Core.CoreMode.singleThread,
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

pub fn init(runtime: *Runtime, config: Config, profiler: *Profiler) !Self {
    try config.isValid();

    const mode: Core.CoreMode = if (config.cores_num == 1) .singleThread else .multiThread;

    // TODO:(kogora): multithread version
    std.debug.assert(mode == Core.CoreMode.singleThread);

    var main_core: Core = undefined;
    var main_ctrl: ?*MainCtrl = null;

    var worker_ctrl: ?*WorkerCtrl = null;
    var cores: []Core = &.{};

    var global_ctx = try GlobalCtx.init(runtime, config);
    errdefer global_ctx.deinit(runtime.gpa);

    switch (mode) {
        .singleThread => {
            main_core = Core.init(
                Core.CoreId{ .main = {} },
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
                Core.CoreId{ .main = {} },
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

            cores = try createWorkerCores(runtime, global_ctx, config.cores_num, created_worker_ctrl, profiler);
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
        .config = config,
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
    _ = try self.main_core.runEquations();
}

inline fn execActivePairMultiCores(self: *Self) !void {
    if (self.config.warmup) {
        const rc = try self.main_core.runEquations();
        if (rc == Core.CoreRc.finishRc) {
            return;
        }

        self.global_ctx.balanceEquations();
    }

    // TODO:(kogora): multithread version
    _ = try self.cores[0].runEquations();
}

inline fn execActivePairMode(self: *Self, mode: Core.CoreMode) !void {
    switch (mode) {
        .singleThread => try self.execActivePairVmCore(),
        .multiThread => try self.execActivePairMultiCores(),
    }
}

inline fn execActivePair(self: *Self, mode: Core.CoreMode) !void {
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

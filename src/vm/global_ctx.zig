//! Heaps and equation fetcher shared by every core of the VM.
const std = @import("std");

const BuildConfig = @import("config");
const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;
const Types = Runtime.Types;
const Agent = Types.Agent;
const Name = Types.Name;
const EquationUnnormalized = Types.EquationUnnormalized;

const Core = @import("core.zig");
const Config = @import("config.zig").Config;
const Normalize = @import("normalize.zig");

pub const GlobalCtx = struct {
    agent_heap: Memory.Heap(Agent),
    name_heap: Memory.Heap(Name),
    equation_fetcher: EquationFetcher,

    /// Heaps and fetcher are shared between cores - multithread needs locked ones.
    locked: bool,

    const FetcherType = EquationFetcher.ThreeDequeEquationFetcher;
    const LockedFetcherType = EquationFetcher.LockedEquationFetcher;

    fn HeapType(comptime T: type) type {
        switch (BuildConfig.heap) {
            .basic => return Memory.BasicHeap(T),
            .objpool => return Memory.ObjPool(T),
        }
    }

    fn LockedHeapType(comptime T: type) type {
        return Memory.LockedHeap(T);
    }

    fn heapInit(
        comptime T: type,
        heap_size: usize,
        locked: bool,
        gpa: std.mem.Allocator,
    ) !Memory.Heap(T) {
        const basic_heap = try gpa.create(HeapType(T));
        errdefer gpa.destroy(basic_heap);

        basic_heap.* = switch (BuildConfig.heap) {
            .basic => try Memory.BasicHeap(T).init(gpa, heap_size),
            .objpool => try Memory.ObjPool(T).init(gpa, heap_size),
        };
        errdefer basic_heap.deinit(gpa);

        if (!locked) {
            return basic_heap.heap();
        }

        const locked_heap = try gpa.create(LockedHeapType(T));
        locked_heap.* = LockedHeapType(T).init(basic_heap.heap());

        return locked_heap.heap();
    }

    fn heapDeinit(
        comptime T: type,
        heap: Memory.Heap(T),
        locked: bool,
        gpa: std.mem.Allocator,
    ) void {
        var inner = heap;
        if (locked) {
            const locked_heap: *LockedHeapType(T) = @ptrCast(@alignCast(heap.ptr));
            inner = locked_heap.inner;
            gpa.destroy(locked_heap);
        }

        const basic_heap: *HeapType(T) = @ptrCast(@alignCast(inner.ptr));

        basic_heap.deinit(gpa);
        gpa.destroy(basic_heap);
    }

    fn equationFetcherInit(locked: bool, gpa: std.mem.Allocator) !EquationFetcher {
        const three_deque_equation_fetcher = try gpa.create(FetcherType);
        errdefer gpa.destroy(three_deque_equation_fetcher);

        three_deque_equation_fetcher.* = .init(gpa);
        errdefer three_deque_equation_fetcher.deinit();

        if (!locked) {
            return three_deque_equation_fetcher.equationFetcher();
        }

        const locked_fetcher = try gpa.create(LockedFetcherType);
        locked_fetcher.* = LockedFetcherType.init(three_deque_equation_fetcher.equationFetcher());

        return locked_fetcher.equationFetcher();
    }

    fn equationFetcherDeinit(
        equation_fetcher: EquationFetcher,
        locked: bool,
        gpa: std.mem.Allocator,
    ) void {
        var inner = equation_fetcher;
        if (locked) {
            const locked_fetcher: *LockedFetcherType = @ptrCast(@alignCast(equation_fetcher.ptr));
            inner = locked_fetcher.inner;
            gpa.destroy(locked_fetcher);
        }

        const three_deque_equation_fetcher: *FetcherType = @ptrCast(@alignCast(inner.ptr));
        three_deque_equation_fetcher.deinit();
        gpa.destroy(three_deque_equation_fetcher);
    }

    fn getHeapUser(comptime T: type, heap: Memory.Heap(T), locked: bool) Memory.Heap(T) {
        if (!locked) {
            return heap;
        }

        const locked_heap: *LockedHeapType(T) = @ptrCast(@alignCast(heap.ptr));
        return locked_heap.getUser();
    }

    fn getFetcherUser(fetcher: EquationFetcher, locked: bool) EquationFetcher {
        if (!locked) {
            return fetcher;
        }

        const locked_fetcher: *LockedFetcherType = @ptrCast(@alignCast(fetcher.ptr));
        return locked_fetcher.getUser();
    }

    pub fn init(runtime: *Runtime, config: Config) !GlobalCtx {
        const locked = config.getMode() == .multiThread;

        const agent_heap = try heapInit(Agent, config.heap_size, locked, runtime.gpa);
        errdefer heapDeinit(Agent, agent_heap, locked, runtime.gpa);

        const name_heap = try heapInit(Name, config.heap_size, locked, runtime.gpa);
        errdefer heapDeinit(Name, name_heap, locked, runtime.gpa);

        const equation_fetcher = try equationFetcherInit(locked, runtime.gpa);
        errdefer equationFetcherDeinit(equation_fetcher, locked, runtime.gpa);

        return .{
            .agent_heap = agent_heap,
            .name_heap = name_heap,
            .equation_fetcher = equation_fetcher,
            .locked = locked,
        };
    }

    pub fn deinit(self: *GlobalCtx, gpa: std.mem.Allocator) void {
        equationFetcherDeinit(self.equation_fetcher, self.locked, gpa);
        heapDeinit(Name, self.name_heap, self.locked, gpa);
        heapDeinit(Agent, self.agent_heap, self.locked, gpa);
    }

    pub fn createLocal(self: GlobalCtx, gpa: std.mem.Allocator) Core.LocalCtx {
        _ = gpa;
        return .{
            .agent_heap = getHeapUser(Agent, self.agent_heap, self.locked),
            .name_heap = getHeapUser(Name, self.name_heap, self.locked),
            .equation_fetcher = getFetcherUser(self.equation_fetcher, self.locked),
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

    pub fn destroyLocal(self: GlobalCtx, local_ctx: Core.LocalCtx, gpa: std.mem.Allocator) void {
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

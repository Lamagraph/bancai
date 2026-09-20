const std = @import("std");

const Config = @import("config");

pub const HeapKind = enum { basic, objpool };

const Agent = @import("types.zig").Agent;

pub fn Heap(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Error = std.mem.Allocator.Error;

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            allocOne: *const fn (*anyopaque) Error!*T,
            freeOne: *const fn (*anyopaque, elem: *T) void,
            printUsage: *const fn (*anyopaque) void,
        };

        pub inline fn allocOne(self: Self) Error!*T {
            return self.vtable.allocOne(self.ptr);
        }

        pub inline fn freeOne(self: Self, elem: *T) void {
            self.vtable.freeOne(self.ptr, elem);
        }

        pub inline fn printUsage(self: Self) void {
            self.vtable.printUsage(self.ptr);
        }
    };
}

pub fn LockedHeap(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: Heap(T),
        mutex: std.atomic.Mutex = .unlocked,

        pub fn init(inner: Heap(T)) Self {
            return .{ .inner = inner };
        }

        const vtable: Heap(T).VTable = .{
            .allocOne = allocOne,
            .freeOne = freeOne,
            .printUsage = printUsage,
        };

        pub fn heap(self: *Self) Heap(T) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn getUser(self: *Self) Heap(T) {
            return self.heap();
        }

        // std.atomic.Mutex is lock-free (tryLock/unlock only) - spin until
        // we get it.
        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn allocOne(ctx: *anyopaque) Heap(T).Error!*T {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.lock();
            defer self.mutex.unlock();

            return self.inner.allocOne();
        }

        fn freeOne(ctx: *anyopaque, elem: *T) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.lock();
            defer self.mutex.unlock();

            self.inner.freeOne(elem);
        }

        fn printUsage(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.lock();
            defer self.mutex.unlock();

            self.inner.printUsage();
        }
    };
}

pub fn BasicHeap(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Optional = union(enum) {
            free: void,
            item: T,
        };

        items: []Optional,
        free_idx: usize,
        capacity: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Self {
            const items = try gpa.alloc(Optional, capacity);
            @memset(items, .free);
            return .{
                .items = items,
                .capacity = capacity,
                .free_idx = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        const vtable: Heap(T).VTable = .{
            .allocOne = allocOne,
            .freeOne = freeOne,
            .printUsage = printUsage,
        };

        pub fn heap(self: *Self) Heap(T) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocOne(ctx: *anyopaque) !*T {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (self.findFree()) |idx| {
                self.free_idx = idx;
                self.items[idx] = .{ .item = undefined };

                return &self.items[idx].item;
            }

            return error.OutOfMemory;
        }

        fn findFree(self: *Self) ?usize {
            for (self.free_idx..self.capacity) |idx|
                if (self.items[idx] == .free) return idx;

            for (0..self.free_idx) |idx|
                if (self.items[idx] == .free) return idx;

            return null;
        }

        fn freeOne(ctx: *anyopaque, elem: *T) void {
            _ = ctx;

            const real_elem: *Optional = @fieldParentPtr("item", elem);

            if (Config.debug_printing.print_frees and real_elem.* == .free) {
                std.debug.print("Double-free\n", .{});
                return;
            }

            real_elem.* = .free;
        }

        fn printUsage(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var used: usize = 0;
            for (self.items) |maybe_elem| {
                if (maybe_elem == .item) {
                    used += 1;
                }
            }

            const free = self.items.len - used;
            std.debug.print("Heap({s}): {} used, {} free, sizeOf(Optional) = {}, sizeOf(T) = {}\n", .{
                @typeName(T),
                used,
                free,
                @sizeOf(Optional),
                @sizeOf(T),
            });
        }
    };
}

pub fn ObjPool(comptime T: type) type {
    return struct {
        const Self = @This();
        const Optional = union {
            value: T,
            ptr: ?*Optional,
        };

        items: []Optional,
        capacity: usize,
        free_list: ?*Optional,
        free_count: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Self {
            const items = try gpa.alloc(Optional, capacity);
            blockInit(items);
            return .{
                .items = items,
                .capacity = capacity,
                .free_list = @ptrCast(@alignCast(items)),
                .free_count = capacity,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        const vtable: Heap(T).VTable = .{
            .allocOne = allocOne,
            .freeOne = freeOne,
            .printUsage = printUsage,
        };

        pub fn heap(self: *Self) Heap(T) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocOne(ctx: *anyopaque) !*T {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const current_ptr = self.free_list orelse return error.OutOfMemory;
            self.free_list = current_ptr.*.ptr;
            self.free_count -= 1;
            return @ptrCast(current_ptr);
        }

        fn freeOne(ctx: *anyopaque, elem: *T) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            //we use this pointer as a pointer to Optional
            const new_ptr: *Optional = @ptrCast(@alignCast(elem));
            if (T == Agent) {
                elem.rc -= 1;
                if (elem.rc != 0) {
                    return;
                }
            }
            new_ptr.ptr = self.free_list;
            self.free_list = new_ptr;
            self.free_count += 1;
        }

        fn printUsage(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const used = self.items.len - self.free_count;
            std.debug.print("Heap({s}): {} used, {} free, sizeOf(T) = {}\n", .{
                @typeName(T),
                used,
                self.free_count,
                @sizeOf(T),
            });
        }

        fn blockInit(items: []Optional) void {
            for (0..items.len) |i| {
                if (i == items.len - 1) {
                    items[i] = .{ .ptr = null };
                } else {
                    items[i] = .{ .ptr = &items[i + 1] };
                }
            }
        }
    };
}

test "ObjPool: basic allocation and free" {
    const gpa = std.testing.allocator;

    const meow = struct {
        meow: i32,
        sh: u64,
    };

    var pool = try ObjPool(meow).init(gpa, 4);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();
    const item_ptr = try my_heap.allocOne();

    item_ptr.meow = 1;
    item_ptr.sh = 2;

    try std.testing.expectEqual(@as(meow, .{ .meow = 1, .sh = 2 }), item_ptr.*);

    my_heap.freeOne(item_ptr);
}

test "ObjPool: basic allocation and free, type smaller than usize" {
    const gpa = std.testing.allocator;

    var pool = try ObjPool(i32).init(gpa, 4);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();
    const item_ptr = try my_heap.allocOne();

    item_ptr.* = 56;
    try std.testing.expectEqual(@as(i32, 56), item_ptr.*);

    my_heap.freeOne(item_ptr);
}

test "ObjPool: basic allocation and free with data alignment smaller than usize alignment" {
    const gpa = std.testing.allocator;

    const meow2 = struct {
        ears: u8,
        eyes: u8,
        vibrases: u32,
        legs: u16,
    };

    var pool = try ObjPool(meow2).init(gpa, 4);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();
    const item_ptr = try my_heap.allocOne();

    item_ptr.ears = 0;
    item_ptr.legs = 0;
    item_ptr.vibrases = 7;
    item_ptr.eyes = 89;

    try std.testing.expectEqual(@as(meow2, .{ .ears = 0, .legs = 0, .vibrases = 7, .eyes = 89 }), item_ptr.*);

    my_heap.freeOne(item_ptr);
}

test "ObjPool: Out of memory " {
    const gpa = std.testing.allocator;

    var pool = try ObjPool(u64).init(gpa, 1);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();
    const item_ptr = try my_heap.allocOne();
    const item_ptr2 = my_heap.allocOne();

    item_ptr.* = 79;

    try std.testing.expectEqual(@as(u64, 79), item_ptr.*);
    try std.testing.expectError(error.OutOfMemory, item_ptr2);

    my_heap.freeOne(item_ptr);
}

test "ObjPool: alloc after free" {
    const gpa = std.testing.allocator;

    const meow = struct {
        meow: i32,
        sh: u64,
    };

    var pool = try ObjPool(meow).init(gpa, 3);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();
    const item_ptr = try my_heap.allocOne();
    _ = try my_heap.allocOne();
    _ = try my_heap.allocOne();

    item_ptr.meow = 1;
    item_ptr.sh = 2;
    my_heap.freeOne(item_ptr);

    const item_ptr2 = try my_heap.allocOne();
    item_ptr2.meow = 1;
    item_ptr2.sh = 2;

    try std.testing.expectEqual(@as(meow, .{ .meow = 1, .sh = 2 }), item_ptr2.*);

    my_heap.freeOne(item_ptr2);
}

test "ObjPool: basic alloc of size = usize " {
    const gpa = std.testing.allocator;

    var pool = try ObjPool(i64).init(gpa, 10000);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();
    const p1 = try my_heap.allocOne();
    const p2 = try my_heap.allocOne();
    const p3 = try my_heap.allocOne();

    try std.testing.expect(p1 != p2);
    try std.testing.expect(p1 != p3);
    try std.testing.expect(p2 != p3);
}

test "ObjPool: LIFO allocation order after free" {
    const gpa = std.testing.allocator;

    const Toy = struct {
        id: u32,
        weight: f32,
    };

    var pool = try ObjPool(Toy).init(gpa, 4);
    defer pool.deinit(gpa);

    const my_heap = pool.heap();

    const a = try my_heap.allocOne();
    const b = try my_heap.allocOne();
    const c = try my_heap.allocOne();

    a.id = 10;
    a.weight = 1.5;

    b.id = 20;
    b.weight = 2.5;

    c.id = 30;
    c.weight = 3.5;

    my_heap.freeOne(b);
    my_heap.freeOne(a);

    const first_reallocated = try my_heap.allocOne();
    const second_reallocated = try my_heap.allocOne();

    try std.testing.expectEqual(a, first_reallocated);
    try std.testing.expectEqual(b, second_reallocated);

    first_reallocated.id = 100;
    second_reallocated.id = 200;

    try std.testing.expectEqual(@as(u32, 100), a.id);
    try std.testing.expectEqual(@as(u32, 200), b.id);

    my_heap.freeOne(c);
    my_heap.freeOne(first_reallocated);
    my_heap.freeOne(second_reallocated);
}

test "ObjPool: interior slots are misaligned for the intrusive free-list pointer " {
    const gpa = std.testing.allocator;
    const Meow = struct {
        ears: u8,
        eyes: u8,
        legs: u16,
        whiskers: u32,
        tail: u32,
    };

    const ptr_align = @alignOf(*Meow);
    if (@sizeOf(Meow) % ptr_align == 0) return error.SkipZigTest;

    var pool = try ObjPool(Meow).init(gpa, 2);
    defer pool.deinit(gpa);
}

test "LockedHeap: wraps allocation/free through to the inner heap" {
    const gpa = std.testing.allocator;

    const Meow = struct {
        meow: i32,
    };

    var pool = try ObjPool(Meow).init(gpa, 4);
    defer pool.deinit(gpa);

    var locked = LockedHeap(Meow).init(pool.heap());
    const my_heap = locked.heap();

    const item_ptr = try my_heap.allocOne();
    item_ptr.meow = 42;
    try std.testing.expectEqual(@as(i32, 42), item_ptr.meow);

    my_heap.freeOne(item_ptr);

    // The slot should be reusable now that it's freed.
    const item_ptr2 = try my_heap.allocOne();
    try std.testing.expectEqual(item_ptr, item_ptr2);
    my_heap.freeOne(item_ptr2);
}

test "LockedHeap: getUser hands back a working copy of the heap" {
    const gpa = std.testing.allocator;

    const Meow = struct {
        meow: i32,
    };

    var pool = try ObjPool(Meow).init(gpa, 4);
    defer pool.deinit(gpa);

    var locked = LockedHeap(Meow).init(pool.heap());

    const my_heap = locked.getUser();
    const item_ptr = try my_heap.allocOne();
    item_ptr.meow = 42;
    try std.testing.expectEqual(@as(i32, 42), item_ptr.meow);

    my_heap.freeOne(item_ptr);
}

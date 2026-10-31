//! Multithread part of the VM: the core threads and their control.
const std = @import("std");

const Runtime = @import("shared_runtime");

const Core = @import("../core.zig");
const VmError = @import("../core_types.zig").Error;
const Config = @import("../config.zig").Config;
const GlobalCtx = @import("../global_ctx.zig").GlobalCtx;

const MainCtrl = @import("main_ctrl.zig");
const DoorBell = @import("door_bell.zig").DoorBell;
const Ring = @import("door_bell.zig").Ring;
const Slot = @import("slot.zig").Slot;

const log = std.log.scoped(.vm);

pub const VmState = enum {
    vm_init,
    vm_eval,
    vm_stop,
    vm_exit,
};

var available_core_id: u32 = 0;

pub const Multi = struct {
    main_ctrl: *MainCtrl,
    bell: *DoorBell,

    state: VmState,

    slots: []Slot,

    fn slotsDeinit(
        slots: []Slot,
        global_ctx: GlobalCtx,
        gpa: std.mem.Allocator,
    ) void {
        for (slots) |*slot| {
            slot.deinit(global_ctx, gpa);
        }

        gpa.free(slots);
    }

    fn slotsInit(
        runtime: *Runtime,
        global_ctx: GlobalCtx,
        slots_cnt: usize,
        bell: *DoorBell,
        gpa: std.mem.Allocator,
    ) ![]Slot {
        const slots: []Slot = try gpa.alloc(Slot, slots_cnt);
        errdefer gpa.free(slots);

        // Only the first `inited_cnt` slots own resources.
        var inited_cnt: usize = 0;
        errdefer for (slots[0..inited_cnt]) |*slot| {
            slot.deinit(global_ctx, gpa);
        };

        for (slots) |*slot| {
            try slot.init(available_core_id, runtime, bell, gpa, global_ctx);
            inited_cnt += 1;

            available_core_id += 1;
        }

        return slots;
    }

    fn mainCtrlDeinit(main_ctrl: *MainCtrl, gpa: std.mem.Allocator) void {
        main_ctrl.deinit();
        gpa.destroy(main_ctrl);
    }

    fn mainCtrlInit(gpa: std.mem.Allocator) !*MainCtrl {
        const main_ctrl = try gpa.create(MainCtrl);
        errdefer gpa.destroy(main_ctrl);

        main_ctrl.* = MainCtrl.init();
        return main_ctrl;
    }

    fn bellDeinit(bell: *DoorBell, gpa: std.mem.Allocator) void {
        gpa.destroy(bell);
    }

    fn bellInit(gpa: std.mem.Allocator, io: std.Io) !*DoorBell {
        const bell = try gpa.create(DoorBell);
        bell.* = DoorBell.init(io);
        return bell;
    }

    pub fn deinit(
        self: *Multi,
        global_ctx: GlobalCtx,
        gpa: std.mem.Allocator,
    ) void {
        mainCtrlDeinit(self.main_ctrl, gpa);
        slotsDeinit(self.slots, global_ctx, gpa);
        bellDeinit(self.bell, gpa);
    }

    pub fn init(
        slot_cnt: usize,
        gpa: std.mem.Allocator,
        runtime: *Runtime,
        global_ctx: GlobalCtx,
        io: std.Io,
    ) !Multi {
        if (slot_cnt > Config.max_core_cnt) {
            return VmError.NotSupported;
        }

        const bell = try bellInit(gpa, io);
        errdefer bellDeinit(bell, gpa);

        const slots = try slotsInit(runtime, global_ctx, slot_cnt, bell, gpa);
        errdefer slotsDeinit(slots, global_ctx, gpa);

        const main_ctrl = try mainCtrlInit(gpa);
        errdefer mainCtrlDeinit(main_ctrl, gpa);

        return .{
            .state = VmState.vm_init,
            .slots = slots,
            .main_ctrl = main_ctrl,
            .bell = bell,
        };
    }

    pub fn anyCoreThreadSpawned(self: *Multi) bool {
        for (self.slots) |*slot| {
            if (slot.thread != null) {
                return true;
            }
        }

        return false;
    }

    fn spawnCoreThreads(self: *Multi) !void {
        for (self.slots) |*slot| {
            slot.thread = try std.Thread.spawn(.{}, Core.eval, .{&slot.core});
        }
    }

    fn killCoreThreadsUnsafe(self: *Multi) void {
        for (self.slots) |*slot| {
            if (slot.thread) |thread| {
                thread.join();
                slot.thread = null;
            }
        }
    }

    fn setVmState(self: *Multi, state: VmState) void {
        if (self.state != state) {
            log.debug("vm: {s} -> {s}", .{ @tagName(self.state), @tagName(state) });
        }

        self.state = state;
    }

    pub const Transition = struct {
        const ScatterFn = *const fn (*Slot) VmError!void;

        pub const GatherState = struct {
            all_done: bool,
            any_busy: bool,

            pub fn init() GatherState {
                return .{ .all_done = true, .any_busy = false };
            }
        };

        const GatherFn = *const fn (*Slot, *GatherState) VmError!void;

        from_state: VmState,
        to_state: VmState,
        scatter: ScatterFn,
        gather: GatherFn,
        rescatter: ?ScatterFn = null,

        const eval_transition: Transition = .{
            .from_state = .vm_eval,
            .to_state = .vm_stop,
            .scatter = Slot.scatterEval,
            .gather = Slot.gatherEvalDone,
            .rescatter = Slot.rescatterIfIdle,
        };

        const stop_transition: Transition = .{
            .from_state = .vm_stop,
            .to_state = .vm_stop,
            .scatter = Slot.scatterStop,
            .gather = Slot.gatherStopped,
        };

        const exit_transition: Transition = .{
            .from_state = .vm_exit,
            .to_state = .vm_exit,
            .scatter = Slot.scatterExit,
            .gather = Slot.gatherExited,
        };
    };

    fn run(self: *Multi, transition: Transition) VmError!?Ring {
        const heard = self.bell.listen();

        var state = Transition.GatherState.init();
        for (self.slots) |*slot| {
            try transition.gather(slot, &state);
        }

        if (state.all_done) return null;

        if (state.any_busy) {
            if (transition.rescatter) |rescatter| {
                for (self.slots) |*slot| {
                    try rescatter(slot);
                }
            }
        }

        return heard;
    }

    fn transit(self: *Multi, transition: Transition) VmError!void {
        for (self.slots) |*slot| {
            try transition.scatter(slot);
        }

        self.setVmState(transition.from_state);

        while (try self.run(transition)) |heard| {
            self.bell.sleep(heard);
        }

        self.setVmState(transition.to_state);
    }

    pub fn start(self: *Multi) !void {
        std.debug.assert(!self.anyCoreThreadSpawned());

        errdefer self.exit();
        try self.spawnCoreThreads();

        try self.transit(Transition.stop_transition);
    }

    pub fn eval(self: *Multi) !void {
        try self.transit(Transition.eval_transition);
    }

    pub fn exit(self: *Multi) void {
        self.transit(Transition.exit_transition) catch unreachable;

        self.killCoreThreadsUnsafe();
    }
};

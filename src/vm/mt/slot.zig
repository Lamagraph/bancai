//! A worker core together with its thread and control channels.
const std = @import("std");

const Runtime = @import("shared_runtime");

const Core = @import("../core.zig");
const CoreId = @import("../core_types.zig").CoreId;
const VmError = @import("../core_types.zig").Error;
const GlobalCtx = @import("../global_ctx.zig").GlobalCtx;

const WorkerCtrl = @import("worker_ctrl.zig");
const DoorBell = @import("door_bell.zig").DoorBell;
const SigChannel = @import("signals.zig").SigChannel;
const GatherState = @import("multi.zig").Multi.Transition.GatherState;

pub const Slot = struct {
    ctrl: *WorkerCtrl,
    sig_ch: *SigChannel,

    core: Core,
    thread: ?std.Thread = null,

    pub fn deinit(
        self: *Slot,
        global_ctx: GlobalCtx,
        gpa: std.mem.Allocator,
    ) void {
        std.debug.assert(self.thread == null);

        gpa.destroy(self.sig_ch);
        gpa.destroy(self.ctrl);
        global_ctx.destroyLocal(self.core.local_ctx, gpa);
    }

    pub fn init(
        self: *Slot,
        raw_id: u32,
        runtime: *Runtime,
        bell: *DoorBell,
        gpa: std.mem.Allocator,
        global_ctx: GlobalCtx,
    ) !void {
        const ctx = global_ctx.createLocal(gpa);
        errdefer global_ctx.destroyLocal(ctx, gpa);

        const ctrl = try gpa.create(WorkerCtrl);
        errdefer gpa.destroy(ctrl);

        const sig_ch = try gpa.create(SigChannel);
        errdefer gpa.destroy(sig_ch);

        sig_ch.* = SigChannel.init();
        ctrl.* = WorkerCtrl.init(sig_ch, bell);

        self.* = .{
            .ctrl = ctrl,
            .sig_ch = sig_ch,
            .core = Core.init(
                CoreId{ .worker = raw_id },
                .multiThread,
                runtime,
                Core.CoreCtrl{ .worker = ctrl },
                ctx,
                null,
            ),
        };
    }

    pub fn rawId(slot: *const Slot) u32 {
        return slot.core.id.worker;
    }

    pub fn scatterStop(slot: *Slot) VmError!void {
        if (slot.thread == null) {
            return VmError.CoreFailed;
        }

        _ = slot.sig_ch.putSignal(.stop_sig);
    }

    pub fn scatterEval(slot: *Slot) VmError!void {
        if (slot.thread == null) {
            return VmError.CoreFailed;
        }

        _ = slot.sig_ch.putSignal(.eval_sig);
    }

    pub fn scatterExit(slot: *Slot) VmError!void {
        if (slot.thread != null) {
            _ = slot.sig_ch.putSignal(.kill_sig);
        }
    }

    pub fn gatherStopped(slot: *Slot, state: *GatherState) VmError!void {
        const pending = slot.sig_ch.isPending();

        const stopped = switch (slot.ctrl.getState()) {
            .goner, .corpse => return VmError.CoreFailed,
            .newborn, .busy => false,
            .applicant => !pending,
        };

        if (!stopped) state.all_done = false;
    }

    pub fn gatherEvalDone(slot: *Slot, state: *GatherState) VmError!void {
        const pending = slot.sig_ch.isPending();

        const done = switch (slot.ctrl.getState()) {
            .goner, .corpse => return VmError.CoreFailed,
            .busy => busy: {
                state.any_busy = true;
                break :busy false;
            },
            .applicant => !pending,
            .newborn => unreachable,
        };

        if (!done) state.all_done = false;
    }

    pub fn rescatterIfIdle(slot: *Slot) VmError!void {
        if (slot.sig_ch.isPending()) return;
        if (slot.ctrl.getState() != .applicant) return;

        _ = slot.sig_ch.putSignal(.eval_sig);
    }

    pub fn gatherExited(slot: *Slot, state: *GatherState) VmError!void {
        if (slot.thread == null) return;

        if (slot.ctrl.getState() != .corpse) state.all_done = false;
    }
};

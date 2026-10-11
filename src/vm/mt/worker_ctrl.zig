//! Worker core state and signal channel, shared with the VM.
const std = @import("std");

const DoorBell = @import("door_bell.zig").DoorBell;
const Sig = @import("signals.zig").Sig;
const SigChannel = @import("signals.zig").SigChannel;

const Self = @This();

const AtomicState = std.atomic.Value(State);

raw_state: AtomicState,
sig_ch: *SigChannel,
bell: *DoorBell,
pending: ?SigChannel.Pending = null,

pub fn init(sig_ch: *SigChannel, bell: *DoorBell) Self {
    return .{
        .sig_ch = sig_ch,
        .bell = bell,
        .raw_state = AtomicState.init(State.newborn),
    };
}

pub inline fn receiveSig(self: *Self) ?Sig {
    std.debug.assert(self.pending == null);

    const pending = self.sig_ch.peekSignals() orelse return null;
    self.pending = pending;

    return pending.signal().?;
}

pub inline fn ackSig(self: *Self) void {
    self.sig_ch.ackSignals(self.pending.?);
    self.pending = null;
    self.bell.ring();
}

pub inline fn putState(self: *Self, state: State) void {
    self.raw_state.store(state, .release);
    self.bell.ring();
}

pub inline fn getState(self: *Self) State {
    return self.raw_state.load(.acquire);
}

pub inline fn getStatePriv(self: *Self) State {
    return self.raw_state.load(.monotonic);
}

pub const State = enum(u8) {
    newborn,
    applicant,
    busy,
    goner,
    corpse,

    pub inline fn applicantState(self: State) State {
        std.debug.assert(self == .newborn or self == .applicant or self == .busy);
        return .applicant;
    }

    pub inline fn gonerState(self: State) State {
        std.debug.assert(self == .applicant or self == .busy);
        return .goner;
    }

    pub inline fn corpseState(self: State) State {
        std.debug.assert(self == .goner);
        return .corpse;
    }

    pub fn sigNextState(
        self: State,
        sig: Sig,
    ) ?State {
        return switch (sig) {
            .kill_sig => switch (self) {
                .applicant, .busy => .goner,
                else => null,
            },
            .eval_sig => switch (self) {
                .applicant, .busy => .busy,
                else => null,
            },
            .stop_sig => switch (self) {
                .busy => .applicant,
                else => null,
            },
        };
    }
};

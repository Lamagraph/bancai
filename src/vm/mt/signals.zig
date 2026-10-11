//! Signals the VM sends to worker cores.

const std = @import("std");

pub const SigBits = u32;
pub const Sig = enum(u8) {
    kill_sig = 0,
    stop_sig = 1,
    eval_sig = 2,

    /// In conflict: kill_sig > stop_sig > eval_sig.
    const by_priority = [_]Sig{ .kill_sig, .stop_sig, .eval_sig };

    inline fn mask(sig: Sig) SigBits {
        return @as(SigBits, 1) << @intCast(@intFromEnum(sig));
    }
};

pub const SigChannel = struct {
    const Self = @This();

    const Channel = std.atomic.Value(SigBits);
    const init_value: SigBits = 0;

    ch: Channel align(std.atomic.cache_line) = Channel.init(init_value),

    pub fn init() Self {
        return .{};
    }

    pub const Pending = struct {
        bits: SigBits,

        pub fn signal(self: Pending) ?Sig {
            inline for (Sig.by_priority) |sig| {
                if (self.bits & sig.mask() != 0) {
                    return sig;
                }
            }

            return null;
        }
    };

    pub fn peekSignals(self: *Self) ?Pending {
        const bits = self.ch.load(.acquire);
        return if (bits == init_value) null else .{ .bits = bits };
    }

    pub fn ackSignals(self: *Self, pending: Pending) void {
        _ = self.ch.fetchAnd(~pending.bits, .release);
    }

    pub fn putSignal(self: *Self, sig: Sig) bool {
        const prev = self.ch.fetchOr(sig.mask(), .release);
        return prev & sig.mask() == 0;
    }

    pub fn isPending(self: *Self) bool {
        return self.ch.load(.acquire) != init_value;
    }
};

fn testTakeSignal(ch: *SigChannel) ?Sig {
    const pending = ch.peekSignals() orelse return null;
    ch.ackSignals(pending);
    return pending.signal();
}

test "SigChannel: empty channel" {
    var ch = SigChannel.init();
    try std.testing.expect(!ch.isPending());
    try std.testing.expectEqual(@as(?Sig, null), testTakeSignal(&ch));
}

test "SigChannel: put twice is reported" {
    var ch = SigChannel.init();
    try std.testing.expect(ch.putSignal(.eval_sig));
    try std.testing.expect(!ch.putSignal(.eval_sig));
    try std.testing.expect(ch.isPending());
    try std.testing.expectEqual(@as(?Sig, .eval_sig), testTakeSignal(&ch));
    try std.testing.expect(!ch.isPending());
}

test "SigChannel: kill_sig > stop_sig > eval_sig" {
    var ch = SigChannel.init();
    _ = ch.putSignal(.eval_sig);
    _ = ch.putSignal(.stop_sig);
    try std.testing.expectEqual(@as(?Sig, .stop_sig), testTakeSignal(&ch));

    _ = ch.putSignal(.eval_sig);
    _ = ch.putSignal(.kill_sig);
    _ = ch.putSignal(.stop_sig);
    try std.testing.expectEqual(@as(?Sig, .kill_sig), testTakeSignal(&ch));
    try std.testing.expect(!ch.isPending());
}

test "SigChannel: ack keeps signals put after the peek" {
    var ch = SigChannel.init();
    _ = ch.putSignal(.eval_sig);

    const pending = ch.peekSignals().?;
    _ = ch.putSignal(.kill_sig);
    ch.ackSignals(pending);

    try std.testing.expectEqual(@as(?Sig, .kill_sig), testTakeSignal(&ch));
}

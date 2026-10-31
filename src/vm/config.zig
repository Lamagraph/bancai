//! VM configuration.

const VmError = @import("core_types.zig").Error;
const CoreMode = @import("core_types.zig").CoreMode;

pub const Config = struct {
    // FIX:(kogora) move to build config
    pub const max_core_cnt = 64;

    cores_num: usize,
    heap_size: usize,

    warmup: bool = false, // TODO:(kogora) support it

    pub fn isValid(cfg: *const Config) !void {
        if (cfg.cores_num == 0) {
            return VmError.NotSupported;
        }

        if (cfg.cores_num > max_core_cnt) {
            return VmError.NotSupported;
        }
    }

    pub fn getMode(cfg: *const Config) CoreMode {
        return if (cfg.cores_num == 1) .singleThread else .multiThread;
    }
};

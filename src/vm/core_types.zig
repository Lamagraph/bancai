//! Types shared by the VM and its cores.
const std = @import("std");

pub const CoreMode = enum { singleThread, multiThread };
pub const CoreRole = enum { main, worker };

pub const CoreRc = enum(u8) {
    Err = 1,
};

pub const Error = error{
    NotSupported,
    CoreFailed,
};

pub const CoreId = union(CoreRole) {
    main: void,
    worker: u32,
};

const std = @import("std");

pub const Fd = std.posix.fd_t;
pub const ExitStatus = u8;
pub const Pid = std.posix.pid_t;
pub const SignalNo = u6;

pub const MAX_FD = 1024;
pub const STDIN = 0;
pub const STDOUT = 1;
pub const STDERR = 2;

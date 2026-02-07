const std = @import("std");
const posix = @import("posix.zig");

const linux = std.os.linux;
const c = std.c;

const SIG = linux.SIG;
const Sigaction = linux.Sigaction;

pub const SIGINT: u6 = 2;
pub const SIGQUIT: u6 = 3;
pub const SIGTSTP: u6 = 20;
pub const SIGTTIN: u6 = 21;
pub const SIGTTOU: u6 = 22;
pub const SIGCHLD: u6 = 17;
pub const SIGCONT: u6 = 18;
pub const SIGTERM: u6 = 15;
pub const SIGHUP: u6 = 1;
pub const SIGPIPE: u6 = 13;
pub const SIGUSR1: u6 = 10;
pub const SIGUSR2: u6 = 12;
pub const SIGABRT: u6 = 6;
pub const SIGALRM: u6 = 14;
pub const SIGKILL: u6 = 9;
pub const SIGSTOP: u6 = 19;

pub fn sigNameFromNum(signum: u6) ?[]const u8 {
    return switch (signum) {
        1 => "HUP",
        2 => "INT",
        3 => "QUIT",
        6 => "ABRT",
        9 => "KILL",
        10 => "USR1",
        12 => "USR2",
        13 => "PIPE",
        14 => "ALRM",
        15 => "TERM",
        17 => "CHLD",
        18 => "CONT",
        19 => "STOP",
        20 => "TSTP",
        21 => "TTIN",
        22 => "TTOU",
        else => null,
    };
}

pub const TRAP_EXIT: usize = 0;
pub const TRAP_ERR: usize = 33;
const TRAP_COUNT = 34;

pub var trap_handlers: [TRAP_COUNT]?[]const u8 = [_]?[]const u8{null} ** TRAP_COUNT;
pub var received_signals: [32]bool = [_]bool{false} ** 32;

fn signalHandler(sig: SIG) callconv(.c) void {
    const s: usize = @intFromEnum(sig);
    if (s < 32) {
        received_signals[s] = true;
    }
}

fn toSIG(signum: u6) SIG {
    return @enumFromInt(signum);
}

pub fn installHandler(signum: u6) void {
    const sa = Sigaction{
        .handler = .{ .handler = &signalHandler },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(toSIG(signum), &sa, null);
}

pub fn ignoreSignal(signum: u6) void {
    const sa = Sigaction{
        .handler = .{ .handler = SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(toSIG(signum), &sa, null);
}

pub fn defaultSignal(signum: u6) void {
    const sa = Sigaction{
        .handler = .{ .handler = SIG.DFL },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(toSIG(signum), &sa, null);
}

pub fn setupInteractiveSignals() void {
    ignoreSignal(SIGINT);
    ignoreSignal(SIGQUIT);
    ignoreSignal(SIGTSTP);
    ignoreSignal(SIGTTIN);
    ignoreSignal(SIGTTOU);
}

pub fn setupChildSignals() void {
    defaultSignal(SIGINT);
    defaultSignal(SIGQUIT);
    defaultSignal(SIGTSTP);
    defaultSignal(SIGTTIN);
    defaultSignal(SIGTTOU);
}

pub fn setTrap(signum: u6, action: ?[]const u8) void {
    if (signum < 32) {
        trap_handlers[@intCast(signum)] = action;
        if (action) |_| {
            installHandler(signum);
        } else {
            defaultSignal(signum);
        }
    }
}

pub fn getExitTrap() ?[]const u8 {
    return trap_handlers[TRAP_EXIT];
}

pub fn setExitTrap(action: ?[]const u8) void {
    trap_handlers[TRAP_EXIT] = action;
}

pub fn getErrTrap() ?[]const u8 {
    return trap_handlers[TRAP_ERR];
}

pub fn setErrTrap(action: ?[]const u8) void {
    trap_handlers[TRAP_ERR] = action;
}

pub fn checkPendingSignals() ?u6 {
    for (0..32) |i| {
        if (received_signals[i]) {
            received_signals[i] = false;
            return @intCast(i);
        }
    }
    return null;
}

pub fn sendSignal(pid: posix.pid_t, sig: u6) !void {
    const rc = c.kill(pid, toSIG(sig));
    if (rc < 0) return error.KillFailed;
}

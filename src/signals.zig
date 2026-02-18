const std = @import("std");
const posix = @import("posix.zig");

const c = std.c;

const SIG = c.SIG;
const Sigaction = c.Sigaction;

fn sigNum(sig: SIG) u6 {
    return @intCast(@intFromEnum(sig));
}

pub const SIGINT: u6 = sigNum(SIG.INT);
pub const SIGQUIT: u6 = sigNum(SIG.QUIT);
pub const SIGTSTP: u6 = sigNum(SIG.TSTP);
pub const SIGTTIN: u6 = sigNum(SIG.TTIN);
pub const SIGTTOU: u6 = sigNum(SIG.TTOU);
pub const SIGCHLD: u6 = sigNum(SIG.CHLD);
pub const SIGCONT: u6 = sigNum(SIG.CONT);
pub const SIGTERM: u6 = sigNum(SIG.TERM);
pub const SIGHUP: u6 = sigNum(SIG.HUP);
pub const SIGPIPE: u6 = sigNum(SIG.PIPE);
pub const SIGUSR1: u6 = sigNum(SIG.USR1);
pub const SIGUSR2: u6 = sigNum(SIG.USR2);
pub const SIGABRT: u6 = sigNum(SIG.ABRT);
pub const SIGALRM: u6 = sigNum(SIG.ALRM);
pub const SIGKILL: u6 = sigNum(SIG.KILL);
pub const SIGSTOP: u6 = sigNum(SIG.STOP);
pub const SIGURG: u6 = sigNum(SIG.URG);

pub fn sigNameFromNum(signum: u6) ?[]const u8 {
    if (signum == 0) return "EXIT";
    if (signum == SIGHUP) return "HUP";
    if (signum == SIGINT) return "INT";
    if (signum == SIGQUIT) return "QUIT";
    if (signum == SIGABRT) return "ABRT";
    if (signum == SIGALRM) return "ALRM";
    if (signum == SIGTERM) return "TERM";
    if (signum == SIGKILL) return "KILL";
    if (signum == SIGSTOP) return "STOP";
    if (signum == SIGCHLD) return "CHLD";
    if (signum == SIGCONT) return "CONT";
    if (signum == SIGTSTP) return "TSTP";
    if (signum == SIGTTIN) return "TTIN";
    if (signum == SIGTTOU) return "TTOU";
    if (signum == SIGPIPE) return "PIPE";
    if (signum == SIGUSR1) return "USR1";
    if (signum == SIGUSR2) return "USR2";
    if (signum == SIGURG) return "URG";
    return null;
}

pub fn sigFullName(signum: u6) ?[]const u8 {
    if (signum == 0) return "EXIT";
    if (signum == SIGHUP) return "SIGHUP";
    if (signum == SIGINT) return "SIGINT";
    if (signum == SIGQUIT) return "SIGQUIT";
    if (signum == SIGABRT) return "SIGABRT";
    if (signum == SIGALRM) return "SIGALRM";
    if (signum == SIGTERM) return "SIGTERM";
    if (signum == SIGKILL) return "SIGKILL";
    if (signum == SIGSTOP) return "SIGSTOP";
    if (signum == SIGCHLD) return "SIGCHLD";
    if (signum == SIGCONT) return "SIGCONT";
    if (signum == SIGTSTP) return "SIGTSTP";
    if (signum == SIGTTIN) return "SIGTTIN";
    if (signum == SIGTTOU) return "SIGTTOU";
    if (signum == SIGPIPE) return "SIGPIPE";
    if (signum == SIGUSR1) return "SIGUSR1";
    if (signum == SIGUSR2) return "SIGUSR2";
    if (signum == SIGURG) return "SIGURG";
    return null;
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
        .mask = std.mem.zeroes(c.sigset_t),
        .flags = 0,
    };
    _ = c.sigaction(toSIG(signum), &sa, null);
}

pub fn ignoreSignal(signum: u6) void {
    const sa = Sigaction{
        .handler = .{ .handler = SIG.IGN },
        .mask = std.mem.zeroes(c.sigset_t),
        .flags = 0,
    };
    _ = c.sigaction(toSIG(signum), &sa, null);
}

pub fn defaultSignal(signum: u6) void {
    const sa = Sigaction{
        .handler = .{ .handler = SIG.DFL },
        .mask = std.mem.zeroes(c.sigset_t),
        .flags = 0,
    };
    _ = c.sigaction(toSIG(signum), &sa, null);
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

pub fn clearTrapsForSubshell() void {
    for (1..32) |i| {
        if (trap_handlers[i]) |action| {
            if (action.len > 0) {
                trap_handlers[i] = null;
                defaultSignal(@intCast(i));
            }
        }
    }
    trap_handlers[TRAP_EXIT] = null;
    trap_handlers[TRAP_ERR] = null;
}

pub fn setTrap(signum: u6, action: ?[]const u8) void {
    if (signum < 32) {
        trap_handlers[@intCast(signum)] = action;
        if (signum == SIGKILL or signum == SIGSTOP) return;
        if (action) |a| {
            if (a.len == 0) {
                ignoreSignal(signum);
            } else {
                installHandler(signum);
            }
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

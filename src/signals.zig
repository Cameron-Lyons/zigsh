const std = @import("std");
const posix = @import("posix.zig");

const c = std.c;

const SIG = c.SIG;
const Sigaction = c.Sigaction;

pub const SIGNAL_LIMIT: usize = 32;
pub const SIGNAL_LIMIT_U6: u6 = @intCast(SIGNAL_LIMIT);

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

const SignalNameEntry = struct {
    num: u6,
    short: []const u8,
    full: []const u8,
};

const signal_name_entries = [_]SignalNameEntry{
    .{ .num = SIGHUP, .short = "HUP", .full = "SIGHUP" },
    .{ .num = SIGINT, .short = "INT", .full = "SIGINT" },
    .{ .num = SIGQUIT, .short = "QUIT", .full = "SIGQUIT" },
    .{ .num = SIGABRT, .short = "ABRT", .full = "SIGABRT" },
    .{ .num = SIGALRM, .short = "ALRM", .full = "SIGALRM" },
    .{ .num = SIGTERM, .short = "TERM", .full = "SIGTERM" },
    .{ .num = SIGKILL, .short = "KILL", .full = "SIGKILL" },
    .{ .num = SIGSTOP, .short = "STOP", .full = "SIGSTOP" },
    .{ .num = SIGCHLD, .short = "CHLD", .full = "SIGCHLD" },
    .{ .num = SIGCONT, .short = "CONT", .full = "SIGCONT" },
    .{ .num = SIGTSTP, .short = "TSTP", .full = "SIGTSTP" },
    .{ .num = SIGTTIN, .short = "TTIN", .full = "SIGTTIN" },
    .{ .num = SIGTTOU, .short = "TTOU", .full = "SIGTTOU" },
    .{ .num = SIGPIPE, .short = "PIPE", .full = "SIGPIPE" },
    .{ .num = SIGUSR1, .short = "USR1", .full = "SIGUSR1" },
    .{ .num = SIGUSR2, .short = "USR2", .full = "SIGUSR2" },
    .{ .num = SIGURG, .short = "URG", .full = "SIGURG" },
};

fn lookupSignalName(signum: u6) ?SignalNameEntry {
    for (signal_name_entries) |entry| {
        if (entry.num == signum) return entry;
    }
    return null;
}

pub fn sigNameFromNum(signum: u6) ?[]const u8 {
    if (signum == 0) return "EXIT";
    if (lookupSignalName(signum)) |entry| return entry.short;
    return null;
}

pub fn sigFullName(signum: u6) ?[]const u8 {
    if (signum == 0) return "EXIT";
    if (lookupSignalName(signum)) |entry| return entry.full;
    return null;
}

pub const TRAP_EXIT: usize = 0;
pub const TRAP_ERR: usize = SIGNAL_LIMIT + 1;
const TRAP_COUNT: usize = TRAP_ERR + 1;

pub var trap_handlers: [TRAP_COUNT]?[]const u8 = [_]?[]const u8{null} ** TRAP_COUNT;
pub var received_signals: [SIGNAL_LIMIT]bool = [_]bool{false} ** SIGNAL_LIMIT;

fn signalHandler(sig: SIG) callconv(.c) void {
    const s: usize = @intFromEnum(sig);
    if (s < SIGNAL_LIMIT) {
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

pub fn clearTrapsForSubshell() void {
    for (1..SIGNAL_LIMIT) |i| {
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
    if (signum < SIGNAL_LIMIT_U6) {
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
    for (0..SIGNAL_LIMIT) |i| {
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

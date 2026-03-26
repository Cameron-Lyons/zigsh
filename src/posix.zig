const std = @import("std");
const c = std.c;

pub const fd_t = i32;
pub const pid_t = i32;
pub const mode_t = c.mode_t;
pub const WNOHANG: u32 = 1;

pub fn pipe() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = c.pipe(&fds);
    if (rc < 0) return error.PipeFailed;
    return fds;
}

pub fn dup(old: fd_t) !fd_t {
    const rc = c.dup(old);
    if (rc < 0) return error.BadFd;
    return rc;
}

pub fn dupHighFd(old: fd_t) !fd_t {
    const rc = c.fcntl(old, c.F.DUPFD, @as(c_int, 100));
    if (rc < 0) return error.BadFd;
    _ = c.fcntl(rc, c.F.SETFD, @as(c_int, FD_CLOEXEC));
    return rc;
}

pub fn dup2(old: fd_t, new: fd_t) !void {
    const rc = c.dup2(old, new);
    if (rc < 0) return error.DupFailed;
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn fork() !pid_t {
    const rc = c.fork();
    if (rc < 0) return error.ForkFailed;
    return rc;
}

pub const ExecError = error{ ExecFailed, NoExec };

pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) ExecError!void {
    _ = c.execve(path, argv, envp);
    const err = std.c._errno().*;
    if (err == 8) return error.NoExec;
    return error.ExecFailed;
}

pub const WaitResult = struct {
    pid: pid_t,
    status: u32,
};

pub fn waitpid(pid: pid_t, flags: u32) WaitResult {
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, @intCast(flags));
    return .{
        .pid = result,
        .status = @bitCast(status),
    };
}

pub const OpenFlags = std.c.O;

pub fn openZ(path: [*:0]const u8, flags: OpenFlags, mode: mode_t) !fd_t {
    const rc = c.open(path, flags, mode);
    if (rc < 0) return error.OpenFailed;
    return rc;
}

pub fn open(path: []const u8, flags: OpenFlags, mode: mode_t) !fd_t {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    return openZ(&path_z, flags, mode);
}

pub fn getcwd(buf: []u8) ![]const u8 {
    const result = c.getcwd(buf.ptr, buf.len);
    if (result == null) return error.GetCwdFailed;
    const ptr: [*:0]const u8 = @ptrCast(result.?);
    return std.mem.sliceTo(ptr, 0);
}

pub fn chdir(path: []const u8) !void {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    return chdirZ(&path_z);
}

pub fn chdirZ(path: [*:0]const u8) !void {
    const rc = c.chdir(path);
    if (rc < 0) return error.ChdirFailed;
}

pub const StatResult = struct {
    mode: u16,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: u32,
    dev_major: u32,
    dev_minor: u32,
    ino: u64,
    uid: u32,
    gid: u32,
};

fn statResultFromC(st: c.Stat) StatResult {
    const mt = st.mtime();
    return .{
        .mode = @intCast(st.mode),
        .size = @intCast(st.size),
        .mtime_sec = @intCast(mt.sec),
        .mtime_nsec = @intCast(mt.nsec),
        .dev_major = @intCast(@as(u64, @intCast(st.dev)) & 0xffff_ffff),
        .dev_minor = 0,
        .ino = @intCast(st.ino),
        .uid = @intCast(st.uid),
        .gid = @intCast(st.gid),
    };
}

pub fn stat(path: [*:0]const u8) !StatResult {
    var st: c.Stat = undefined;
    const rc = c.fstatat(@as(c.fd_t, @intCast(c.AT.FDCWD)), path, &st, 0);
    if (rc < 0) return error.StatFailed;
    return statResultFromC(st);
}

pub fn lstat(path: [*:0]const u8) !StatResult {
    var st: c.Stat = undefined;
    const rc = c.fstatat(
        @as(c.fd_t, @intCast(c.AT.FDCWD)),
        path,
        &st,
        @as(u32, c.AT.SYMLINK_NOFOLLOW),
    );
    if (rc < 0) return error.StatFailed;
    return statResultFromC(st);
}

pub fn access(path: [*:0]const u8, mode: c_uint) bool {
    return c.access(path, mode) == 0;
}

pub fn getpwnam(name: [*:0]const u8) ?[*:0]const u8 {
    const pw = ext.getpwnam(name);
    if (pw == null) return null;
    return pw.?.pw_dir;
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    const result = c.read(fd, buf.ptr, buf.len);
    if (result < 0) return error.ReadFailed;
    return @intCast(result);
}

pub fn write(fd: fd_t, data: []const u8) !usize {
    const result = c.write(fd, data.ptr, data.len);
    if (result < 0) return error.WriteFailed;
    return @intCast(result);
}

pub var stdout_write_error: bool = false;
pub const WriteHook = *const fn (fd: fd_t, data: []const u8) bool;
pub var write_hook: ?WriteHook = null;

pub fn writeAll(fd: fd_t, data: []const u8) void {
    if (write_hook) |hook| {
        if (hook(fd, data)) return;
    }
    var written: usize = 0;
    while (written < data.len) {
        const result = c.write(fd, data[written..].ptr, data[written..].len);
        if (result < 0) {
            if (fd == 1) stdout_write_error = true;
            return;
        }
        written += @intCast(result);
    }
}

pub fn getpid() pid_t {
    return c.getpid();
}

pub fn getppid() pid_t {
    return c.getppid();
}

pub fn geteuid() u32 {
    return c.geteuid();
}

pub fn getegid() u32 {
    return c.getegid();
}

pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) != 0;
}

pub fn fcntl_setfd(fd: fd_t, flags: c_int) !void {
    const rc = c.fcntl(fd, c.F.SETFD, flags);
    if (rc < 0) return error.FcntlFailed;
}

pub const FD_CLOEXEC = 1;

pub fn oRdonly() OpenFlags {
    return .{ .ACCMODE = .RDONLY };
}

pub fn oWronlyCreatTrunc() OpenFlags {
    return .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
}

pub fn oWronlyCreatAppend() OpenFlags {
    return .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
}

pub fn oRdwrCreat() OpenFlags {
    return .{ .ACCMODE = .RDWR, .CREAT = true };
}

pub fn oWronlyCreatExcl() OpenFlags {
    return .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true };
}

pub const S_IFMT: u16 = 0o170000;
pub const S_IFDIR: u16 = 0o040000;
pub const S_IFREG: u16 = 0o100000;
pub const S_IFBLK: u16 = 0o060000;
pub const S_IFCHR: u16 = 0o020000;
pub const S_IFIFO: u16 = 0o010000;
pub const S_IFLNK: u16 = 0o120000;
pub const S_IFSOCK: u16 = 0o140000;
pub const S_ISUID: u16 = 0o4000;
pub const S_ISGID: u16 = 0o2000;
pub const S_ISVTX: u16 = 0o1000;

pub const R_OK: c_uint = 4;
pub const W_OK: c_uint = 2;
pub const X_OK: c_uint = 1;

pub fn statusFromWait(status: u32) u8 {
    if (status & 0x7f == 0) {
        return @truncate((status >> 8) & 0xff);
    }
    return @truncate(128 + (status & 0x7f));
}

pub fn readToEnd(fd: fd_t, alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) !void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = read(fd, &buf) catch break;
        if (n == 0) break;
        try list.appendSlice(alloc, buf[0..n]);
    }
}

const Passwd = extern struct {
    pw_name: ?[*:0]const u8,
    pw_passwd: ?[*:0]const u8,
    pw_uid: c.uid_t,
    pw_gid: c.gid_t,
    pw_gecos: ?[*:0]const u8,
    pw_dir: ?[*:0]const u8,
    pw_shell: ?[*:0]const u8,
};

const ext = struct {
    extern "c" fn tcgetpgrp(fd: c_int) pid_t;
    extern "c" fn tcsetpgrp(fd: c_int, pgrp: pid_t) c_int;
    extern "c" fn setpgid(pid: pid_t, pgid: pid_t) c_int;
    extern "c" fn getpwnam(name: [*:0]const u8) ?*const Passwd;
    extern "c" fn getrusage(who: c_int, usage: *rusage) c_int;
    extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

    const timeval = extern struct {
        tv_sec: i64,
        tv_usec: i64,
    };

    const rusage = extern struct {
        ru_utime: timeval,
        ru_stime: timeval,
        ru_maxrss: isize,
        ru_ixrss: isize,
        ru_idrss: isize,
        ru_isrss: isize,
        ru_minflt: isize,
        ru_majflt: isize,
        ru_nswap: isize,
        ru_inblock: isize,
        ru_oublock: isize,
        ru_msgsnd: isize,
        ru_msgrcv: isize,
        ru_nsignals: isize,
        ru_nvcsw: isize,
        ru_nivcsw: isize,
    };
};

pub fn tcgetpgrp(fd: fd_t) !pid_t {
    const rc = ext.tcgetpgrp(fd);
    if (rc < 0) return error.TcgetpgrpFailed;
    return rc;
}

pub fn tcsetpgrp(fd: fd_t, pgrp: pid_t) !void {
    const rc = ext.tcsetpgrp(fd, pgrp);
    if (rc < 0) return error.TcsetpgrpFailed;
}

pub fn setpgid(pid: pid_t, pgid: pid_t) !void {
    const rc = ext.setpgid(pid, pgid);
    if (rc < 0) return error.SetpgidFailed;
}

pub fn killpg(pgrp: pid_t, sig: u6) !void {
    const rc = c.kill(-pgrp, @enumFromInt(sig));
    if (rc < 0) return error.KillFailed;
}

pub fn exit(status: u8) noreturn {
    std.process.exit(status);
}

pub const RUsage = struct {
    user_sec: i64,
    user_usec: i64,
    sys_sec: i64,
    sys_usec: i64,
};

pub fn getrusage(who: c_int) RUsage {
    var ru: ext.rusage = undefined;
    _ = ext.getrusage(who, &ru);
    return .{
        .user_sec = ru.ru_utime.tv_sec,
        .user_usec = ru.ru_utime.tv_usec,
        .sys_sec = ru.ru_stime.tv_sec,
        .sys_usec = ru.ru_stime.tv_usec,
    };
}

pub const RUSAGE_SELF: c_int = 0;
pub const RUSAGE_CHILDREN: c_int = -1;

pub fn realpath(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const result = ext.realpath(path, buf.ptr);
    if (result == null) return null;
    const ptr: [*:0]const u8 = @ptrCast(result.?);
    return std.mem.sliceTo(ptr, 0);
}

test "statusFromWait normal exit" {
    try std.testing.expectEqual(@as(u8, 0), statusFromWait(0x0000));
    try std.testing.expectEqual(@as(u8, 1), statusFromWait(0x0100));
    try std.testing.expectEqual(@as(u8, 2), statusFromWait(0x0200));
    try std.testing.expectEqual(@as(u8, 127), statusFromWait(0x7F00));
    try std.testing.expectEqual(@as(u8, 255), statusFromWait(0xFF00));
}

test "statusFromWait signal death" {
    try std.testing.expectEqual(@as(u8, 128 + 9), statusFromWait(9));
    try std.testing.expectEqual(@as(u8, 128 + 15), statusFromWait(15));
    try std.testing.expectEqual(@as(u8, 128 + 2), statusFromWait(2));
}

test "pipe and close" {
    const fds = try pipe();
    close(fds[0]);
    close(fds[1]);
}

test "dup" {
    const fds = try pipe();
    defer {
        close(fds[0]);
        close(fds[1]);
    }
    const new_fd = try dup(fds[0]);
    close(new_fd);
}

test "write and read" {
    const fds = try pipe();
    defer {
        close(fds[0]);
        close(fds[1]);
    }
    const msg = "hello";
    _ = try write(fds[1], msg);
    close(fds[1]);

    var buf: [64]u8 = undefined;
    const n = try read(fds[0], &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "getcwd" {
    var buf: [4096]u8 = undefined;
    const cwd = try getcwd(&buf);
    try std.testing.expect(cwd.len > 0);
    try std.testing.expect(cwd[0] == '/');
}

test "getpid" {
    const pid = getpid();
    try std.testing.expect(pid > 0);
}

test "isatty" {
    const fds = try pipe();
    defer {
        close(fds[0]);
        close(fds[1]);
    }
    try std.testing.expect(!isatty(fds[0]));
}

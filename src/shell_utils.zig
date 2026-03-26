const std = @import("std");
const Environment = @import("env.zig").Environment;
const posix = @import("posix.zig");

pub fn isValidVarName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] != '_' and !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |ch| {
        if (ch != '_' and !std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

fn isExecutableNonDir(path: []const u8) bool {
    const path_z = std.posix.toPosixPath(path) catch return false;
    if (!posix.access(&path_z, posix.X_OK)) return false;
    const st = posix.stat(&path_z) catch return false;
    return st.mode & posix.S_IFMT != posix.S_IFDIR;
}

pub fn findInPathNonDir(name: []const u8, env: *Environment, path_buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return if (isExecutableNonDir(name)) name else null;
    }

    if (env.getCachedCommand(name)) |cached| {
        if (isExecutableNonDir(cached)) return cached;
        env.removeCachedCommand(name);
    }

    const path_env = env.get("PATH") orelse "/usr/bin:/bin";
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        const full = std.fmt.bufPrint(path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (!isExecutableNonDir(full)) continue;
        env.cacheCommand(name, full) catch return full;
        return env.getCachedCommand(name) orelse full;
    }
    return null;
}

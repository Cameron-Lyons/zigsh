const std = @import("std");

pub const Topic = struct {
    name: []const u8,
    special: bool = false,
};

pub const topics = [_]Topic{
    .{ .name = ":" },
    .{ .name = "." },
    .{ .name = "alias" },
    .{ .name = "bg" },
    .{ .name = "break", .special = true },
    .{ .name = "cd" },
    .{ .name = "chdir" },
    .{ .name = "command" },
    .{ .name = "continue", .special = true },
    .{ .name = "declare" },
    .{ .name = "dirs" },
    .{ .name = "echo" },
    .{ .name = "eval", .special = true },
    .{ .name = "exec", .special = true },
    .{ .name = "exit", .special = true },
    .{ .name = "export", .special = true },
    .{ .name = "false" },
    .{ .name = "fc" },
    .{ .name = "fg" },
    .{ .name = "getopts" },
    .{ .name = "hash" },
    .{ .name = "help" },
    .{ .name = "history" },
    .{ .name = "jobs" },
    .{ .name = "kill" },
    .{ .name = "let" },
    .{ .name = "local" },
    .{ .name = "mapfile" },
    .{ .name = "popd" },
    .{ .name = "printf" },
    .{ .name = "pushd" },
    .{ .name = "pwd" },
    .{ .name = "read" },
    .{ .name = "readarray" },
    .{ .name = "readonly", .special = true },
    .{ .name = "return", .special = true },
    .{ .name = "set", .special = true },
    .{ .name = "shift", .special = true },
    .{ .name = "shopt" },
    .{ .name = "source" },
    .{ .name = "test" },
    .{ .name = "times", .special = true },
    .{ .name = "trap", .special = true },
    .{ .name = "true" },
    .{ .name = "type" },
    .{ .name = "typeset" },
    .{ .name = "ulimit" },
    .{ .name = "umask" },
    .{ .name = "unalias" },
    .{ .name = "unset", .special = true },
    .{ .name = "wait" },
    .{ .name = "[" },
};

pub fn isKnown(name: []const u8) bool {
    for (topics) |topic| {
        if (std.mem.eql(u8, topic.name, name)) return true;
    }
    return false;
}

pub fn isSpecial(name: []const u8) bool {
    for (topics) |topic| {
        if (std.mem.eql(u8, topic.name, name)) return topic.special;
    }
    return false;
}

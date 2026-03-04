const std = @import("std");

pub fn isShortCluster(arg: []const u8) bool {
    return arg.len >= 2 and arg[0] == '-' and !std.mem.eql(u8, arg, "--");
}

pub fn invalidShortFlag(cluster: []const u8, allowed: []const u8) ?u8 {
    if (!isShortCluster(cluster)) return null;
    for (cluster[1..]) |ch| {
        if (std.mem.indexOfScalar(u8, allowed, ch) == null) {
            return ch;
        }
    }
    return null;
}

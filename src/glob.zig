const std = @import("std");
const c = std.c;

pub fn expand(alloc: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    if (!hasGlobChars(pattern)) {
        const copy = try alloc.dupe(u8, pattern);
        const result = try alloc.alloc([]const u8, 1);
        result[0] = copy;
        return result;
    }

    var results: std.ArrayListUnmanaged([]const u8) = .empty;

    const last_slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const dir_path: []const u8 = if (last_slash) |idx| pattern[0 .. idx + 1] else "";
    const file_pattern: []const u8 = if (last_slash) |idx| pattern[idx + 1 ..] else pattern;

    const dir_to_open = if (dir_path.len == 0) "." else if (dir_path.len > 1 and dir_path[dir_path.len - 1] == '/') dir_path[0 .. dir_path.len - 1] else dir_path;

    const dir_z = std.posix.toPosixPath(dir_to_open) catch {
        const copy = try alloc.dupe(u8, pattern);
        const result = try alloc.alloc([]const u8, 1);
        result[0] = copy;
        return result;
    };

    const dir = c.opendir(&dir_z) orelse {
        const copy = try alloc.dupe(u8, pattern);
        const result = try alloc.alloc([]const u8, 1);
        result[0] = copy;
        return result;
    };
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);

        if (name[0] == '.' and (file_pattern.len == 0 or file_pattern[0] != '.')) continue;

        if (fnmatch(file_pattern, name)) {
            const full = if (dir_path.len > 0)
                try std.fmt.allocPrint(alloc, "{s}{s}", .{ dir_path, name })
            else
                try alloc.dupe(u8, name);
            try results.append(alloc, full);
        }
    }

    if (results.items.len == 0) {
        const copy = try alloc.dupe(u8, pattern);
        const result = try alloc.alloc([]const u8, 1);
        result[0] = copy;
        return result;
    }

    std.mem.sort([]const u8, results.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return results.toOwnedSlice(alloc);
}

pub fn fnmatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '[') {
            if (matchBracket(pattern, &pi, text[ti])) {
                ti += 1;
                continue;
            } else if (star_pi) |sp| {
                pi = sp + 1;
                star_ti += 1;
                ti = star_ti;
                continue;
            } else {
                return false;
            }
        }
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

fn matchBracket(pattern: []const u8, pi: *usize, ch: u8) bool {
    var i = pi.* + 1;
    if (i >= pattern.len) return false;

    var negate = false;
    if (pattern[i] == '!' or pattern[i] == '^') {
        negate = true;
        i += 1;
    }

    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            pi.* = i + 1;
            return if (negate) !matched else matched;
        }
        first = false;

        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (ch >= pattern[i] and ch <= pattern[i + 2]) {
                matched = true;
            }
            i += 3;
        } else {
            if (pattern[i] == ch) {
                matched = true;
            }
            i += 1;
        }
    }
    return false;
}

fn hasGlobChars(s: []const u8) bool {
    for (s) |ch| {
        switch (ch) {
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

test "fnmatch basic" {
    try std.testing.expect(fnmatch("*.txt", "hello.txt"));
    try std.testing.expect(!fnmatch("*.txt", "hello.csv"));
    try std.testing.expect(fnmatch("hello*", "hello world"));
    try std.testing.expect(fnmatch("h?llo", "hello"));
    try std.testing.expect(!fnmatch("h?llo", "hllo"));
    try std.testing.expect(fnmatch("*", "anything"));
    try std.testing.expect(fnmatch("[abc]", "a"));
    try std.testing.expect(!fnmatch("[abc]", "d"));
    try std.testing.expect(fnmatch("[a-z]", "m"));
    try std.testing.expect(!fnmatch("[a-z]", "M"));
    try std.testing.expect(fnmatch("[!abc]", "d"));
    try std.testing.expect(!fnmatch("[!abc]", "a"));
}

test "fnmatch empty" {
    try std.testing.expect(fnmatch("", ""));
    try std.testing.expect(!fnmatch("", "a"));
    try std.testing.expect(!fnmatch("a", ""));
}

test "fnmatch exact" {
    try std.testing.expect(fnmatch("abc", "abc"));
    try std.testing.expect(!fnmatch("abc", "abcd"));
    try std.testing.expect(!fnmatch("abcd", "abc"));
}

test "fnmatch multiple wildcards" {
    try std.testing.expect(fnmatch("*.*", "file.txt"));
    try std.testing.expect(fnmatch("*.*", "a.b"));
    try std.testing.expect(!fnmatch("*.*", "noext"));
    try std.testing.expect(fnmatch("*.*.bak", "file.txt.bak"));
    try std.testing.expect(fnmatch("a*b*c", "axbxc"));
    try std.testing.expect(fnmatch("a*b*c", "abc"));
    try std.testing.expect(!fnmatch("a*b*c", "ac"));
}

test "fnmatch question mark" {
    try std.testing.expect(fnmatch("???", "abc"));
    try std.testing.expect(!fnmatch("???", "ab"));
    try std.testing.expect(!fnmatch("???", "abcd"));
    try std.testing.expect(fnmatch("a?c", "abc"));
    try std.testing.expect(!fnmatch("a?c", "adc_extra"));
}

test "fnmatch bracket negate caret" {
    try std.testing.expect(fnmatch("[^abc]", "d"));
    try std.testing.expect(!fnmatch("[^abc]", "a"));
}

test "fnmatch star matches empty" {
    try std.testing.expect(fnmatch("*", ""));
    try std.testing.expect(fnmatch("a*", "a"));
    try std.testing.expect(fnmatch("*a", "a"));
}

test "hasGlobChars" {
    try std.testing.expect(hasGlobChars("*.txt"));
    try std.testing.expect(hasGlobChars("file?.c"));
    try std.testing.expect(hasGlobChars("[abc]"));
    try std.testing.expect(!hasGlobChars("plain.txt"));
    try std.testing.expect(!hasGlobChars(""));
}

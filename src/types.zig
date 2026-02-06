const std = @import("std");

pub const Fd = std.posix.fd_t;
pub const STDIN = 0;
pub const STDOUT = 1;
pub const STDERR = 2;

pub fn isNameStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

pub fn isNameCont(ch: u8) bool {
    return isNameStart(ch) or (ch >= '0' and ch <= '9');
}

test "isNameStart" {
    try std.testing.expect(isNameStart('a'));
    try std.testing.expect(isNameStart('z'));
    try std.testing.expect(isNameStart('A'));
    try std.testing.expect(isNameStart('Z'));
    try std.testing.expect(isNameStart('_'));
    try std.testing.expect(!isNameStart('0'));
    try std.testing.expect(!isNameStart('9'));
    try std.testing.expect(!isNameStart('-'));
    try std.testing.expect(!isNameStart(' '));
    try std.testing.expect(!isNameStart('.'));
}

test "isNameCont" {
    try std.testing.expect(isNameCont('a'));
    try std.testing.expect(isNameCont('Z'));
    try std.testing.expect(isNameCont('_'));
    try std.testing.expect(isNameCont('0'));
    try std.testing.expect(isNameCont('9'));
    try std.testing.expect(!isNameCont('-'));
    try std.testing.expect(!isNameCont(' '));
    try std.testing.expect(!isNameCont('.'));
}

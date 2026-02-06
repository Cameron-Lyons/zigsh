const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Tag = enum {
    word,
    assignment_word,
    io_number,
    newline,
    eof,

    // Operators
    and_if, // &&
    or_if, // ||
    dsemi, // ;;

    // Redirections
    dless, // <<
    dgreat, // >>
    lessand, // <&
    greatand, // >&
    lessgreat, // <>
    dlessdash, // <<-
    clobber, // >|

    // Single-char operators
    pipe, // |
    ampersand, // &
    semicolon, // ;
    less_than, // <
    greater_than, // >
    lparen, // (
    rparen, // )
    lbrace, // { (reserved word, but also operator-like)
    rbrace, // } (reserved word, but also operator-like)
    bang, // !

    // Reserved words
    kw_if,
    kw_then,
    kw_else,
    kw_elif,
    kw_fi,
    kw_do,
    kw_done,
    kw_case,
    kw_esac,
    kw_while,
    kw_until,
    kw_for,
    kw_in,

    pub fn isRedirectionOp(self: Tag) bool {
        return switch (self) {
            .less_than, .greater_than, .dless, .dgreat, .lessand, .greatand, .lessgreat, .dlessdash, .clobber => true,
            else => false,
        };
    }

};

pub const reserved_words = std.StaticStringMap(Tag).initComptime(.{
    .{ "if", .kw_if },
    .{ "then", .kw_then },
    .{ "else", .kw_else },
    .{ "elif", .kw_elif },
    .{ "fi", .kw_fi },
    .{ "do", .kw_do },
    .{ "done", .kw_done },
    .{ "case", .kw_case },
    .{ "esac", .kw_esac },
    .{ "while", .kw_while },
    .{ "until", .kw_until },
    .{ "for", .kw_for },
    .{ "{", .lbrace },
    .{ "}", .rbrace },
    .{ "!", .bang },
    .{ "in", .kw_in },
});

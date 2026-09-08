const std = @import("std");

/// Text normalization shared by candidate routing, lexical ranking and the
/// deterministic embedding reference. Version two retains ASCII behavior and
/// additionally emits each CJK ideograph as a stable token. This intentionally
/// avoids a hidden dependency on a language model or dictionary while making
/// Chinese/Japanese/Korean retrieval possible.
pub const version = "meml-tokenizer-unicode-cjk-v2";
pub const delimiters = " \t\n\r,.;:!?()[]{}\"'";

pub const Iterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.cursor < self.text.len) {
            const start = self.cursor;
            const width = std.unicode.utf8ByteSequenceLength(self.text[start]) catch {
                self.cursor += 1;
                continue;
            };
            if (start + width > self.text.len) {
                self.cursor += 1;
                continue;
            }
            const decoded = std.unicode.utf8Decode(self.text[start .. start + width]) catch {
                self.cursor += 1;
                continue;
            };
            if (isDelimiter(decoded)) {
                self.cursor += width;
                continue;
            }
            if (isCjk(decoded)) {
                self.cursor += width;
                return self.text[start..self.cursor];
            }
            self.cursor += width;
            while (self.cursor < self.text.len) {
                const current_start = self.cursor;
                const current_width = std.unicode.utf8ByteSequenceLength(self.text[current_start]) catch {
                    self.cursor += 1;
                    continue;
                };
                if (current_start + current_width > self.text.len) {
                    self.cursor += 1;
                    continue;
                }
                const current = std.unicode.utf8Decode(self.text[current_start .. current_start + current_width]) catch {
                    self.cursor += 1;
                    continue;
                };
                if (isDelimiter(current) or isCjk(current)) break;
                self.cursor += current_width;
            }
            return self.text[start..self.cursor];
        }
        return null;
    }
};

pub fn tokenize(text: []const u8) Iterator {
    return .{ .text = text };
}

fn isDelimiter(codepoint: u21) bool {
    if (codepoint < 128) return std.mem.indexOfScalar(u8, delimiters, @intCast(codepoint)) != null;
    return switch (codepoint) {
        0x3000, 0x3001, 0x3002, 0xff0c, 0xff01, 0xff1f, 0xff1a, 0xff1b, 0x3008...0x3011, 0xff08, 0xff09, 0x201c, 0x201d, 0x2018, 0x2019 => true,
        else => false,
    };
}

fn isCjk(codepoint: u21) bool {
    return switch (codepoint) {
        0x3400...0x4dbf, // CJK Extension A
        0x4e00...0x9fff, // CJK Unified Ideographs
        0xf900...0xfaff, // CJK compatibility ideographs
        0x3040...0x30ff, // Hiragana + Katakana
        0xac00...0xd7af,
        => true, // Hangul syllables
        else => false,
    };
}

pub fn equalsNormalized(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    return true;
}

pub fn lowerInto(destination: []u8, source: []const u8) []u8 {
    std.debug.assert(destination.len >= source.len);
    for (source, 0..) |byte, index| destination[index] = std.ascii.toLower(byte);
    return destination[0..source.len];
}

pub fn hash(token: []const u8) u64 {
    var value: u64 = 14695981039346656037;
    for (token) |byte| value = (value ^ std.ascii.toLower(byte)) *% 1099511628211;
    return value;
}

pub fn containsToken(text: []const u8, wanted: []const u8) bool {
    var tokens = tokenize(text);
    while (tokens.next()) |token| if (equalsNormalized(token, wanted)) return true;
    return false;
}

test "tokenizer normalizes punctuation and ASCII case" {
    var tokens = tokenize("Zig-0.17, Allocator!");
    try std.testing.expect(equalsNormalized(tokens.next().?, "zig-0"));
    try std.testing.expect(equalsNormalized(tokens.next().?, "17"));
    try std.testing.expect(equalsNormalized(tokens.next().?, "ALLOCATOR"));
    try std.testing.expect(tokens.next() == null);
}

test "tokenizer emits CJK codepoints as stable tokens" {
    var tokens = tokenize("中文检索，Rust");
    try std.testing.expectEqualStrings("中", tokens.next().?);
    try std.testing.expectEqualStrings("文", tokens.next().?);
    try std.testing.expectEqualStrings("检", tokens.next().?);
    try std.testing.expectEqualStrings("索", tokens.next().?);
    try std.testing.expectEqualStrings("Rust", tokens.next().?);
    try std.testing.expect(tokens.next() == null);
}

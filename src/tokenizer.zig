const std = @import("std");

/// Text normalization shared by candidate routing, lexical ranking and the
/// deterministic embedding reference. The first version deliberately keeps
/// ASCII-compatible behavior deterministic; language-specific segmentation is
/// an explicit future tokenizer version rather than an implicit ranking change.
pub const version = "meml-tokenizer-ascii-v1";
pub const delimiters = " \t\n\r,.;:!?()[]{}\"'";

pub fn tokenize(text: []const u8) @TypeOf(std.mem.tokenizeAny(u8, text, delimiters)) {
    return std.mem.tokenizeAny(u8, text, delimiters);
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

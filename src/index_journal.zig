const std = @import("std");
const store_mod = @import("store.zig");

const Header = "MEMLIDX1";

fn checkpointName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.index", .{path});
}

fn journalName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.index.journal", .{path});
}

fn parse(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !struct { revision: u64, ids: std.ArrayList(u64) } {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return error.BadIndexJournal;
    var fields = std.mem.splitScalar(u8, header, ' ');
    if (!std.mem.eql(u8, fields.next() orelse return error.BadIndexJournal, Header)) return error.BadIndexJournal;
    const revision = std.fmt.parseInt(u64, fields.next() orelse return error.BadIndexJournal, 10) catch return error.BadIndexJournal;
    if (fields.next() != null) return error.BadIndexJournal;
    var ids = std.ArrayList(u64).empty;
    errdefer ids.deinit(allocator);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try ids.append(allocator, std.fmt.parseInt(u64, line, 10) catch return error.BadIndexJournal);
    }
    return .{ .revision = revision, .ids = ids };
}

fn matches(store: *const store_mod.Store, revision: u64, expected_revision: u64, ids: []const u64) bool {
    if (revision != expected_revision or ids.len != store.nodes.items.len) return false;
    for (store.nodes.items, ids) |node, id| if (node.id != id) return false;
    return true;
}

/// Atomically records the semantic revision and ordered node IDs used by every
/// derived backend index. It never stores scores or vectors, so a checkpoint
/// cannot bypass kernel validation; recovery still rebuilds the derived index.
pub fn save(store: *const store_mod.Store, revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const journal = try journalName(allocator, path);
    defer allocator.free(journal);
    const checkpoint = try checkpointName(allocator, path);
    defer allocator.free(checkpoint);
    var file = try std.Io.Dir.cwd().createFile(io, journal, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("{s} {d}\n", .{ Header, revision });
    for (store.nodes.items) |node| try writer.interface.print("{d}\n", .{node.id});
    try writer.interface.flush();
    try file.sync(io);
    try std.Io.Dir.cwd().rename(journal, std.Io.Dir.cwd(), checkpoint, io);
}

/// Replays a valid index journal only when it matches the recovered semantic
/// revision exactly. Stale, malformed, or mismatched checkpoints are deleted.
pub fn recover(store: *const store_mod.Store, revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !bool {
    const journal = try journalName(allocator, path);
    defer allocator.free(journal);
    const checkpoint = try checkpointName(allocator, path);
    defer allocator.free(checkpoint);
    var candidate = recovery: {
        const parsed = parse(allocator, io, journal) catch |err| switch (err) {
            error.FileNotFound => break :recovery null,
            error.BadIndexJournal => {
                std.Io.Dir.cwd().deleteFile(io, journal) catch {};
                break :recovery null;
            },
            else => return err,
        };
        break :recovery parsed;
    };
    if (candidate) |*entry| {
        defer entry.ids.deinit(allocator);
        if (matches(store, entry.revision, revision, entry.ids.items)) {
            try std.Io.Dir.cwd().rename(journal, std.Io.Dir.cwd(), checkpoint, io);
        } else {
            try std.Io.Dir.cwd().deleteFile(io, journal);
        }
    }
    var saved = parse(allocator, io, checkpoint) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.BadIndexJournal => {
            std.Io.Dir.cwd().deleteFile(io, checkpoint) catch {};
            return false;
        },
        else => return err,
    };
    defer saved.ids.deinit(allocator);
    if (!matches(store, saved.revision, revision, saved.ids.items)) {
        try std.Io.Dir.cwd().deleteFile(io, checkpoint);
        return false;
    }
    return true;
}

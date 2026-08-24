const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");

pub const Loaded = struct { store: store_mod.Store, revision: u64, next_id: u64, clock: i64 };

fn journalName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.journal", .{path});
}

fn lockName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.lock", .{path});
}

fn acquireWriterLock(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !struct { file: std.Io.File, name: []u8 } {
    const name = try lockName(allocator, path);
    errdefer allocator.free(name);
    const file = std.Io.Dir.cwd().createFile(io, name, .{ .truncate = false, .exclusive = true, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.PathAlreadyExists => try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }),
        else => return err,
    };
    return .{ .file = file, .name = name };
}

fn encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (input) |byte| switch (byte) {
        '%', '|', '\n', '\r' => {
            try out.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 15]);
        },
        else => try out.append(allocator, byte),
    };
    return out.toOwnedSlice(allocator);
}

fn decode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '%') {
            try out.append(allocator, input[i]);
            continue;
        }
        if (i + 2 >= input.len) return error.BadFile;
        const hi = std.fmt.charToDigit(input[i + 1], 16) catch return error.BadFile;
        const lo = std.fmt.charToDigit(input[i + 2], 16) catch return error.BadFile;
        try out.append(allocator, @as(u8, @intCast(hi * 16 + lo)));
        i += 2;
    }
    return out.toOwnedSlice(allocator);
}

fn integer(comptime T: type, value: ?[]const u8) !T {
    return std.fmt.parseInt(T, value orelse return error.BadFile, 10) catch error.BadFile;
}

fn enumValue(comptime T: type, value: ?[]const u8) !T {
    return std.meta.stringToEnum(T, value orelse return error.BadFile) orelse error.BadFile;
}

fn finish(fields: anytype) !void {
    if (fields.next() != null) return error.BadFile;
}

fn scaled(value: ?[]const u8) !f64 {
    return @as(f64, @floatFromInt(try integer(i64, value))) / 1_000_000;
}

pub fn save(store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, path: []const u8) !void {
    try store.validate();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("MEML12 {d} {d} {d}\n", .{ revision, next_id, clock });
    for (store.nodes.items) |node| {
        const subject = try encode(store.allocator, node.subject);
        defer store.allocator.free(subject);
        const predicate = try encode(store.allocator, node.predicate);
        defer store.allocator.free(predicate);
        const object = try encode(store.allocator, node.object);
        defer store.allocator.free(object);
        const context = try encode(store.allocator, node.context);
        defer store.allocator.free(context);
        const result = try encode(store.allocator, node.result);
        defer store.allocator.free(result);
        try writer.interface.print("N|{d}|{s}|{s}|{s}|{s}|{s}|{s}|{d}|{d}|{d}|{s}|{d}|{d}|{d}|{d}\n", .{ node.id, @tagName(node.kind), subject, predicate, object, context, result, node.timestamp, @as(i64, @intFromFloat(node.confidence * 1_000_000)), @as(i64, @intFromFloat(node.strength * 1_000_000)), @tagName(node.belief_state), node.support_count, node.contradiction_count, node.last_confirmed_at, node.last_contradicted_at });
    }
    for (store.relations.items) |relation| try writer.interface.print("R|{d}|{d}|{s}|{d}\n", .{ relation.from, relation.to, @tagName(relation.kind), @as(i64, @intFromFloat(relation.weight * 1_000_000)) });
    for (store.consolidations.items) |record| {
        const rule = try encode(store.allocator, record.rule);
        defer store.allocator.free(rule);
        try writer.interface.print("C|{d}|{s}|{d}|{d}|{d}\n", .{ record.artifact, rule, record.version, record.source_a, record.source_b });
    }
    for (store.fingerprint_groups.items) |group| try writer.interface.print("G|{d}|{d}\n", .{ group.fingerprint, group.count });
    for (store.fingerprint_members.items) |member| try writer.interface.print("M|{d}|{d}\n", .{ member.fingerprint, member.experience });
    for (store.neural_states.items) |state| try writer.interface.print("L|{d}|{d}|{d}|{d}\n", .{ state.artifact, state.activation_count, @as(i64, @intFromFloat(state.strength * 1_000_000)), state.version });
    for (store.learned_signals.items) |state| {
        const provider = try encode(store.allocator, state.provider);
        defer store.allocator.free(provider);
        try writer.interface.print("P|{s}|{d}|{d}|{d}\n", .{ provider, @as(i64, @intFromFloat(state.weight * 1_000_000)), @as(i64, @intFromFloat(state.bias * 1_000_000)), state.version });
    }
    for (store.feedback_records.items) |record| {
        const actor = try encode(store.allocator, record.actor);
        defer store.allocator.free(actor);
        const receipt = try encode(store.allocator, record.receipt);
        defer store.allocator.free(receipt);
        try writer.interface.print("F|{d}|{d}|{s}|{s}|{s}|{s}\n", .{ record.evidence, record.target, @tagName(record.outcome), @tagName(record.failure_class), actor, receipt });
    }
    try writer.interface.flush();
}

fn saveAtomicLocked(store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const journal = try journalName(allocator, path);
    defer allocator.free(journal);
    try save(store, revision, next_id, clock, io, journal);
    {
        var journal_file = try std.Io.Dir.cwd().openFile(io, journal, .{ .mode = .read_write });
        try journal_file.sync(io);
        journal_file.close(io);
    }
    var check = try load(allocator, io, journal);
    defer check.store.deinit();
    if (check.revision != revision) return error.BadFile;
    try std.Io.Dir.cwd().rename(journal, std.Io.Dir.cwd(), path, io);
}

/// Write a validated complete state to a journal and atomically replace the target.
pub fn saveAtomic(store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var lock = try acquireWriterLock(io, allocator, path);
    defer {
        lock.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, lock.name) catch {};
        allocator.free(lock.name);
    }
    try saveAtomicLocked(store, revision, next_id, clock, io, allocator, path);
}

/// Optimistic local CAS: an update commits only if the persisted revision
/// equals `expected_revision`; otherwise it leaves the target unchanged.
pub fn saveAtomicIfRevision(store: *const store_mod.Store, expected_revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
    var lock = try acquireWriterLock(io, allocator, path);
    defer {
        lock.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, lock.name) catch {};
        allocator.free(lock.name);
    }
    var current = load(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (current) |*state| {
        defer state.store.deinit();
        if (state.revision != expected_revision) return error.RevisionConflict;
    } else if (expected_revision != 0) return error.RevisionConflict;
    const next_revision = std.math.add(u64, expected_revision, 1) catch return error.RevisionOverflow;
    try saveAtomicLocked(store, next_revision, next_id, clock, io, allocator, path);
    return next_revision;
}

pub fn recoverJournal(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var lock = try acquireWriterLock(io, allocator, path);
    defer {
        lock.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, lock.name) catch {};
        allocator.free(lock.name);
    }
    const journal = try journalName(allocator, path);
    defer allocator.free(journal);
    var file = std.Io.Dir.cwd().openFile(io, journal, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    file.close(io);
    var journal_state = load(allocator, io, journal) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, journal) catch {};
        return err;
    };
    defer journal_state.store.deinit();
    var target_state = load(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (target_state) |*target| {
        defer target.store.deinit();
        if (target.revision >= journal_state.revision) {
            try std.Io.Dir.cwd().deleteFile(io, journal);
            return;
        }
    }
    try std.Io.Dir.cwd().rename(journal, std.Io.Dir.cwd(), path, io);
}

/// Loads the single current on-disk format. Every record is strict and the
/// whole graph is validated before the resulting state is returned.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    var loaded = Loaded{ .store = store_mod.Store.init(allocator), .revision = 0, .next_id = 1, .clock = 0 };
    errdefer loaded.store.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return error.BadFile;
    var header_fields = std.mem.splitScalar(u8, header, ' ');
    if (!std.mem.eql(u8, header_fields.next() orelse return error.BadFile, "MEML12")) return error.UnsupportedVersion;
    loaded.revision = try integer(u64, header_fields.next());
    loaded.next_id = try integer(u64, header_fields.next());
    loaded.clock = try integer(i64, header_fields.next());
    try finish(&header_fields);
    if (loaded.next_id == 0) return error.BadFile;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '|');
        const tag = fields.next() orelse return error.BadFile;
        if (std.mem.eql(u8, tag, "N")) {
            const id = try integer(u64, fields.next());
            const kind = try enumValue(model.Kind, fields.next());
            const subject = try decode(allocator, fields.next() orelse return error.BadFile);
            errdefer allocator.free(subject);
            const predicate = try decode(allocator, fields.next() orelse return error.BadFile);
            errdefer allocator.free(predicate);
            const object = try decode(allocator, fields.next() orelse return error.BadFile);
            errdefer allocator.free(object);
            const context = try decode(allocator, fields.next() orelse return error.BadFile);
            errdefer allocator.free(context);
            const result = try decode(allocator, fields.next() orelse return error.BadFile);
            errdefer allocator.free(result);
            const node = model.Node{
                .id = id,
                .kind = kind,
                .subject = subject,
                .predicate = predicate,
                .object = object,
                .context = context,
                .result = result,
                .timestamp = try integer(i64, fields.next()),
                .confidence = try scaled(fields.next()),
                .strength = try scaled(fields.next()),
                .belief_state = try enumValue(model.BeliefState, fields.next()),
                .support_count = try integer(u32, fields.next()),
                .contradiction_count = try integer(u32, fields.next()),
                .last_confirmed_at = try integer(i64, fields.next()),
                .last_contradicted_at = try integer(i64, fields.next()),
            };
            try finish(&fields);
            _ = try loaded.store.add(node);
        } else if (std.mem.eql(u8, tag, "R")) {
            try loaded.store.link(.{ .from = try integer(u64, fields.next()), .to = try integer(u64, fields.next()), .kind = try enumValue(model.RelationKind, fields.next()), .weight = try scaled(fields.next()) });
            try finish(&fields);
        } else if (std.mem.eql(u8, tag, "C")) {
            const artifact = try integer(u64, fields.next());
            const rule = try decode(allocator, fields.next() orelse return error.BadFile);
            errdefer allocator.free(rule);
            const record = model.ConsolidationRecord{ .artifact = artifact, .rule = rule, .version = try integer(u32, fields.next()), .source_a = try integer(u64, fields.next()), .source_b = try integer(u64, fields.next()) };
            try finish(&fields);
            try loaded.store.recordConsolidation(record);
        } else if (std.mem.eql(u8, tag, "G")) {
            try loaded.store.fingerprint_groups.append(allocator, .{ .fingerprint = try integer(u64, fields.next()), .count = try integer(usize, fields.next()) });
            try finish(&fields);
        } else if (std.mem.eql(u8, tag, "M")) {
            try loaded.store.fingerprint_members.append(allocator, .{ .fingerprint = try integer(u64, fields.next()), .experience = try integer(u64, fields.next()) });
            try finish(&fields);
        } else if (std.mem.eql(u8, tag, "L")) {
            try loaded.store.neural_states.append(allocator, .{ .artifact = try integer(u64, fields.next()), .activation_count = try integer(u64, fields.next()), .strength = try scaled(fields.next()), .version = try integer(u32, fields.next()) });
            try finish(&fields);
        } else if (std.mem.eql(u8, tag, "P")) {
            const provider = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(provider);
            const weight = try scaled(fields.next());
            const bias = try scaled(fields.next());
            const version = try integer(u32, fields.next());
            try finish(&fields);
            try loaded.store.upsertLearnedSignal(provider, weight, bias, version);
        } else if (std.mem.eql(u8, tag, "F")) {
            const evidence = try integer(u64, fields.next());
            const target = try integer(u64, fields.next());
            const outcome = try enumValue(model.Outcome, fields.next());
            const failure_class = try enumValue(model.FailureClass, fields.next());
            const actor = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(actor);
            const receipt = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(receipt);
            try finish(&fields);
            try loaded.store.recordFeedback(.{ .evidence = evidence, .target = target, .outcome = outcome, .failure_class = failure_class, .actor = actor, .receipt = receipt });
        } else return error.BadFile;
    }
    try loaded.store.validate();
    var maximum_id: u64 = 0;
    for (loaded.store.nodes.items) |node| maximum_id = @max(maximum_id, node.id);
    if (loaded.next_id <= maximum_id) return error.BadFile;
    return loaded;
}

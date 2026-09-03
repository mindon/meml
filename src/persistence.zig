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

fn ensureParentDirectory(io: std.Io, path: []const u8) !void {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (separator == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, path[0..separator]);
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

fn optionalScaled(value: ?[]const u8) !?f64 {
    const raw = value orelse return error.BadFile;
    if (std.mem.eql(u8, raw, "-")) return null;
    return try scaled(raw);
}

pub fn save(store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, path: []const u8) !void {
    try store.validate();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("MEML15 {d} {d} {d}\n", .{ revision, next_id, clock });
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
        try writer.interface.print("N|{d}|{s}|{s}|{s}|{s}|{s}|{s}|{d}|{d}|{d}|{s}|{d}|{d}|{d}|{d}\n", .{ node.id, @tagName(node.kind), subject, predicate, object, context, result, node.timestamp, @as(i64, @intFromFloat(node.confidence * 1_000_000)), @as(i64, @intFromFloat(node.strength * 1_000_000)), @tagName(node.cognitive_state), node.support_count, node.contradiction_count, node.last_confirmed_at, node.last_contradicted_at });
    }
    for (store.scoped_records.items) |record| {
        const key = try encode(store.allocator, record.scope.key);
        defer store.allocator.free(key);
        const value = try encode(store.allocator, record.scope.value);
        defer store.allocator.free(value);
        try writer.interface.print("S|{d}|{s}|{s}\n", .{ record.node, key, value });
    }
    for (store.metric_records.items) |record| {
        const name = try encode(store.allocator, record.metric.name);
        defer store.allocator.free(name);
        const unit = try encode(store.allocator, record.metric.unit);
        defer store.allocator.free(unit);
        if (record.metric.uncertainty) |uncertainty| {
            try writer.interface.print("T|{d}|{s}|{d}|{s}|{d}|{s}\n", .{ record.node, name, @as(i64, @intFromFloat(record.metric.value * 1_000_000)), unit, @as(i64, @intFromFloat(uncertainty * 1_000_000)), @tagName(record.metric.direction) });
        } else {
            try writer.interface.print("T|{d}|{s}|{d}|{s}|-|{s}\n", .{ record.node, name, @as(i64, @intFromFloat(record.metric.value * 1_000_000)), unit, @tagName(record.metric.direction) });
        }
    }
    for (store.artifact_records.items) |record| {
        const kind = try encode(store.allocator, record.artifact.kind);
        defer store.allocator.free(kind);
        const digest = try encode(store.allocator, record.artifact.digest);
        defer store.allocator.free(digest);
        const locator = try encode(store.allocator, record.artifact.locator);
        defer store.allocator.free(locator);
        try writer.interface.print("A|{d}|{s}|{s}|{s}\n", .{ record.node, kind, digest, locator });
    }
    for (store.structure_records.items) |record| {
        const kind = try encode(store.allocator, record.structure.kind);
        defer store.allocator.free(kind);
        const fingerprint = try encode(store.allocator, record.structure.fingerprint);
        defer store.allocator.free(fingerprint);
        try writer.interface.print("H|{d}|{s}|{s}\n", .{ record.node, kind, fingerprint });
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
    for (store.attestation_replays.items) |record| try writer.interface.print("V|{x}|{d}\n", .{ record.digest, record.expires_at });
    for (store.transition_records.items) |record| {
        const reason = try encode(store.allocator, record.reason);
        defer store.allocator.free(reason);
        const actor = try encode(store.allocator, record.actor);
        defer store.allocator.free(actor);
        const receipt = try encode(store.allocator, record.receipt);
        defer store.allocator.free(receipt);
        try writer.interface.print("X|{d}|{d}|{d}|{s}|{s}|{s}|{d}|{d}|{d}|{d}|{d}|{s}|{s}|{s}\n", .{ record.id, record.target, record.cause orelse 0, @tagName(record.kind), @tagName(record.prior_state), @tagName(record.next_state), @as(i64, @intFromFloat(record.prior_confidence * 1_000_000)), @as(i64, @intFromFloat(record.next_confidence * 1_000_000)), @as(i64, @intFromFloat(record.prior_strength * 1_000_000)), @as(i64, @intFromFloat(record.next_strength * 1_000_000)), record.timestamp, reason, actor, receipt });
    }
    for (store.information_records.items) |record| {
        const source = try encode(store.allocator, record.source);
        defer store.allocator.free(source);
        try writer.interface.print("I|{d}|{s}|{s}|{s}|{s}|{d}|{d}|{d}\n", .{ record.node, @tagName(record.kind), @tagName(record.trust), @tagName(record.retention), source, record.observed_at, record.valid_from, record.valid_until orelse -1 });
    }
    for (store.evolution_events.items) |event| {
        const source = try encode(store.allocator, event.source);
        defer store.allocator.free(source);
        const reason = try encode(store.allocator, event.reason);
        defer store.allocator.free(reason);
        try writer.interface.print("E|{d}|{s}|{d}|{d}|{d}|{s}|{s}\n", .{ event.id, @tagName(event.kind), event.target, event.related orelse 0, event.timestamp, source, reason });
    }
    for (store.decision_dependencies.items) |dependency| try writer.interface.print("D|{d}|{d}|{d}\n", .{ dependency.decision, dependency.information, dependency.timestamp });
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
    try ensureParentDirectory(io, path);
    var lock = try acquireWriterLock(io, allocator, path);
    defer {
        lock.file.close(io);
        allocator.free(lock.name);
    }
    try saveAtomicLocked(store, revision, next_id, clock, io, allocator, path);
}

/// Optimistic local CAS: an update commits only if the persisted revision
/// equals `expected_revision`; otherwise it leaves the target unchanged.
pub fn saveAtomicIfRevision(store: *const store_mod.Store, expected_revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
    try ensureParentDirectory(io, path);
    var lock = try acquireWriterLock(io, allocator, path);
    defer {
        lock.file.close(io);
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
    if (!std.mem.eql(u8, header_fields.next() orelse return error.BadFile, "MEML15")) return error.UnsupportedVersion;
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
                .cognitive_state = try enumValue(model.CognitiveState, fields.next()),
                .support_count = try integer(u32, fields.next()),
                .contradiction_count = try integer(u32, fields.next()),
                .last_confirmed_at = try integer(i64, fields.next()),
                .last_contradicted_at = try integer(i64, fields.next()),
            };
            try finish(&fields);
            _ = try loaded.store.add(node);
        } else if (std.mem.eql(u8, tag, "S")) {
            const node = try integer(u64, fields.next());
            const key = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(key);
            const value = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(value);
            try finish(&fields);
            try loaded.store.addScope(node, .{ .key = key, .value = value });
        } else if (std.mem.eql(u8, tag, "T")) {
            const node = try integer(u64, fields.next());
            const name = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(name);
            const value = try scaled(fields.next());
            const unit = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(unit);
            const uncertainty = try optionalScaled(fields.next());
            const direction = try enumValue(model.MetricDirection, fields.next());
            try finish(&fields);
            try loaded.store.addMetric(node, .{ .name = name, .value = value, .unit = unit, .uncertainty = uncertainty, .direction = direction });
        } else if (std.mem.eql(u8, tag, "A")) {
            const node = try integer(u64, fields.next());
            const kind = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(kind);
            const digest = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(digest);
            const locator = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(locator);
            try finish(&fields);
            try loaded.store.addArtifact(node, .{ .kind = kind, .digest = digest, .locator = locator });
        } else if (std.mem.eql(u8, tag, "H")) {
            const node = try integer(u64, fields.next());
            const kind = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(kind);
            const fingerprint = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(fingerprint);
            try finish(&fields);
            try loaded.store.setStructure(node, .{ .kind = kind, .fingerprint = fingerprint });
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
        } else if (std.mem.eql(u8, tag, "V")) {
            const encoded_digest = fields.next() orelse return error.BadFile;
            if (encoded_digest.len != 64) return error.BadFile;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, encoded_digest) catch return error.BadFile;
            const expires_at = try integer(i64, fields.next());
            try finish(&fields);
            try loaded.store.recordAttestationReplay(.{ .digest = digest, .expires_at = expires_at });
        } else if (std.mem.eql(u8, tag, "X")) {
            const id = try integer(u64, fields.next());
            const target = try integer(u64, fields.next());
            const raw_cause = try integer(u64, fields.next());
            const kind = try enumValue(model.TransitionKind, fields.next());
            const prior_state = try enumValue(model.CognitiveState, fields.next());
            const next_state = try enumValue(model.CognitiveState, fields.next());
            const prior_confidence = try scaled(fields.next());
            const next_confidence = try scaled(fields.next());
            const prior_strength = try scaled(fields.next());
            const next_strength = try scaled(fields.next());
            const timestamp = try integer(i64, fields.next());
            const reason = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(reason);
            const actor = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(actor);
            const receipt = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(receipt);
            try finish(&fields);
            try loaded.store.recordTransition(.{ .id = id, .target = target, .cause = if (raw_cause == 0) null else raw_cause, .kind = kind, .prior_state = prior_state, .next_state = next_state, .prior_confidence = prior_confidence, .next_confidence = next_confidence, .prior_strength = prior_strength, .next_strength = next_strength, .timestamp = timestamp, .reason = reason, .actor = actor, .receipt = receipt });
        } else if (std.mem.eql(u8, tag, "I")) {
            const node = try integer(u64, fields.next());
            const kind = try enumValue(model.InformationKind, fields.next());
            const trust = try enumValue(model.Trust, fields.next());
            const retention = try enumValue(model.Retention, fields.next());
            const source = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(source);
            const observed_at = try integer(i64, fields.next());
            const valid_from = try integer(i64, fields.next());
            const raw_valid_until = try integer(i64, fields.next());
            try finish(&fields);
            try loaded.store.recordInformation(.{ .node = node, .kind = kind, .trust = trust, .retention = retention, .source = source, .observed_at = observed_at, .valid_from = valid_from, .valid_until = if (raw_valid_until < 0) null else raw_valid_until });
        } else if (std.mem.eql(u8, tag, "E")) {
            const id = try integer(u64, fields.next());
            const kind = try enumValue(model.EvolutionKind, fields.next());
            const target = try integer(u64, fields.next());
            const raw_related = try integer(u64, fields.next());
            const timestamp = try integer(i64, fields.next());
            const source = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(source);
            const reason = try decode(allocator, fields.next() orelse return error.BadFile);
            defer allocator.free(reason);
            try finish(&fields);
            try loaded.store.recordEvolutionEvent(.{ .id = id, .kind = kind, .target = target, .related = if (raw_related == 0) null else raw_related, .timestamp = timestamp, .source = source, .reason = reason });
        } else if (std.mem.eql(u8, tag, "D")) {
            const decision = try integer(u64, fields.next());
            const information = try integer(u64, fields.next());
            const timestamp = try integer(i64, fields.next());
            try finish(&fields);
            try loaded.store.recordDecisionDependency(.{ .decision = decision, .information = information, .timestamp = timestamp });
        } else return error.BadFile;
    }
    try loaded.store.validate();
    var maximum_id: u64 = 0;
    for (loaded.store.nodes.items) |node| maximum_id = @max(maximum_id, node.id);
    if (loaded.next_id <= maximum_id) return error.BadFile;
    return loaded;
}

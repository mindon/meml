const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const tokenizer = @import("tokenizer.zig");

/// Provider contract: providers own candidate generation only; the kernel owns
/// node identity, scoring, ordering, limits, and explanations.
pub const Contract = struct {
    pub const version = "MEML-ABI-1";
    pub const operations = [_][]const u8{ "name", "reset", "upsert", "remove", "candidates" };
};

pub const Provider = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    resetFn: *const fn (*anyopaque, *const store_mod.Store) anyerror!void,
    upsertFn: *const fn (*anyopaque, *const store_mod.Store, u64) anyerror!void,
    removeFn: *const fn (*anyopaque, u64) void,
    candidatesFn: *const fn (*anyopaque, *const store_mod.Store, model.Context, std.mem.Allocator) anyerror!std.ArrayList(u64),

    pub fn name(self: Provider) []const u8 {
        return self.nameFn(self.context);
    }
    pub fn reset(self: Provider, store: *const store_mod.Store) !void {
        return self.resetFn(self.context, store);
    }
    pub fn upsert(self: Provider, store: *const store_mod.Store, id: u64) !void {
        return self.upsertFn(self.context, store, id);
    }
    pub fn remove(self: Provider, id: u64) void {
        self.removeFn(self.context, id);
    }
    pub fn candidates(self: Provider, store: *const store_mod.Store, context: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
        return self.candidatesFn(self.context, store, context, allocator);
    }
};
pub const Backend = Provider;

/// A host-owned local semantic candidate source, typically backed by an ANN
/// index built from precomputed embeddings. All callbacks must be local and
/// must not perform network or model I/O during `candidates`.
pub const LocalSemantic = struct {
    context: *anyopaque,
    model_version: []const u8,
    model_sha256: []const u8,
    resetFn: *const fn (*anyopaque, *const store_mod.Store) anyerror!void,
    upsertFn: *const fn (*anyopaque, *const store_mod.Store, u64) anyerror!void,
    removeFn: *const fn (*anyopaque, u64) void,
    candidatesFn: *const fn (*anyopaque, *const store_mod.Store, model.Context, std.mem.Allocator) anyerror!std.ArrayList(u64),

    pub fn provider(self: *LocalSemantic) Provider {
        return .{ .context = self, .nameFn = LocalSemantic.name, .resetFn = LocalSemantic.reset, .upsertFn = LocalSemantic.upsert, .removeFn = LocalSemantic.remove, .candidatesFn = LocalSemantic.candidates };
    }
    fn name(context: *anyopaque) []const u8 {
        const self: *const LocalSemantic = @ptrCast(@alignCast(context));
        return self.model_version;
    }
    fn reset(context: *anyopaque, store: *const store_mod.Store) !void {
        const self: *LocalSemantic = @ptrCast(@alignCast(context));
        try self.resetFn(self.context, store);
    }
    fn upsert(context: *anyopaque, store: *const store_mod.Store, id: u64) !void {
        const self: *LocalSemantic = @ptrCast(@alignCast(context));
        try self.upsertFn(self.context, store, id);
    }
    fn remove(context: *anyopaque, id: u64) void {
        const self: *LocalSemantic = @ptrCast(@alignCast(context));
        self.removeFn(self.context, id);
    }
    fn candidates(context: *anyopaque, store: *const store_mod.Store, request: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
        const self: *LocalSemantic = @ptrCast(@alignCast(context));
        return self.candidatesFn(self.context, store, request, allocator);
    }
};

/// Composes two candidate sources by set union. It never ranks records: every
/// returned ID still flows through the kernel's lifecycle and scoring policy.
pub const Hybrid = struct {
    left: Provider,
    right: Provider,

    pub fn provider(self: *Hybrid) Provider {
        return .{ .context = self, .nameFn = Hybrid.name, .resetFn = Hybrid.reset, .upsertFn = Hybrid.upsert, .removeFn = Hybrid.remove, .candidatesFn = Hybrid.candidates };
    }
    fn name(_: *anyopaque) []const u8 {
        return "hybrid";
    }
    fn reset(context: *anyopaque, store: *const store_mod.Store) !void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        try self.left.reset(store);
        try self.right.reset(store);
    }
    fn upsert(context: *anyopaque, store: *const store_mod.Store, id: u64) !void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        try self.left.upsert(store, id);
        try self.right.upsert(store, id);
    }
    fn remove(context: *anyopaque, id: u64) void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        self.left.remove(id);
        self.right.remove(id);
    }
    fn candidates(context: *anyopaque, store: *const store_mod.Store, request: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        var left = try self.left.candidates(store, request, allocator);
        defer left.deinit(allocator);
        var right = try self.right.candidates(store, request, allocator);
        defer right.deinit(allocator);
        var combined = std.ArrayList(u64).empty;
        errdefer combined.deinit(allocator);
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();
        for (left.items) |id| if (!(try seen.getOrPut(id)).found_existing) try combined.append(allocator, id);
        for (right.items) |id| if (!(try seen.getOrPut(id)).found_existing) try combined.append(allocator, id);
        return combined;
    }
};

fn exhaustiveReset(_: *anyopaque, _: *const store_mod.Store) !void {}
fn exhaustiveUpsert(_: *anyopaque, _: *const store_mod.Store, _: u64) !void {}
fn exhaustiveRemove(_: *anyopaque, _: u64) void {}

const Indexes = struct {
    allocator: std.mem.Allocator,
    tokens: std.StringHashMap(std.ArrayList(u64)),
    vectors: std.AutoHashMap(u64, [32]f32),
    fn init(allocator: std.mem.Allocator) Indexes {
        return .{ .allocator = allocator, .tokens = std.StringHashMap(std.ArrayList(u64)).init(allocator), .vectors = std.AutoHashMap(u64, [32]f32).init(allocator) };
    }
    fn deinit(self: *Indexes) void {
        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.tokens.deinit();
        self.vectors.deinit();
    }
    fn addToken(self: *Indexes, token: []const u8, id: u64) !void {
        if (token.len == 0) return;
        const owned = try self.allocator.alloc(u8, token.len);
        errdefer self.allocator.free(owned);
        _ = tokenizer.lowerInto(owned, token);
        const entry = try self.tokens.getOrPut(owned);
        if (!entry.found_existing) entry.value_ptr.* = .empty else self.allocator.free(owned);
        for (entry.value_ptr.items) |old| if (old == id) return;
        try entry.value_ptr.append(self.allocator, id);
    }
    fn addText(self: *Indexes, text: []const u8, id: u64) !void {
        var tokens = tokenizer.tokenize(text);
        while (tokens.next()) |token| try self.addToken(token, id);
    }
    fn indexNode(self: *Indexes, store: *const store_mod.Store, node: model.Node) !void {
        try self.addText(node.subject, node.id);
        try self.addText(node.predicate, node.id);
        try self.addText(node.object, node.id);
        try self.addText(node.context, node.id);
        try self.addText(node.result, node.id);
        for (store.scoped_records.items) |record| if (record.node == node.id) {
            try self.addToken(record.scope.key, node.id);
            try self.addToken(record.scope.value, node.id);
        };
        for (store.metric_records.items) |record| if (record.node == node.id) try self.addToken(record.metric.name, node.id);
        for (store.artifact_records.items) |record| if (record.node == node.id) {
            try self.addToken(record.artifact.kind, node.id);
            try self.addToken(record.artifact.digest, node.id);
        };
        for (store.structure_records.items) |record| if (record.node == node.id) {
            try self.addToken(record.structure.kind, node.id);
            try self.addToken(record.structure.fingerprint, node.id);
        };
        self.vectors.put(node.id, vector(node, "")) catch return error.OutOfMemory;
    }
    fn reset(self: *Indexes, store: *const store_mod.Store) !void {
        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.tokens.clearRetainingCapacity();
        self.vectors.clearRetainingCapacity();
        for (store.nodes.items) |node| try self.indexNode(store, node);
    }
};
fn addTextToVector(out: *[32]f32, text: []const u8) void {
    var tokens = tokenizer.tokenize(text);
    while (tokens.next()) |token| out[tokenizer.hash(token) % out.len] += 1;
}
fn vector(node: model.Node, query: []const u8) [32]f32 {
    var out = std.mem.zeroes([32]f32);
    addTextToVector(&out, node.subject);
    addTextToVector(&out, node.predicate);
    addTextToVector(&out, node.object);
    addTextToVector(&out, node.context);
    addTextToVector(&out, node.result);
    addTextToVector(&out, query);
    return out;
}
fn contains(haystack: []const u8, needle: []const u8) bool {
    return needle.len > 0 and std.mem.indexOf(u8, haystack, needle) != null;
}
fn all(_: *anyopaque, store: *const store_mod.Store, _: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
    var ids = std.ArrayList(u64).empty;
    for (store.nodes.items) |node| try ids.append(allocator, node.id);
    return ids;
}
fn appendTokenMatches(indexes: *const Indexes, raw_token: []const u8, seen: *std.AutoHashMap(u64, void), ids: *std.ArrayList(u64), allocator: std.mem.Allocator) !void {
    const token = try allocator.alloc(u8, raw_token.len);
    defer allocator.free(token);
    _ = tokenizer.lowerInto(token, raw_token);
    if (indexes.tokens.get(token)) |matches| for (matches.items) |id| if (!seen.contains(id)) {
        try seen.put(id, {});
        try ids.append(allocator, id);
    };
}

/// Candidate recall is token-based and case-normalized across every contextual
/// field. This routing step must not change because a query is multi-word or
/// differently cased than the indexed record.
fn indexedCandidates(ctx: *anyopaque, store: *const store_mod.Store, context: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
    const indexes: *Indexes = @ptrCast(@alignCast(ctx));
    var ids = std.ArrayList(u64).empty;
    errdefer ids.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var has_token = false;
    const terms = [_][]const u8{ context.query, context.goal, context.situation, context.preferred };
    for (terms) |term| {
        var tokens = tokenizer.tokenize(term);
        while (tokens.next()) |token| {
            has_token = true;
            try appendTokenMatches(indexes, token, &seen, &ids, allocator);
        }
    }
    for (context.scopes) |scope| {
        var keys = tokenizer.tokenize(scope.key);
        while (keys.next()) |token| {
            has_token = true;
            try appendTokenMatches(indexes, token, &seen, &ids, allocator);
        }
        var values = tokenizer.tokenize(scope.value);
        while (values.next()) |token| {
            has_token = true;
            try appendTokenMatches(indexes, token, &seen, &ids, allocator);
        }
    }
    if (context.structure) |structure| {
        var kinds = tokenizer.tokenize(structure.kind);
        while (kinds.next()) |token| {
            has_token = true;
            try appendTokenMatches(indexes, token, &seen, &ids, allocator);
        }
        var fingerprints = tokenizer.tokenize(structure.fingerprint);
        while (fingerprints.next()) |token| {
            has_token = true;
            try appendTokenMatches(indexes, token, &seen, &ids, allocator);
        }
    }
    if (!has_token) return all(ctx, store, context, allocator);
    return ids;
}
/// Graph routing deliberately returns only indexed seeds. The kernel-owned
/// retrieval pipeline performs bounded, lifecycle-aware relation propagation so
/// providers cannot bypass activation budgets or final-state semantics.
fn graph(ctx: *anyopaque, store: *const store_mod.Store, context: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
    return indexedCandidates(ctx, store, context, allocator);
}

fn vectorCandidates(ctx: *anyopaque, store: *const store_mod.Store, context: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
    const indexes: *Indexes = @ptrCast(@alignCast(ctx));
    var ids = std.ArrayList(u64).empty;
    const query_node: model.Node = .{ .id = 0, .kind = .context, .subject = "", .predicate = "", .object = context.query, .context = context.situation, .result = context.goal, .timestamp = 0, .confidence = 1, .strength = 1 };
    const q = vector(query_node, context.query);
    for (store.nodes.items) |node| {
        const v = indexes.vectors.get(node.id) orelse continue;
        var dot: f32 = 0;
        var qn: f32 = 0;
        var vn: f32 = 0;
        for (q, v) |a, b| {
            dot += a * b;
            qn += a * a;
            vn += b * b;
        }
        if (dot > 0 and dot / (@sqrt(qn * vn) + 0.0001) >= 0.15) try ids.append(allocator, node.id);
    }
    if (ids.items.len == 0 and context.query.len == 0) return all(ctx, store, context, allocator);
    return ids;
}

/// Bounded lexical ∪ hash-vector candidate recall. This only contributes IDs;
/// lifecycle filtering, propagation, scoring and ordering remain kernel-owned.
fn hybridCandidates(ctx: *anyopaque, store: *const store_mod.Store, context: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
    var lexical_ids = try indexedCandidates(ctx, store, context, allocator);
    defer lexical_ids.deinit(allocator);
    var vector_ids = try vectorCandidates(ctx, store, context, allocator);
    defer vector_ids.deinit(allocator);
    var ids = std.ArrayList(u64).empty;
    errdefer ids.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (lexical_ids.items) |id| if (!(try seen.getOrPut(id)).found_existing) try ids.append(allocator, id);
    for (vector_ids.items) |id| if (!(try seen.getOrPut(id)).found_existing) try ids.append(allocator, id);
    return ids;
}
fn reset(ctx: *anyopaque, store: *const store_mod.Store) !void {
    return (@as(*Indexes, @ptrCast(@alignCast(ctx)))).reset(store);
}
fn upsert(ctx: *anyopaque, store: *const store_mod.Store, id: u64) !void {
    const index: *Indexes = @ptrCast(@alignCast(ctx));
    const node = store.constNode(id) orelse return error.UnknownNode;
    return index.indexNode(store, node.*);
}
fn remove(ctx: *anyopaque, id: u64) void {
    const index: *Indexes = @ptrCast(@alignCast(ctx));
    _ = index.vectors.remove(id);
}
fn nameSymbolic(_: *anyopaque) []const u8 {
    return "symbolic";
}
fn nameVector(_: *anyopaque) []const u8 {
    return "vector";
}
fn nameGraph(_: *anyopaque) []const u8 {
    return "graph";
}
fn nameHybrid(_: *anyopaque) []const u8 {
    return "hybrid";
}

pub const Owned = struct {
    indexes: *Indexes,
    provider: Provider,
    pub fn init(allocator: std.mem.Allocator, kind: enum { symbolic, vector, graph, hybrid }) Owned {
        const indexes = allocator.create(Indexes) catch @panic("MEML backend allocation failed");
        indexes.* = Indexes.init(allocator);
        return .{ .indexes = indexes, .provider = switch (kind) {
            .symbolic => .{ .context = indexes, .nameFn = nameSymbolic, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = indexedCandidates },
            .vector => .{ .context = indexes, .nameFn = nameVector, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = vectorCandidates },
            .graph => .{ .context = indexes, .nameFn = nameGraph, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = graph },
            .hybrid => .{ .context = indexes, .nameFn = nameHybrid, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = hybridCandidates },
        } };
    }
    pub fn deinit(self: *Owned) void {
        self.indexes.deinit();
        self.indexes.allocator.destroy(self.indexes);
    }
};
pub const Symbolic = struct {
    pub fn exhaustive() Provider {
        return .{ .context = undefined, .nameFn = nameSymbolic, .resetFn = exhaustiveReset, .upsertFn = exhaustiveUpsert, .removeFn = exhaustiveRemove, .candidatesFn = all };
    }
};

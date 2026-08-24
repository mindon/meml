const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");

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

fn exhaustiveReset(_: *anyopaque, _: *const store_mod.Store) !void {}
fn exhaustiveUpsert(_: *anyopaque, _: *const store_mod.Store, _: u64) !void {}
fn exhaustiveRemove(_: *anyopaque, _: u64) void {}

const token_delimiters = " \t\n\r,.;:!?()[]{}\"'";

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
        for (token, 0..) |byte, index| owned[index] = std.ascii.toLower(byte);
        const entry = try self.tokens.getOrPut(owned);
        if (!entry.found_existing) entry.value_ptr.* = .empty else self.allocator.free(owned);
        for (entry.value_ptr.items) |old| if (old == id) return;
        try entry.value_ptr.append(self.allocator, id);
    }
    fn indexNode(self: *Indexes, node: model.Node) !void {
        var buffer: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s} {s} {s} {s} {s}", .{ node.subject, node.predicate, node.object, node.context, node.result }) catch "";
        var it = std.mem.tokenizeAny(u8, text, token_delimiters);
        while (it.next()) |token| try self.addToken(token, node.id);
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
        for (store.nodes.items) |node| try self.indexNode(node);
    }
};
fn hashToken(token: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (token) |c| h = (h ^ std.ascii.toLower(c)) *% 1099511628211;
    return h;
}
fn vector(node: model.Node, query: []const u8) [32]f32 {
    var out = std.mem.zeroes([32]f32);
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s} {s} {s} {s} {s} {s}", .{ node.subject, node.predicate, node.object, node.context, node.result, query }) catch "";
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r,.;:!?()[]{}\"'");
    while (it.next()) |token| out[hashToken(token) % 32] += 1;
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
    for (raw_token, 0..) |byte, index| token[index] = std.ascii.toLower(byte);
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
        var tokens = std.mem.tokenizeAny(u8, term, token_delimiters);
        while (tokens.next()) |token| {
            has_token = true;
            try appendTokenMatches(indexes, token, &seen, &ids, allocator);
        }
    }
    if (!has_token) return all(ctx, store, context, allocator);
    return ids;
}
fn graph(ctx: *anyopaque, store: *const store_mod.Store, context: model.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
    var ids = try indexedCandidates(ctx, store, context, allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (ids.items) |id| try seen.put(id, {});
    for (store.relations.items) |relation| if (seen.contains(relation.from) or seen.contains(relation.to)) {
        const other = if (seen.contains(relation.from)) relation.to else relation.from;
        if (!seen.contains(other)) {
            try seen.put(other, {});
            try ids.append(allocator, other);
        }
    };
    return ids;
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
fn reset(ctx: *anyopaque, store: *const store_mod.Store) !void {
    return (@as(*Indexes, @ptrCast(@alignCast(ctx)))).reset(store);
}
fn upsert(ctx: *anyopaque, store: *const store_mod.Store, id: u64) !void {
    const index: *Indexes = @ptrCast(@alignCast(ctx));
    const node = store.constNode(id) orelse return error.UnknownNode;
    return index.indexNode(node.*);
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

pub const Owned = struct {
    indexes: *Indexes,
    provider: Provider,
    pub fn init(allocator: std.mem.Allocator, kind: enum { symbolic, vector, graph }) Owned {
        const indexes = allocator.create(Indexes) catch @panic("MEML backend allocation failed");
        indexes.* = Indexes.init(allocator);
        return .{ .indexes = indexes, .provider = switch (kind) {
            .symbolic => .{ .context = indexes, .nameFn = nameSymbolic, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = indexedCandidates },
            .vector => .{ .context = indexes, .nameFn = nameVector, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = vectorCandidates },
            .graph => .{ .context = indexes, .nameFn = nameGraph, .resetFn = reset, .upsertFn = upsert, .removeFn = remove, .candidatesFn = graph },
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

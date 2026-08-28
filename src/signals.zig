const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const tokenizer = @import("tokenizer.zig");

/// Signal/reranking contract. A provider may be replaced without changing
/// the kernel-owned scoring and candidate-routing boundaries.
pub const Provider = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    scoreFn: *const fn (*anyopaque, *const store_mod.Store, model.Node, model.Context) f64,
    /// Relative contribution when the pipeline aggregates providers.
    weight: f64 = 1,
    pub fn name(self: Provider) []const u8 {
        return self.nameFn(self.context);
    }
    pub fn score(self: Provider, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
        return std.math.clamp(self.scoreFn(self.context, store, node, context), 0, 1);
    }
    pub fn weighted(self: Provider, weight: f64) Provider {
        var updated = self;
        updated.weight = if (std.math.isFinite(weight) and weight >= 0) weight else 0;
        return updated;
    }
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayList(Provider),
    pub fn init(allocator: std.mem.Allocator) Pipeline {
        return .{ .allocator = allocator, .providers = .empty };
    }
    pub fn deinit(self: *Pipeline) void {
        self.providers.deinit(self.allocator);
    }
    pub fn append(self: *Pipeline, provider: Provider) !void {
        // Keep every active provider explainable; do not silently truncate trace.
        if (self.providers.items.len >= (model.ProviderTrace{}).items.len) return error.ProviderTraceCapacityExceeded;
        try self.providers.append(self.allocator, provider);
    }
    pub const Score = struct { value: f64 = 0, trace: model.ProviderTrace = .{} };

    /// Returns an auditable aggregate along with individual provider inputs.
    pub fn scoreWithTrace(self: *const Pipeline, store: *const store_mod.Store, node: model.Node, context: model.Context) Score {
        var output = Score{};
        var weight_total: f64 = 0;
        for (self.providers.items, 0..) |provider, index| {
            const provider_score = provider.score(store, node, context);
            const weight = if (std.math.isFinite(provider.weight) and provider.weight >= 0) provider.weight else 0;
            output.value += provider_score * weight;
            weight_total += weight;
            if (index < output.trace.items.len) {
                output.trace.items[index] = .{ .name = provider.name(), .score = provider_score, .weight = weight };
                output.trace.count += 1;
            }
        }
        if (weight_total > 0) output.value /= weight_total;
        return output;
    }

    /// Compatibility convenience for callers that only need the aggregate.
    pub fn score(self: *const Pipeline, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
        return self.scoreWithTrace(store, node, context).value;
    }
};

fn nameEmbedding(_: *anyopaque) []const u8 {
    return "embedding";
}
fn nameMetadata(_: *anyopaque) []const u8 {
    return "metadata";
}
fn nameReranker(_: *anyopaque) []const u8 {
    return "reranker";
}
fn nameCalibrated(_: *anyopaque) []const u8 {
    return "calibrated";
}
fn addTextToEmbedding(vector: *[32]f32, text: []const u8) void {
    var tokens = tokenizer.tokenize(text);
    while (tokens.next()) |token| vector[tokenizer.hash(token) % vector.len] += 1;
}

fn cosine(lhs: []const f32, rhs: []const f32) f64 {
    if (lhs.len == 0 or lhs.len != rhs.len) return 0;
    var dot: f64 = 0;
    var lhs_norm: f64 = 0;
    var rhs_norm: f64 = 0;
    for (lhs, rhs) |left, right| {
        dot += left * right;
        lhs_norm += left * left;
        rhs_norm += right * right;
    }
    if (lhs_norm == 0 or rhs_norm == 0) return 0;
    return std.math.clamp(dot / @sqrt(lhs_norm * rhs_norm), 0, 1);
}

fn embedding(_: *anyopaque, _: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
    var lhs = std.mem.zeroes([32]f32);
    var rhs = std.mem.zeroes([32]f32);
    addTextToEmbedding(&lhs, node.subject);
    addTextToEmbedding(&lhs, node.object);
    addTextToEmbedding(&lhs, node.context);
    addTextToEmbedding(&lhs, node.result);
    addTextToEmbedding(&rhs, context.query);
    addTextToEmbedding(&rhs, context.situation);
    addTextToEmbedding(&rhs, context.goal);
    return cosine(&lhs, &rhs);
}
fn metadata(_: *anyopaque, _: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
    const age = @abs(context.now - node.timestamp);
    const recency = if (context.now == 0) 0.5 else 1 / (1 + @as(f64, @floatFromInt(age)) / 86_400);
    return std.math.clamp((recency + node.confidence * node.strength) / 2, 0, 1);
}
fn reranker(_: *anyopaque, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
    var score = metadata(undefined, store, node, context);
    if (node.kind == .procedure and context.goal.len > 0) score += 0.25;
    return std.math.clamp(score, 0, 1);
}

/// A data-driven reference provider. Its versioned parameters live in Store,
/// so scoring stays transparent and the provider cannot alter kernel ranking.
fn calibrated(_: *anyopaque, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
    const state = store.learnedSignal("calibrated") orelse return 0;
    const base = (embedding(undefined, store, node, context) + metadata(undefined, store, node, context)) / 2;
    return std.math.clamp(base * state.weight + state.bias, 0, 1);
}

pub const Embedding = struct {
    pub fn provider() Provider {
        return .{ .context = undefined, .nameFn = nameEmbedding, .scoreFn = embedding };
    }
};

/// Host-owned local vector cache contract. Query and node embeddings must be
/// precomputed or cached locally; MEML never performs model I/O during scoring.
pub const LocalEmbedding = struct {
    context: *anyopaque,
    model_version: []const u8,
    model_sha256: []const u8,
    queryFn: *const fn (*anyopaque, model.Context) ?[]const f32,
    nodeFn: *const fn (*anyopaque, u64) ?[]const f32,

    pub fn provider(self: *LocalEmbedding) Provider {
        return .{ .context = self, .nameFn = name, .scoreFn = score };
    }

    pub fn name(context: *anyopaque) []const u8 {
        const self: *const LocalEmbedding = @ptrCast(@alignCast(context));
        return self.model_version;
    }

    fn score(context: *anyopaque, _: *const store_mod.Store, node: model.Node, request: model.Context) f64 {
        const self: *const LocalEmbedding = @ptrCast(@alignCast(context));
        const query = self.queryFn(self.context, request) orelse return 0;
        const document = self.nodeFn(self.context, node.id) orelse return 0;
        return cosine(query, document);
    }
};
pub const Metadata = struct {
    pub fn provider() Provider {
        return .{ .context = undefined, .nameFn = nameMetadata, .scoreFn = metadata };
    }
};
pub const Reranker = struct {
    pub fn provider() Provider {
        return .{ .context = undefined, .nameFn = nameReranker, .scoreFn = reranker };
    }
};

pub const Calibrated = struct {
    pub fn provider() Provider {
        return .{ .context = undefined, .nameFn = nameCalibrated, .scoreFn = calibrated };
    }
};

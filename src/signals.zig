const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");

/// Signal/reranking contract. A provider may be replaced without changing
/// the kernel-owned scoring and candidate-routing boundaries.
pub const Provider = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    scoreFn: *const fn (*anyopaque, *const store_mod.Store, model.Node, model.Context) f64,
    pub fn name(self: Provider) []const u8 {
        return self.nameFn(self.context);
    }
    pub fn score(self: Provider, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
        return std.math.clamp(self.scoreFn(self.context, store, node, context), 0, 1);
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
        try self.providers.append(self.allocator, provider);
    }
    pub fn score(self: *const Pipeline, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
        if (self.providers.items.len == 0) return 0;
        var total: f64 = 0;
        for (self.providers.items) |provider| total += provider.score(store, node, context);
        return total / @as(f64, @floatFromInt(self.providers.items.len));
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
fn tokenHash(token: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (token) |c| h = (h ^ std.ascii.toLower(c)) *% 1099511628211;
    return h;
}
fn embedding(_: *anyopaque, _: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
    var lhs = std.mem.zeroes([32]f32);
    var rhs = std.mem.zeroes([32]f32);
    var left_buffer: [4096]u8 = undefined;
    var right_buffer: [4096]u8 = undefined;
    const left = std.fmt.bufPrint(left_buffer[0..], "{s} {s} {s} {s}", .{ node.subject, node.object, node.context, node.result }) catch "";
    const right = std.fmt.bufPrint(right_buffer[0..], "{s} {s} {s}", .{ context.query, context.situation, context.goal }) catch "";
    var it = std.mem.tokenizeAny(u8, left, " \t\n\r,.;:!?()[]{}\"'");
    while (it.next()) |token| lhs[tokenHash(token) % 32] += 1;
    it = std.mem.tokenizeAny(u8, right, " \t\n\r,.;:!?()[]{}\"'");
    while (it.next()) |token| rhs[tokenHash(token) % 32] += 1;
    var dot: f32 = 0;
    var ln: f32 = 0;
    var rn: f32 = 0;
    for (lhs, rhs) |a, b| {
        dot += a * b;
        ln += a * a;
        rn += b * b;
    }
    return @as(f64, dot / (@sqrt(ln * rn) + 0.0001));
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

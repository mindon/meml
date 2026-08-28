const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const backend_mod = @import("backend.zig");
const ranking = @import("ranking.zig");
const signals_mod = @import("signals.zig");

pub const Stats = struct {
    candidates: usize = 0,
    seeds: usize = 0,
    propagated: usize = 0,
    edges_examined: usize = 0,
    scored: usize = 0,
    returned: usize = 0,
};

pub const Result = struct {
    items: std.ArrayList(model.Activation),
    stats: Stats,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

/// The kernel-owned retrieval pipeline. Backends route candidate IDs; the
/// kernel owns scoring, ordering, limits, and explainable signals.
pub fn run(store: *const store_mod.Store, backend: backend_mod.Backend, context: model.Context, limit: usize, allocator: std.mem.Allocator) !Result {
    return runWithPipeline(store, backend, context, limit, allocator, null);
}

fn activationAllowed(node: *const model.Node, policy: model.ActivationPolicy) bool {
    return switch (policy) {
        .active_only => node.cognitive_state == .active,
        .include_contested => node.cognitive_state != .archived and node.cognitive_state != .superseded,
        .include_historical => true,
    };
}

fn propagate(store: *const store_mod.Store, seeds: []const u64, context: model.Context, allocator: std.mem.Allocator) !struct { ids: std.ArrayList(u64), stats: Stats } {
    var ids = std.ArrayList(u64).empty;
    errdefer ids.deinit(allocator);
    if (context.propagation.max_hops == 0) {
        try ids.appendSlice(allocator, seeds);
        return .{ .ids = ids, .stats = .{ .candidates = seeds.len, .seeds = seeds.len } };
    }
    var frontier = std.ArrayList(u64).empty;
    defer frontier.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    const seed_count = @min(seeds.len, context.propagation.seed_limit);
    for (seeds[0..seed_count]) |id| {
        const node = store.constNode(id) orelse continue;
        if (!activationAllowed(node, context.activation_policy)) continue;
        if (!(try seen.getOrPut(id)).found_existing) {
            try ids.append(allocator, id);
            try frontier.append(allocator, id);
        }
    }
    var stats: Stats = .{ .seeds = frontier.items.len };
    var hop: u8 = 0;
    while (hop < context.propagation.max_hops and frontier.items.len > 0 and stats.edges_examined < context.propagation.edge_limit and ids.items.len < context.propagation.candidate_limit) : (hop += 1) {
        var next = std.ArrayList(u64).empty;
        defer next.deinit(allocator);
        for (frontier.items) |current| {
            for (store.relations.items) |relation| {
                if (stats.edges_examined >= context.propagation.edge_limit or ids.items.len >= context.propagation.candidate_limit) break;
                if (relation.from != current and relation.to != current) continue;
                stats.edges_examined += 1;
                const other = if (relation.from == current) relation.to else relation.from;
                const node = store.constNode(other) orelse continue;
                if (!activationAllowed(node, context.activation_policy)) continue;
                if (!(try seen.getOrPut(other)).found_existing) {
                    try ids.append(allocator, other);
                    try next.append(allocator, other);
                    stats.propagated += 1;
                }
            }
        }
        frontier.clearRetainingCapacity();
        try frontier.appendSlice(allocator, next.items);
    }
    stats.candidates = ids.items.len;
    return .{ .ids = ids, .stats = stats };
}

pub fn runWithPipeline(store: *const store_mod.Store, backend: backend_mod.Backend, context: model.Context, limit: usize, allocator: std.mem.Allocator, pipeline: ?*const signals_mod.Pipeline) !Result {
    if (!std.math.isFinite(context.minimum_stability) or context.minimum_stability < 0 or context.minimum_stability > 1 or context.propagation.max_hops > 8 or context.propagation.seed_limit == 0 or context.propagation.candidate_limit == 0) return error.InvalidActivationContext;
    var base = try backend.candidates(store, context, allocator);
    defer base.deinit(allocator);
    var propagated = try propagate(store, base.items, context, allocator);
    defer propagated.ids.deinit(allocator);

    var output = std.ArrayList(model.Activation).empty;
    errdefer output.deinit(allocator);
    for (propagated.ids.items) |id| {
        const node = store.constNode(id) orelse continue;
        if (!activationAllowed(node, context.activation_policy)) continue;
        const stable = ranking.stability(store, node.*);
        if (stable.score < context.minimum_stability) continue;
        var scored_signals = ranking.signals(store, node.*, context);
        var provider_trace = model.ProviderTrace{};
        if (pipeline) |p| {
            const pipeline_score = p.scoreWithTrace(store, node.*, context);
            scored_signals.external = pipeline_score.value;
            provider_trace = pipeline_score.trace;
        }
        try output.append(allocator, .{ .id = id, .score = scored_signals.total(context.weights), .signals = scored_signals, .provider_trace = provider_trace });
    }
    const scored = output.items.len;
    std.sort.heap(model.Activation, output.items, {}, ranking.sortActivations);
    if (output.items.len > limit) output.shrinkRetainingCapacity(limit);
    propagated.stats.scored = scored;
    propagated.stats.returned = output.items.len;
    return .{ .items = output, .stats = propagated.stats };
}

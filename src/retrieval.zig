const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const backend_mod = @import("backend.zig");
const ranking = @import("ranking.zig");
const signals_mod = @import("signals.zig");

pub const Stats = struct {
    candidates: usize = 0,
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

pub fn runWithPipeline(store: *const store_mod.Store, backend: backend_mod.Backend, context: model.Context, limit: usize, allocator: std.mem.Allocator, pipeline: ?*const signals_mod.Pipeline) !Result {
    var ids = try backend.candidates(store, context, allocator);
    defer ids.deinit(allocator);

    var output = std.ArrayList(model.Activation).empty;
    errdefer output.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (ids.items) |id| {
        const seen_entry = try seen.getOrPut(id);
        if (seen_entry.found_existing) continue;
        const node = store.constNode(id) orelse continue;
        if (node.kind == .belief and (node.belief_state == .archived or node.belief_state == .superseded)) continue;
        var scored_signals = ranking.signals(store, node.*, context);
        if (pipeline) |p| scored_signals.external = p.score(store, node.*, context);
        try output.append(allocator, .{ .id = id, .score = scored_signals.total(context.weights), .signals = scored_signals });
    }
    const scored = output.items.len;
    std.sort.heap(model.Activation, output.items, {}, ranking.sortActivations);
    if (output.items.len > limit) output.shrinkRetainingCapacity(limit);
    return .{ .items = output, .stats = .{ .candidates = ids.items.len, .scored = scored, .returned = output.items.len } };
}

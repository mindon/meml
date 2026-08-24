const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const signals = @import("signals.zig");

pub const Proposal = struct { subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, confidence: f64, source_a: u64, source_b: u64 };

/// Neural consolidation never mutates the store directly. It proposes
/// kernel-native nodes; Runtime commits them and records provenance.
pub const Consolidator = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    proposeFn: *const fn (*anyopaque, *const store_mod.Store, std.mem.Allocator) anyerror!std.ArrayList(Proposal),
    pub fn name(self: Consolidator) []const u8 {
        return self.nameFn(self.context);
    }
    pub fn propose(self: Consolidator, store: *const store_mod.Store, allocator: std.mem.Allocator) !std.ArrayList(Proposal) {
        return self.proposeFn(self.context, store, allocator);
    }
};

fn nameDeterministic(_: *anyopaque) []const u8 {
    return "deterministic-neural";
}
fn proposeDeterministic(_: *anyopaque, store: *const store_mod.Store, allocator: std.mem.Allocator) !std.ArrayList(Proposal) {
    var out = std.ArrayList(Proposal).empty;
    for (store.nodes.items, 0..) |left, i| {
        if (left.kind != .claim and left.kind != .evidence and left.kind != .memory) continue;
        for (store.nodes.items[i + 1 ..]) |right| {
            if (right.kind != .claim and right.kind != .evidence and right.kind != .memory) continue;
            if (std.mem.eql(u8, left.subject, right.subject) and std.mem.eql(u8, left.predicate, right.predicate) and std.mem.eql(u8, left.object, right.object)) {
                try out.append(allocator, .{ .subject = left.subject, .predicate = left.predicate, .object = left.object, .context = left.context, .result = "neural consolidation", .confidence = @min(1, (left.confidence + right.confidence) / 2 + 0.1), .source_a = left.id, .source_b = right.id });
                break;
            }
        }
    }
    return out;
}
pub const Deterministic = struct {
    pub fn consolidator() Consolidator {
        return .{ .context = undefined, .nameFn = nameDeterministic, .proposeFn = proposeDeterministic };
    }
};

fn neuralName(_: *anyopaque) []const u8 {
    return "neural-retrieval";
}
fn neuralScore(_: *anyopaque, store: *const store_mod.Store, node: model.Node, context: model.Context) f64 {
    if (context.query.len == 0) return 0;
    var score: f64 = 0;
    for (context.query) |q| {
        if (std.mem.indexOfScalar(u8, node.object, q) != null) score += 0.08;
        if (std.mem.indexOfScalar(u8, node.context, q) != null) score += 0.04;
    }
    for (store.neural_states.items) |state| {
        if (state.artifact == node.id) {
            score += @min(0.25, 0.05 + @as(f64, @floatFromInt(state.activation_count)) * 0.01) * state.strength;
            break;
        }
    }
    return @min(1, score);
}
/// Replaceable neural retrieval signal. The reference provider consumes the
/// persisted artifact state; production providers can replace the state shape
/// with learned parameters while preserving the signal contract.
pub fn retrievalProvider() signals.Provider {
    return .{ .context = undefined, .nameFn = neuralName, .scoreFn = neuralScore };
}

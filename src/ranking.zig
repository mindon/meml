const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");

pub fn has(haystack: []const u8, needle: []const u8) bool {
    return needle.len > 0 and std.mem.indexOf(u8, haystack, needle) != null;
}

fn lexical(node: model.Node, query: []const u8) f64 {
    if (query.len == 0) return 0;
    var score: f64 = 0;
    if (has(node.subject, query)) score += 0.25;
    if (has(node.predicate, query)) score += 0.25;
    if (has(node.object, query)) score += 0.3;
    if (has(node.context, query)) score += 0.2;
    return @min(1, score);
}

fn semantic(node: model.Node, context: model.Context) f64 {
    var score: f64 = 0;
    if (has(context.query, node.object) or has(node.object, context.query)) score += 0.5;
    if (has(context.situation, node.context) or has(node.context, context.situation)) score += 0.3;
    if (has(context.user, node.subject)) score += 0.2;
    return @min(1, score);
}

fn scopeScore(store: *const store_mod.Store, id: u64, requested: []const model.Scope) f64 {
    if (requested.len == 0) return 0;
    var matches: usize = 0;
    for (requested) |scope| {
        var found = false;
        for (store.scoped_records.items) |record| {
            if (record.node == id and std.mem.eql(u8, record.scope.key, scope.key)) {
                if (!std.mem.eql(u8, record.scope.value, scope.value)) return 0;
                found = true;
                break;
            }
        }
        if (found) matches += 1;
    }
    return @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(requested.len));
}

fn metricQuality(store: *const store_mod.Store, id: u64) f64 {
    var count: usize = 0;
    var uncertainty_penalty: f64 = 0;
    for (store.metric_records.items) |record| if (record.node == id) {
        count += 1;
        if (record.metric.uncertainty) |uncertainty| uncertainty_penalty += @min(0.5, uncertainty / (@abs(record.metric.value) + 0.000001));
    };
    if (count == 0) return 0;
    return @max(0, @min(1, 0.5 + @min(0.4, @as(f64, @floatFromInt(count)) * 0.1) - uncertainty_penalty / @as(f64, @floatFromInt(count))));
}

fn structureScore(store: *const store_mod.Store, id: u64, requested: ?model.Structure) f64 {
    const expected = requested orelse return 0;
    for (store.structure_records.items) |record| if (record.node == id and std.mem.eql(u8, record.structure.kind, expected.kind) and std.mem.eql(u8, record.structure.fingerprint, expected.fingerprint)) return 1;
    return 0;
}

fn lineageScore(store: *const store_mod.Store, id: u64) f64 {
    var count: usize = 0;
    for (store.relations.items) |relation| {
        if (relation.from == id and relation.kind == .derived_from) count += 1;
    }
    return @min(1, @as(f64, @floatFromInt(count)) * 0.25);
}

/// Computes a discrete, reproducible attractor classification from durable
/// evidence and audited state transitions. It never creates another mutable
/// truth: callers can always recompute it from the semantic store.
pub fn stability(store: *const store_mod.Store, node: model.Node) model.Stability {
    var support: usize = 0;
    var contradiction: usize = 0;
    for (store.relations.items) |relation| {
        if (relation.to != node.id) continue;
        if (relation.kind == .supports) support += 1;
        if (relation.kind == .contradicts) contradiction += 1;
    }
    var transitions: usize = 0;
    for (store.transition_records.items) |record| {
        if (record.target == node.id) transitions += 1;
    }
    if (node.cognitive_state == .contested) return .{ .state = .contested, .score = 0, .support = support, .contradiction = contradiction, .transitions = transitions };
    const evidence = @as(f64, @floatFromInt(support)) / @as(f64, @floatFromInt(support + contradiction + 1));
    const history = @min(1, @as(f64, @floatFromInt(transitions)) / 3);
    const lineage = lineageScore(store, node.id);
    const score = std.math.clamp(node.confidence * node.strength * 0.5 + evidence * 0.25 + history * 0.15 + lineage * 0.1, 0, 1);
    const state: model.AttractorState = if (score >= 0.75 and support >= 2 and contradiction == 0) .stable else if (score >= 0.4 or support > contradiction) .emerging else .transient;
    return .{ .state = state, .score = score, .support = support, .contradiction = contradiction, .transitions = transitions };
}

fn graphScore(store: *const store_mod.Store, id: u64, context: model.Context) f64 {
    for (store.relations.items) |relation| {
        if (relation.from != id and relation.to != id) continue;
        if (relation.kind != .causes and relation.kind != .supports) continue;
        const other = store.constNode(if (relation.from == id) relation.to else relation.from) orelse continue;
        if (context.goal.len > 0 and (has(other.object, context.goal) or has(other.context, context.goal))) return @min(1, relation.weight);
    }
    return 0;
}

fn contradictionScore(store: *const store_mod.Store, id: u64, context: model.Context) f64 {
    if (!context.resolve_conflicts) return 0;
    const node = store.constNode(id) orelse return 0;
    var score: f64 = 0;
    for (store.relations.items) |relation| {
        if (relation.kind != .contradicts or (relation.from != id and relation.to != id)) continue;
        const other = store.constNode(if (relation.from == id) relation.to else relation.from) orelse continue;
        var relevance: f64 = 0.35;
        if (context.situation.len > 0) {
            if (has(other.context, context.situation)) relevance += 0.35;
            if (has(node.context, context.situation) and !has(other.context, context.situation)) relevance -= 0.20;
        }
        if (context.goal.len > 0 and (has(other.object, context.goal) or has(other.context, context.goal))) relevance += 0.20;
        if (context.query.len > 0 and (has(other.predicate, context.query) or has(other.object, context.query))) relevance += 0.10;
        score = @max(score, @min(1, relevance * relation.weight));
    }
    return score;
}

pub fn signals(store: *const store_mod.Store, node: model.Node, context: model.Context) model.Signals {
    const age = @abs(context.now - node.timestamp);
    const temporal = if (context.now == 0) 0.5 else 1 / (1 + @as(f64, @floatFromInt(age)) / 86_400);
    var output = model.Signals{
        .semantic = semantic(node, context),
        .lexical = lexical(node, context.query),
        .temporal = temporal,
        .causal = graphScore(store, node.id, context),
        .procedural = if (node.kind == .procedure or has(node.predicate, "does") or has(context.goal, "how")) 1 else 0,
        .preference = if (context.preferred.len > 0 and has(node.object, context.preferred)) 1 else 0,
        .goal = if (context.goal.len > 0 and (has(node.object, context.goal) or has(node.context, context.goal) or has(node.predicate, context.goal))) 1 else 0,
        .confidence = node.confidence * node.strength,
        .scope = scopeScore(store, node.id, context.scopes),
        .metric = metricQuality(store, node.id),
        .structure = structureScore(store, node.id, context.structure),
        .lineage = lineageScore(store, node.id),
        .stability = stability(store, node).score,
        .contradiction = contradictionScore(store, node.id, context),
    };
    if (node.cognitive_state == .contested and context.resolve_conflicts) output.confidence *= 0.6;
    return output;
}

pub fn sortActivations(_: void, left: model.Activation, right: model.Activation) bool {
    if (left.score == right.score) return left.id < right.id;
    return left.score > right.score;
}

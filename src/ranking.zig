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
        .contradiction = contradictionScore(store, node.id, context),
    };
    if (node.belief_state == .contested and context.resolve_conflicts) output.confidence *= 0.6;
    return output;
}

pub fn sortActivations(_: void, left: model.Activation, right: model.Activation) bool {
    return left.score > right.score;
}

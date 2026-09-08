const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");

pub const Report = struct {
    scanned_experiences: usize = 0,
    pending_experiences: usize = 0,
    skipped: bool = false,
    memories_created: usize = 0,
    beliefs_created: usize = 0,
    concepts_created: usize = 0,
    procedures_created: usize = 0,
    neural_artifacts_created: usize = 0,
};

pub const Policy = struct {
    repeat_threshold: usize = 2,
    procedure_success_ratio: f64 = 0.75,
    auto_consolidate: bool = true,
    enable_memory: bool = true,
    enable_belief: bool = true,
    enable_concept: bool = true,
    enable_procedure: bool = true,
    enable_neural: bool = true,
    abort_after_artifacts: ?usize = null,

    pub fn key(self: Policy) u8 {
        return @as(u8, @intFromBool(self.enable_memory)) | (@as(u8, @intFromBool(self.enable_belief)) << 1) |
            (@as(u8, @intFromBool(self.enable_concept)) << 2) | (@as(u8, @intFromBool(self.enable_procedure)) << 3) |
            (@as(u8, @intFromBool(self.enable_neural)) << 4);
    }
};

/// Runtime-owned mutation operations required by the built-in strategy. The
/// strategy is deliberately independent from Runtime's concrete type: it
/// describes default memory evolution while the host preserves identity,
/// transactionality, lifecycle audit, and provider state.
pub const Host = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    clock: *i64,
    makeFn: *const fn (*anyopaque, model.Kind, []const u8, []const u8, []const u8, []const u8, []const u8, f64, i64) anyerror!u64,
    transitionFn: *const fn (*anyopaque, model.TransitionInput) anyerror!u64,
    proposalsFn: *const fn (*anyopaque, []const Proposal) anyerror!usize,
    neuralFn: *const fn (*anyopaque) anyerror!usize,

    pub fn make(self: Host, kind: model.Kind, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, confidence: f64) !u64 {
        return self.makeFn(self.context, kind, subject, predicate, object, context, result, confidence, self.clock.*);
    }

    pub fn transition(self: Host, input: model.TransitionInput) !u64 {
        return self.transitionFn(self.context, input);
    }

    pub fn applyProposals(self: Host, proposals: []const Proposal) !usize {
        return self.proposalsFn(self.context, proposals);
    }

    pub fn consolidateNeural(self: Host) !usize {
        return self.neuralFn(self.context);
    }
};

/// A strategy can only propose derived semantic records. The Runtime remains
/// the sole authority that validates IDs, creates nodes, writes lineage, and
/// commits the proposal atomically.
pub const Proposal = struct {
    kind: model.Kind = .belief,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    context: []const u8,
    result: []const u8,
    confidence: f64,
    source_a: u64,
    source_b: u64 = 0,
    rule: []const u8,
    rule_version: u32 = 1,
    neural_state: ?model.NeuralState = null,
};

/// Candidate-only extension point for domain consolidation. Strategies cannot
/// mutate Store and cannot bypass Runtime identity, provenance, or rollback.
pub const Strategy = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    proposeFn: *const fn (*anyopaque, *const store_mod.Store, std.mem.Allocator) anyerror!std.ArrayList(Proposal),

    pub fn name(self: Strategy) []const u8 {
        return self.nameFn(self.context);
    }

    pub fn propose(self: Strategy, store: *const store_mod.Store, allocator: std.mem.Allocator) !std.ArrayList(Proposal) {
        return self.proposeFn(self.context, store, allocator);
    }
};

fn sameSemantic(left: model.Node, right: model.Node) bool {
    return std.mem.eql(u8, left.subject, right.subject) and std.mem.eql(u8, left.predicate, right.predicate) and
        std.mem.eql(u8, left.object, right.object) and std.mem.eql(u8, left.context, right.context);
}

fn fingerprint(subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8) u64 {
    var seed: u64 = 0;
    seed = std.hash.Wyhash.hash(seed, subject);
    seed = std.hash.Wyhash.hash(seed, predicate);
    seed = std.hash.Wyhash.hash(seed, object);
    seed = std.hash.Wyhash.hash(seed, context);
    return std.hash.Wyhash.hash(seed, result);
}

fn recordRule(host: Host, artifact: u64, rule: []const u8, source_a: u64, source_b: u64) !void {
    try host.store.recordConsolidation(.{ .artifact = artifact, .rule = try host.allocator.dupe(u8, rule), .version = 1, .source_a = source_a, .source_b = source_b });
}

fn maybeAbort(policy: Policy, report: Report) !void {
    if (policy.abort_after_artifacts) |limit| {
        const artifacts = report.memories_created + report.beliefs_created + report.concepts_created + report.procedures_created + report.neural_artifacts_created;
        if (artifacts >= limit) return error.InjectedConsolidationFailure;
    }
}

/// The old kernel behavior, moved out of Runtime without changing its public
/// semantics. This strategy uses only Host operations and Store facts.
pub fn runDefault(host: Host, policy: Policy, scope: ?[]const u64, pending_experiences: usize, last_consolidated_experiences: usize, last_consolidation_policy: u8) !Report {
    var report = Report{};
    var experiences = std.ArrayList(u64).empty;
    defer experiences.deinit(host.allocator);
    if (scope) |ids| {
        for (ids) |id| try experiences.append(host.allocator, id);
    } else {
        for (host.store.nodes.items) |node| if (node.kind == .experience) try experiences.append(host.allocator, node.id);
    }
    report.scanned_experiences = experiences.items.len;
    report.pending_experiences = pending_experiences;
    if (scope == null and experiences.items.len == last_consolidated_experiences and policy.key() == last_consolidation_policy) {
        report.skipped = true;
        return report;
    }

    if (policy.enable_memory) for (experiences.items) |experience_id| {
        const experience = host.store.constNode(experience_id).?;
        var exists = false;
        for (host.store.nodes.items) |node| if (node.kind == .memory and sameSemantic(node, experience.*) and host.store.hasRelation(node.id, experience_id, .derived_from)) {
            exists = true;
            break;
        };
        if (!exists) {
            const created = try host.make(.memory, experience.subject, experience.predicate, experience.object, experience.context, experience.result, 0.6);
            try host.store.link(.{ .from = created, .to = experience_id, .kind = .derived_from, .weight = 1 });
            try recordRule(host, created, "experience-to-memory", experience_id, 0);
            report.memories_created += 1;
        }
    };
    try maybeAbort(policy, report);

    const RepeatGroup = struct { representative: u64, last: u64, repetitions: usize, contradictions: usize = 0 };
    var groups = std.ArrayList(RepeatGroup).empty;
    defer groups.deinit(host.allocator);
    var group_by_key = std.AutoHashMap(u64, usize).init(host.allocator);
    defer group_by_key.deinit();
    var group_by_experience = std.AutoHashMap(u64, usize).init(host.allocator);
    defer group_by_experience.deinit();
    for (experiences.items) |experience_id| {
        const experience = host.store.constNode(experience_id).?;
        const entry = try group_by_key.getOrPut(fingerprint(experience.subject, experience.predicate, experience.object, experience.context, experience.result));
        if (entry.found_existing) {
            const group = &groups.items[entry.value_ptr.*];
            group.last = experience_id;
            group.repetitions += 1;
        } else {
            entry.value_ptr.* = groups.items.len;
            try groups.append(host.allocator, .{ .representative = experience_id, .last = experience_id, .repetitions = 1 });
        }
        try group_by_experience.put(experience_id, entry.value_ptr.*);
    }
    for (host.store.relations.items) |relation| {
        if (relation.kind != .contradicts) continue;
        if (group_by_experience.get(relation.to)) |index| groups.items[index].contradictions += 1;
    }

    if (policy.enable_belief) for (groups.items, 0..) |group, group_index| {
        if (group.repetitions < policy.repeat_threshold) continue;
        const left = host.store.constNode(group.representative).?;
        var belief_id: ?u64 = null;
        for (host.store.nodes.items) |node| if (node.kind == .belief and std.mem.eql(u8, node.result, "consolidated repetition") and sameSemantic(node, left.*)) {
            belief_id = node.id;
            break;
        };
        if (belief_id == null) {
            belief_id = try host.make(.belief, left.subject, left.predicate, left.object, left.context, "consolidated repetition", @min(1, 0.5 + @as(f64, @floatFromInt(group.repetitions)) * 0.1));
            if (host.store.node(belief_id.?)) |belief| {
                belief.support_count = @intCast(group.repetitions);
                belief.last_confirmed_at = host.clock.*;
            }
            try recordRule(host, belief_id.?, "repeated-experience-to-belief", group.representative, group.last);
            report.beliefs_created += 1;
        } else if (host.store.node(belief_id.?)) |belief| {
            belief.support_count += @intCast(group.repetitions);
            belief.last_confirmed_at = host.clock.*;
            _ = try host.transition(.{ .target = belief_id.?, .kind = .reinforce, .amount = @min(0.25, 0.05 * @as(f64, @floatFromInt(group.repetitions))), .reason = "kernel repeated experience", .actor = "kernel", .receipt = "consolidation", .timestamp = host.clock.* });
            if (belief.cognitive_state == .contested and belief.contradiction_count == 0) _ = try host.transition(.{ .target = belief_id.?, .kind = .stabilize, .amount = 0.01, .reason = "kernel contradiction resolved", .actor = "kernel", .receipt = "consolidation", .timestamp = host.clock.* });
        }
        if (group.contradictions > 0) {
            for (host.store.relations.items) |relation| {
                if (relation.kind != .contradicts) continue;
                const source_group = group_by_experience.get(relation.to) orelse continue;
                if (source_group != group_index) continue;
                if (!host.store.hasRelation(relation.from, belief_id.?, .contradicts)) {
                    try host.store.link(.{ .from = relation.from, .to = belief_id.?, .kind = .contradicts, .weight = 1 });
                    if (host.store.node(belief_id.?)) |belief| {
                        belief.contradiction_count += 1;
                        belief.last_contradicted_at = host.clock.*;
                    }
                }
            }
            _ = try host.transition(.{ .target = belief_id.?, .kind = .set_state, .target_state = .contested, .reason = "kernel inherited contradictory evidence", .actor = "kernel", .receipt = "consolidation", .timestamp = host.clock.* });
            _ = try host.transition(.{ .target = belief_id.?, .kind = .penalize, .amount = @min(0.8, 0.2 * @as(f64, @floatFromInt(group.contradictions))), .reason = "kernel inherited contradictory evidence", .actor = "kernel", .receipt = "consolidation", .timestamp = host.clock.* });
        }
        const current = host.store.constNode(group.representative).?;
        for (host.store.nodes.items) |node| if (node.kind == .memory and sameSemantic(node, current.*) and !host.store.hasRelation(belief_id.?, node.id, .derived_from)) try host.store.link(.{ .from = belief_id.?, .to = node.id, .kind = .derived_from, .weight = 1 });
    };
    try maybeAbort(policy, report);

    var beliefs = std.ArrayList(model.Node).empty;
    defer beliefs.deinit(host.allocator);
    for (host.store.nodes.items) |node| if (node.kind == .belief and std.mem.eql(u8, node.result, "consolidated repetition")) try beliefs.append(host.allocator, node);
    if (policy.enable_concept and beliefs.items.len >= 2) {
        const first = beliefs.items[0];
        const label = try std.fmt.allocPrint(host.allocator, "generalized {s}", .{first.predicate});
        defer host.allocator.free(label);
        var concept_id: ?u64 = null;
        for (host.store.nodes.items) |node| {
            if (node.kind == .concept and std.mem.eql(u8, node.object, label)) concept_id = node.id;
        }
        if (concept_id == null) {
            concept_id = try host.make(.concept, first.subject, "generalizes", label, first.context, "automatic generalization", 0.7);
            try recordRule(host, concept_id.?, "beliefs-to-concept", beliefs.items[0].id, beliefs.items[1].id);
            report.concepts_created = 1;
        }
        for (beliefs.items) |belief| if (!host.store.hasRelation(concept_id.?, belief.id, .generalizes)) try host.store.link(.{ .from = concept_id.?, .to = belief.id, .kind = .generalizes, .weight = 1 });
    }
    try maybeAbort(policy, report);

    var procedures = std.ArrayList(model.Node).empty;
    defer procedures.deinit(host.allocator);
    if (policy.enable_procedure) for (host.store.nodes.items) |node| if (node.kind == .experience) try procedures.append(host.allocator, node);
    if (policy.enable_procedure and procedures.items.len >= 2) {
        var order_index: usize = 1;
        while (order_index < procedures.items.len) : (order_index += 1) {
            var position = order_index;
            while (position > 0 and procedures.items[position - 1].timestamp > procedures.items[position].timestamp) {
                const temporary = procedures.items[position - 1];
                procedures.items[position - 1] = procedures.items[position];
                procedures.items[position] = temporary;
                position -= 1;
            }
        }
        const first = procedures.items[0];
        const name = try std.fmt.allocPrint(host.allocator, "learned {s} sequence", .{first.predicate});
        defer host.allocator.free(name);
        var procedure_id: ?u64 = null;
        for (host.store.nodes.items) |node| {
            if (node.kind == .procedure and std.mem.eql(u8, node.object, name)) procedure_id = node.id;
        }
        var successes: usize = 0;
        for (procedures.items) |experience| {
            if (std.mem.eql(u8, experience.result, "success")) successes += 1;
        }
        if (@as(f64, @floatFromInt(successes)) / @as(f64, @floatFromInt(procedures.items.len)) >= policy.procedure_success_ratio) {
            if (procedure_id == null) {
                procedure_id = try host.make(.procedure, first.subject, "performs", name, first.context, "automatic sequence", 0.7);
                try recordRule(host, procedure_id.?, "ordered-successful-experiences-to-procedure", procedures.items[0].id, procedures.items[procedures.items.len - 1].id);
                report.procedures_created = 1;
            }
            for (procedures.items, 0..) |experience, index| if (!host.store.hasRelation(procedure_id.?, experience.id, .follows)) try host.store.link(.{ .from = procedure_id.?, .to = experience.id, .kind = .follows, .weight = 1 / @as(f64, @floatFromInt(index + 1)) });
        }
    }
    try maybeAbort(policy, report);
    if (policy.enable_neural) report.neural_artifacts_created = try host.consolidateNeural();
    try maybeAbort(policy, report);
    return report;
}

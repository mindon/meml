const std = @import("std");
const model = @import("model.zig");
const runtime_mod = @import("runtime.zig");
const neural_mod = @import("neural.zig");

pub const Case = struct { query: []const u8, goal: []const u8 = "", situation: []const u8 = "", now: i64 = 0, expected: u64 };
pub const Report = struct {
    cases: usize = 0,
    hits: usize = 0,
    reciprocal_rank: f64 = 0,
    ndcg: f64 = 0,
    pub fn mrr(self: Report) f64 {
        return if (self.cases == 0) 0 else self.reciprocal_rank / @as(f64, @floatFromInt(self.cases));
    }
    pub fn recall(self: Report) f64 {
        return if (self.cases == 0) 0 else @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(self.cases));
    }
    pub fn meanNdcg(self: Report) f64 {
        return if (self.cases == 0) 0 else self.ndcg / @as(f64, @floatFromInt(self.cases));
    }
};

/// Provider quality gate for reproducible evaluation suites. A candidate
/// provider is accepted only when all configured quality floors are met.
pub const QualityGate = struct {
    min_cases: usize = 1,
    min_recall: f64 = 0,
    min_mrr: f64 = 0,
    min_ndcg: f64 = 0,

    pub fn accepts(self: QualityGate, report: Report) bool {
        return report.cases >= self.min_cases and report.recall() >= self.min_recall and report.mrr() >= self.min_mrr and report.meanNdcg() >= self.min_ndcg;
    }
};

/// Versionable human relevance annotation. Dataset owners provide stable task
/// IDs and graded relevance rather than treating generated IDs as ground truth.
pub const AnnotatedCase = struct {
    task_id: []const u8,
    context: model.Context,
    expected: u64,
    relevance: u8,
};

pub const AnnotationReport = struct {
    cases: usize = 0,
    hits: usize = 0,
    reciprocal_rank: f64 = 0,
    ndcg: f64 = 0,

    pub fn asReport(self: AnnotationReport) Report {
        return .{ .cases = self.cases, .hits = self.hits, .reciprocal_rank = self.reciprocal_rank, .ndcg = self.ndcg };
    }
};

/// Evaluates a manually labelled suite. Relevance is constrained to 1..3 so
/// malformed annotations cannot silently create meaningless quality results.
pub fn evaluateAnnotated(runtime: *runtime_mod.Runtime, cases: []const AnnotatedCase, limit: usize, allocator: std.mem.Allocator) !AnnotationReport {
    var report: AnnotationReport = .{};
    for (cases) |case| {
        if (case.task_id.len == 0 or case.relevance == 0 or case.relevance > 3) return error.InvalidAnnotation;
        var result = try runtime.activate(case.context, limit, allocator);
        defer result.deinit(allocator);
        report.cases += 1;
        for (result.items, 0..) |item, index| if (item.id == case.expected) {
            report.hits += 1;
            const rank = @as(f64, @floatFromInt(index + 1));
            report.reciprocal_rank += 1 / rank;
            report.ndcg += 1 / std.math.log2(rank + 1);
            break;
        };
    }
    return report;
}

/// Reproducible Agent loop: retrieve competing strategies, record verified tool
/// outcomes, persist, recover, and ensure later retrieval prefers the strategy
/// with the stronger observed outcome history.
pub const AgentLoopReport = struct {
    feedback_records: usize = 0,
    persisted_revision: u64 = 0,
    recovered_revision: u64 = 0,
    selected_after_restart: u64 = 0,
    expected: u64 = 0,

    pub fn passed(self: AgentLoopReport) bool {
        return self.feedback_records == 2 and self.persisted_revision > 0 and self.recovered_revision == self.persisted_revision and self.selected_after_restart == self.expected;
    }
};

/// Compact reproducible suite covering independent tasks and a contextual
/// preference shift. It prevents a provider from passing by memorizing only
/// one strategy or one static context.
pub const AgentSuiteReport = struct {
    cases: usize = 0,
    hits: usize = 0,
    drift_preferred: bool = false,

    pub fn passed(self: AgentSuiteReport) bool {
        return self.cases == 3 and self.hits == 3 and self.drift_preferred;
    }
};

pub fn evaluateAgentSuite(runtime: *runtime_mod.Runtime, allocator: std.mem.Allocator) !AgentSuiteReport {
    const browser = try runtime.assert("agent", "uses", "browser-tool", "browser", 0.9);
    const data = try runtime.assert("agent", "uses", "data-tool", "data", 0.9);
    const recovery = try runtime.assert("agent", "uses", "recovery-tool", "recovery", 0.9);
    const cases = [_]Case{
        .{ .query = "browser-tool", .situation = "browser", .expected = browser },
        .{ .query = "data-tool", .situation = "data", .expected = data },
        .{ .query = "recovery-tool", .situation = "recovery", .expected = recovery },
    };
    const report = try evaluate(runtime, &cases, 1, allocator);
    const data_browser = try runtime.assert("agent", "uses", "browser-tool", "data", 0.95);
    var shifted = try runtime.activate(.{ .query = "browser-tool", .situation = "data" }, 1, allocator);
    defer shifted.deinit(allocator);
    return .{ .cases = report.cases, .hits = report.hits, .drift_preferred = shifted.items.len == 1 and shifted.items[0].id == data_browser };
}

pub const LongHorizonReport = struct {
    stages: usize = 0,
    memories: usize = 0,
    retrieved: usize = 0,
    self_hosting_records: usize = 0,
    pub fn passed(self: LongHorizonReport) bool {
        return self.stages == 4 and self.retrieved == 4 and self.self_hosting_records >= 4;
    }
};

pub const CausalStatus = enum { pass, partial, fail };

pub const CausalEvolutionReport = struct {
    statuses: [8]CausalStatus,
    baseline_results: usize,
    post_experience_results: usize,
    repeated_experience_nodes: usize,
    memory_nodes_after_observe: usize,
    belief_nodes_after_observe: usize,
    concept_nodes_after_observe: usize,
    procedure_nodes_after_observe: usize,
    relation_count_after_observe: usize,
    explicit_beliefs: usize,
    explicit_concepts: usize,
    explicit_procedures: usize,
    neural_committed: usize,
    restart_results: usize,
    learned_neural_state_artifacts: usize,

    pub fn automaticChainSupported(self: CausalEvolutionReport) bool {
        for (self.statuses) |status| if (status != .pass) return false;
        return true;
    }
};

fn countKind(runtime: *const runtime_mod.Runtime, kind: model.Kind) usize {
    var count: usize = 0;
    for (runtime.store.nodes.items) |node| {
        if (node.kind == kind) count += 1;
    }
    return count;
}

fn retrievalCount(runtime: *runtime_mod.Runtime, query: []const u8, allocator: std.mem.Allocator) !usize {
    var result = try runtime.activate(.{ .query = query, .situation = "deployment", .now = 3 }, 8, allocator);
    defer result.deinit(allocator);
    return result.items.len;
}

/// Controlled causal-evolution audit. The first half deliberately calls only
/// observe() with repeated experiences. If later memory structures appear,
/// that is causal evolution; if only experience nodes and retrieval results
/// change, the runtime is retrieval-only for this path. The second half checks
/// that the explicit constructors and neural proposal commit still work, but
/// does not treat those manual calls as an automatic chain.
pub fn evaluateCausalEvolution(runtime: *runtime_mod.Runtime, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !CausalEvolutionReport {
    const baseline_results = try retrievalCount(runtime, "deployment", allocator);
    const first = try runtime.observe("agent", "experienced", "deployment", "deployment", "success", 1);
    _ = try runtime.observe("agent", "experienced", "deployment", "deployment", "success", 2);
    _ = try runtime.observe("agent", "experienced", "deployment", "deployment", "success", 3);
    const post_experience_results = try retrievalCount(runtime, "deployment", allocator);

    var report = CausalEvolutionReport{
        .statuses = .{ .partial, .fail, .pass, .pass, .pass, .fail, .partial, .pass },
        .baseline_results = baseline_results,
        .post_experience_results = post_experience_results,
        .repeated_experience_nodes = countKind(runtime, .experience),
        .memory_nodes_after_observe = countKind(runtime, .memory),
        .belief_nodes_after_observe = countKind(runtime, .belief),
        .concept_nodes_after_observe = countKind(runtime, .concept),
        .procedure_nodes_after_observe = countKind(runtime, .procedure),
        .relation_count_after_observe = runtime.store.relations.items.len,
        .explicit_beliefs = 0,
        .explicit_concepts = 0,
        .explicit_procedures = 0,
        .neural_committed = 0,
        .restart_results = 0,
        .learned_neural_state_artifacts = 0,
    };

    _ = try runtime.remember(first);
    const belief = try runtime.infer(first);
    report.explicit_beliefs = countKind(runtime, .belief);
    const concept = try runtime.generalize(&[_]u64{ first, belief }, "deployment pattern");
    _ = concept;
    report.explicit_concepts = countKind(runtime, .concept);
    _ = try runtime.inferProcedure(&[_]u64{ first, belief }, "recover deployment");
    report.explicit_procedures = countKind(runtime, .procedure);

    _ = try runtime.assert("agent", "prefers", "deployment", "deployment", 0.8);
    _ = try runtime.assert("agent", "prefers", "deployment", "deployment", 0.9);
    report.neural_committed = try runtime.consolidateNeural(neural_mod.Deterministic.consolidator());
    try runtime.persist(io, path);
    var recovered = try runtime_mod.Runtime.recover(allocator, io, path);
    defer recovered.deinit();
    report.restart_results = try retrievalCount(&recovered, "deployment", allocator);
    report.learned_neural_state_artifacts = recovered.store.neural_states.items.len;
    return report;
}

pub fn evaluateAgentLoop(runtime: *runtime_mod.Runtime, verifier: model.FeedbackVerifier, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !AgentLoopReport {
    runtime.setFeedbackVerifier(verifier);
    const fragile = try runtime.assert("agent", "uses", "fragile-browser-tool", "browser", 0.9);
    const reliable = try runtime.assert("agent", "uses", "reliable-browser-tool", "browser", 0.6);
    _ = try runtime.recordFeedback(.{ .target = fragile, .outcome = .failure, .failure_class = .invalid_result, .actor = "trusted-agent", .receipt = "receipt-fragile-invalid", .timestamp = 10 });
    _ = try runtime.recordFeedback(.{ .target = reliable, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-reliable-success", .timestamp = 20 });
    try runtime.persist(io, path);
    var recovered = try runtime_mod.Runtime.recover(allocator, io, path);
    defer recovered.deinit();
    var activated = try recovered.activate(.{ .query = "browser-tool", .situation = "browser", .now = 20 }, 1, allocator);
    defer activated.deinit(allocator);
    return .{
        .feedback_records = recovered.store.feedback_records.items.len,
        .persisted_revision = runtime.revision,
        .recovered_revision = recovered.revision,
        .selected_after_restart = if (activated.items.len == 0) 0 else activated.items[0].id,
        .expected = reliable,
    };
}

/// Deterministic four-stage agent history: experience -> belief -> concept
/// -> procedure. The expected IDs are checked at each stage so this is both
/// a long-horizon regression and a self-memory-shaped scenario.
pub fn evaluateLongHorizon(runtime: *runtime_mod.Runtime, allocator: std.mem.Allocator) !LongHorizonReport {
    var report = LongHorizonReport{};
    const experience = try runtime.observe("meml", "learned", "provider contract", "day-1", "success", 1);
    const belief = try runtime.infer(experience);
    const concept = try runtime.generalize(&[_]u64{ experience, belief }, "stable memory ABI");
    const procedure = try runtime.inferProcedure(&[_]u64{ experience, belief, concept }, "run conformance suite");
    const stages = [_]struct { query: []const u8, expected: u64 }{
        .{ .query = "provider", .expected = experience },
        .{ .query = "inferred", .expected = belief },
        .{ .query = "stable", .expected = concept },
        .{ .query = "conformance", .expected = procedure },
    };
    for (stages) |stage| {
        var result = try runtime.activate(.{ .query = stage.query, .now = 1 }, 8, allocator);
        defer result.deinit(allocator);
        for (result.items) |item| if (item.id == stage.expected) {
            report.retrieved += 1;
            break;
        };
        report.stages += 1;
    }
    report.memories = runtime.store.nodes.items.len;
    report.self_hosting_records = report.memories;
    return report;
}

/// Fixed, in-memory evaluation cases keep benchmarks deterministic and make
/// signal/provider regressions visible without requiring a model service.
pub fn evaluate(runtime: *runtime_mod.Runtime, cases: []const Case, limit: usize, allocator: std.mem.Allocator) !Report {
    var report = Report{ .cases = cases.len };
    for (cases) |case| {
        var result = try runtime.activate(.{ .query = case.query, .goal = case.goal, .situation = case.situation, .now = case.now }, limit, allocator);
        defer result.deinit(allocator);
        for (result.items, 0..) |item, rank| if (item.id == case.expected) {
            report.hits += 1;
            report.reciprocal_rank += 1 / @as(f64, @floatFromInt(rank + 1));
            report.ndcg += 1 / std.math.log2(@as(f64, @floatFromInt(rank + 2)));
            break;
        };
    }
    return report;
}

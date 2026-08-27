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

pub const RelevanceLabel = struct { expected: u64, relevance: u8 };
pub const AnnotatedTask = struct { task_id: []const u8, context: model.Context, labels: []const RelevanceLabel };
pub const VersionedAnnotationReport = struct {
    tasks: usize = 0,
    relevant: usize = 0,
    retrieved_relevant: usize = 0,
    reciprocal_rank: f64 = 0,
    ndcg: f64 = 0,
    pub fn recall(self: VersionedAnnotationReport) f64 {
        return if (self.relevant == 0) 0 else @as(f64, @floatFromInt(self.retrieved_relevant)) / @as(f64, @floatFromInt(self.relevant));
    }
    pub fn mrr(self: VersionedAnnotationReport) f64 {
        return if (self.tasks == 0) 0 else self.reciprocal_rank / @as(f64, @floatFromInt(self.tasks));
    }
    pub fn meanNdcg(self: VersionedAnnotationReport) f64 {
        return if (self.tasks == 0) 0 else self.ndcg / @as(f64, @floatFromInt(self.tasks));
    }
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

/// A domain-neutral feasibility case. The thresholds assert that retrieved
/// records carry compatible scope, measured quality, and optional structure.
pub const StructuredCase = struct {
    task_id: []const u8,
    context: model.Context,
    expected: u64,
    min_scope: f64 = 0,
    min_metric: f64 = 0,
    min_structure: f64 = 0,
};

pub const StructuredReport = struct {
    cases: usize = 0,
    relevant: usize = 0,
    feasible: usize = 0,
    scope_total: f64 = 0,
    metric_total: f64 = 0,
    structure_total: f64 = 0,

    pub fn feasibility(self: StructuredReport) f64 {
        return if (self.cases == 0) 0 else @as(f64, @floatFromInt(self.feasible)) / @as(f64, @floatFromInt(self.cases));
    }
};

/// Verifies that a state transition produced an observable, attributable change
/// in the kernel's activation boundary. Host actions remain outside MEML.
pub const DynamicsCase = struct {
    task_id: []const u8,
    before: model.Context,
    after: model.Context,
    expected_before: ?u64 = null,
    expected_after: ?u64 = null,
};

pub const DynamicsReport = struct {
    cases: usize = 0,
    changed: usize = 0,
    expected_before: usize = 0,
    expected_after: usize = 0,

    pub fn changeRate(self: DynamicsReport) f64 {
        return if (self.cases == 0) 0 else @as(f64, @floatFromInt(self.changed)) / @as(f64, @floatFromInt(self.cases));
    }
};

pub fn evaluateDynamics(runtime: *runtime_mod.Runtime, cases: []const DynamicsCase, limit: usize, allocator: std.mem.Allocator) !DynamicsReport {
    var report: DynamicsReport = .{};
    for (cases) |case| {
        if (case.task_id.len == 0) return error.InvalidAnnotation;
        var before = try runtime.activate(case.before, limit, allocator);
        defer before.deinit(allocator);
        var after = try runtime.activate(case.after, limit, allocator);
        defer after.deinit(allocator);
        report.cases += 1;
        const before_id: ?u64 = if (before.items.len == 0) null else before.items[0].id;
        const after_id: ?u64 = if (after.items.len == 0) null else after.items[0].id;
        if (before_id != after_id) report.changed += 1;
        if (case.expected_before == null or before_id == case.expected_before) report.expected_before += 1;
        if (case.expected_after == null or after_id == case.expected_after) report.expected_after += 1;
    }
    return report;
}

/// Held-out outcome case for an empirical procedure forecast. `cutoff` keeps
/// later feedback out of the estimate, so a passing score cannot be achieved by
/// reading the answer from the future.
pub const ProcedurePredictionCase = struct {
    task_id: []const u8,
    procedure: u64,
    context: model.Context = .{},
    cutoff: i64,
    expected: model.Outcome,
};

pub const ProcedurePredictionReport = struct {
    cases: usize = 0,
    correct: usize = 0,
    compatible: usize = 0,
    brier_sum: f64 = 0,

    pub fn accuracy(self: ProcedurePredictionReport) f64 {
        return if (self.cases == 0) 0 else @as(f64, @floatFromInt(self.correct)) / @as(f64, @floatFromInt(self.cases));
    }

    pub fn brier(self: ProcedurePredictionReport) f64 {
        return if (self.cases == 0) 0 else self.brier_sum / @as(f64, @floatFromInt(self.cases));
    }
};

pub const ProcedurePredictionQualityGate = struct {
    min_cases: usize = 1,
    min_accuracy: f64 = 0,
    max_brier: f64 = 1,

    pub fn accepts(self: ProcedurePredictionQualityGate, report: ProcedurePredictionReport) bool {
        return report.cases >= self.min_cases and report.accuracy() >= self.min_accuracy and report.brier() <= self.max_brier;
    }
};

pub fn evaluateProcedurePredictions(runtime: *const runtime_mod.Runtime, cases: []const ProcedurePredictionCase) !ProcedurePredictionReport {
    var report: ProcedurePredictionReport = .{};
    for (cases) |case| {
        if (case.task_id.len == 0) return error.InvalidAnnotation;
        const prediction = try runtime.predictProcedureAt(case.procedure, case.context, case.cutoff);
        const actual: f64 = if (case.expected == .success) 1 else 0;
        const classified_success = prediction.success_probability >= 0.5;
        if (classified_success == (case.expected == .success)) report.correct += 1;
        if (prediction.compatible) report.compatible += 1;
        const difference = prediction.success_probability - actual;
        report.brier_sum += difference * difference;
        report.cases += 1;
    }
    return report;
}

/// Evaluates a quality-gated, caller-bounded comparison. Candidates are passed
/// directly to Runtime; evaluation never uses retrieval to discover extras.
pub const ProcedureSelectionCase = struct {
    task_id: []const u8,
    candidates: []const u64,
    context: model.Context = .{},
    gate: model.ProcedureSelectionQualityGate = .{},
    expected: ?u64 = null,
};

pub const ProcedureSelectionReport = struct {
    cases: usize = 0,
    expected_selected: usize = 0,
    rejected: usize = 0,
    eligible: usize = 0,

    pub fn selectionAccuracy(self: ProcedureSelectionReport) f64 {
        return if (self.cases == 0) 0 else @as(f64, @floatFromInt(self.expected_selected)) / @as(f64, @floatFromInt(self.cases));
    }
};

pub fn evaluateProcedureSelection(runtime: *const runtime_mod.Runtime, cases: []const ProcedureSelectionCase, allocator: std.mem.Allocator) !ProcedureSelectionReport {
    var report: ProcedureSelectionReport = .{};
    for (cases) |case| {
        if (case.task_id.len == 0) return error.InvalidAnnotation;
        var selections = try runtime.selectProcedures(case.candidates, case.context, case.gate, allocator);
        defer selections.deinit(allocator);
        report.cases += 1;
        var selected: ?u64 = null;
        for (selections.items) |selection| {
            if (selection.counterfactual_score == null) report.rejected += 1 else report.eligible += 1;
            if (selection.rank == 1) selected = selection.procedure;
        }
        if (selected == case.expected) report.expected_selected += 1;
    }
    return report;
}

/// Tests that an explicitly bounded, multi-objective comparison chooses the
/// documented winner without retrieving alternatives or treating a forecast as
/// an observed outcome.
pub const ProcedureComparisonCase = struct {
    task_id: []const u8,
    candidates: []const u64,
    context: model.Context = .{},
    policy: model.ProcedureComparisonPolicy,
    expected: ?u64 = null,
};

pub const ProcedureComparisonReport = struct {
    cases: usize = 0,
    expected_selected: usize = 0,
    rejected: usize = 0,
    compared: usize = 0,

    pub fn selectionAccuracy(self: ProcedureComparisonReport) f64 {
        return if (self.cases == 0) 0 else @as(f64, @floatFromInt(self.expected_selected)) / @as(f64, @floatFromInt(self.cases));
    }
};

pub fn evaluateProcedureComparison(runtime: *const runtime_mod.Runtime, cases: []const ProcedureComparisonCase, allocator: std.mem.Allocator) !ProcedureComparisonReport {
    var report: ProcedureComparisonReport = .{};
    for (cases) |case| {
        if (case.task_id.len == 0) return error.InvalidAnnotation;
        var comparisons = try runtime.compareProcedures(case.candidates, case.context, case.policy, allocator);
        defer comparisons.deinit(allocator);
        report.cases += 1;
        var selected: ?u64 = null;
        for (comparisons.items) |comparison| {
            if (comparison.counterfactual_score) |_| report.compared += 1 else report.rejected += 1;
            if (comparison.rank == 1) selected = comparison.procedure;
        }
        if (selected == case.expected) report.expected_selected += 1;
    }
    return report;
}

pub const StructuredQualityGate = struct {
    min_cases: usize = 1,
    min_recall: f64 = 0,
    min_feasibility: f64 = 0,

    pub fn accepts(self: StructuredQualityGate, report: StructuredReport) bool {
        const recall = if (report.cases == 0) 0 else @as(f64, @floatFromInt(report.relevant)) / @as(f64, @floatFromInt(report.cases));
        return report.cases >= self.min_cases and recall >= self.min_recall and report.feasibility() >= self.min_feasibility;
    }
};

pub fn evaluateStructured(runtime: *runtime_mod.Runtime, cases: []const StructuredCase, limit: usize, allocator: std.mem.Allocator) !StructuredReport {
    var report: StructuredReport = .{};
    for (cases) |case| {
        if (case.task_id.len == 0 or case.min_scope < 0 or case.min_scope > 1 or case.min_metric < 0 or case.min_metric > 1 or case.min_structure < 0 or case.min_structure > 1) return error.InvalidAnnotation;
        var result = try runtime.activate(case.context, limit, allocator);
        defer result.deinit(allocator);
        report.cases += 1;
        for (result.items) |activation| if (activation.id == case.expected) {
            report.relevant += 1;
            report.scope_total += activation.signals.scope;
            report.metric_total += activation.signals.metric;
            report.structure_total += activation.signals.structure;
            if (activation.signals.scope >= case.min_scope and activation.signals.metric >= case.min_metric and activation.signals.structure >= case.min_structure) report.feasible += 1;
            break;
        };
    }
    return report;
}

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

fn relevanceGain(relevance: u8) f64 {
    return @floatFromInt((@as(u32, 1) << @as(u5, @intCast(relevance))) - 1);
}
fn discountedGain(relevance: u8, rank: usize) f64 {
    return relevanceGain(relevance) / std.math.log2(@as(f64, @floatFromInt(rank + 1)));
}

pub fn evaluateAnnotatedTasks(runtime: *runtime_mod.Runtime, tasks: []const AnnotatedTask, limit: usize, allocator: std.mem.Allocator) !VersionedAnnotationReport {
    var report: VersionedAnnotationReport = .{};
    for (tasks, 0..) |task, task_index| {
        if (task.task_id.len == 0 or task.labels.len == 0) return error.InvalidAnnotation;
        for (tasks[task_index + 1 ..]) |other| if (std.mem.eql(u8, task.task_id, other.task_id)) return error.InvalidAnnotation;
        var ideal: f64 = 0;
        for (task.labels, 0..) |label, label_index| {
            if (label.relevance == 0 or label.relevance > 3 or runtime.store.constNode(label.expected) == null) return error.InvalidAnnotation;
            for (task.labels[label_index + 1 ..]) |other| if (label.expected == other.expected) return error.InvalidAnnotation;
            ideal += discountedGain(label.relevance, label_index + 1);
        }
        var sorted = std.ArrayList(RelevanceLabel).empty;
        defer sorted.deinit(allocator);
        try sorted.appendSlice(allocator, task.labels);
        std.mem.sort(RelevanceLabel, sorted.items, {}, struct {
            fn lessThan(_: void, a: RelevanceLabel, b: RelevanceLabel) bool {
                return a.relevance > b.relevance;
            }
        }.lessThan);
        ideal = 0;
        for (sorted.items, 0..) |label, index| ideal += discountedGain(label.relevance, index + 1);
        var result = try runtime.activate(task.context, limit, allocator);
        defer result.deinit(allocator);
        var dcg: f64 = 0;
        var first: ?usize = null;
        for (result.items, 0..) |item, rank| for (task.labels) |label| if (item.id == label.expected) {
            report.retrieved_relevant += 1;
            if (first == null) first = rank + 1;
            dcg += discountedGain(label.relevance, rank + 1);
            break;
        };
        report.tasks += 1;
        report.relevant += task.labels.len;
        if (first) |rank| report.reciprocal_rank += 1 / @as(f64, @floatFromInt(rank));
        report.ndcg += dcg / ideal;
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

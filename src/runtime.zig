const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const backend_mod = @import("backend.zig");
const persistence = @import("persistence.zig");
const index_journal = @import("index_journal.zig");
const storage_mod = @import("storage.zig");
const retrieval = @import("retrieval.zig");
const signals_mod = @import("signals.zig");
const neural_mod = @import("neural.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    store: store_mod.Store,
    next_id: u64 = 1,
    clock: i64 = 0,
    revision: u64 = 0,
    index_checkpoint_revision: u64 = 0,
    backend_state: backend_mod.Owned,
    backend: backend_mod.Backend,
    signal_pipeline: signals_mod.Pipeline,
    last_consolidated_experiences: usize = 0,
    last_consolidation_policy: u8 = 0,
    pending_experiences: usize = 0,
    experience_groups: std.AutoHashMap(u64, usize),
    pending_groups: std.AutoHashMap(u64, void),
    auto_consolidation_enabled: bool = false,
    auto_consolidation_policy: ConsolidationPolicy = .{},
    feedback_verifier: ?model.FeedbackVerifier = null,
    feedback_policy: model.FeedbackPolicy = .{},

    pub const ConsolidationReport = struct {
        scanned_experiences: usize = 0,
        pending_experiences: usize = 0,
        skipped: bool = false,
        memories_created: usize = 0,
        beliefs_created: usize = 0,
        concepts_created: usize = 0,
        procedures_created: usize = 0,
        neural_artifacts_created: usize = 0,
    };

    pub const ConsolidationPolicy = struct {
        repeat_threshold: usize = 2,
        procedure_success_ratio: f64 = 0.75,
        auto_consolidate: bool = true,
        enable_memory: bool = true,
        enable_belief: bool = true,
        enable_concept: bool = true,
        enable_procedure: bool = true,
        enable_neural: bool = true,
        abort_after_artifacts: ?usize = null,

        fn key(self: ConsolidationPolicy) u8 {
            return @as(u8, @intFromBool(self.enable_memory)) | (@as(u8, @intFromBool(self.enable_belief)) << 1) |
                (@as(u8, @intFromBool(self.enable_concept)) << 2) | (@as(u8, @intFromBool(self.enable_procedure)) << 3) |
                (@as(u8, @intFromBool(self.enable_neural)) << 4);
        }
    };

    pub const Transaction = struct {
        runtime: *Runtime,
        store: store_mod.Store,
        next_id: u64,
        clock: i64,
        revision: u64,
        index_checkpoint_revision: u64,
        last_consolidated_experiences: usize,
        last_consolidation_policy: u8,
        pending_experiences: usize,
        experience_groups: std.AutoHashMap(u64, usize),
        pending_groups: std.AutoHashMap(u64, void),
        signal_provider_count: usize,
        auto_consolidation_enabled: bool,
        auto_consolidation_policy: ConsolidationPolicy,
        feedback_verifier: ?model.FeedbackVerifier,
        feedback_policy: model.FeedbackPolicy,
        committed: bool = false,

        pub fn commit(self: *Transaction) void {
            self.committed = true;
        }

        pub fn rollback(self: *Transaction) !void {
            if (self.committed) return;
            const runtime = self.runtime;
            runtime.store.deinit();
            runtime.store = self.store;
            self.store = store_mod.Store.init(runtime.allocator);
            runtime.next_id = self.next_id;
            runtime.clock = self.clock;
            runtime.revision = self.revision;
            runtime.index_checkpoint_revision = self.index_checkpoint_revision;
            runtime.last_consolidated_experiences = self.last_consolidated_experiences;
            runtime.last_consolidation_policy = self.last_consolidation_policy;
            runtime.pending_experiences = self.pending_experiences;
            runtime.experience_groups.deinit();
            runtime.experience_groups = self.experience_groups;
            self.experience_groups = std.AutoHashMap(u64, usize).init(runtime.allocator);
            runtime.pending_groups.deinit();
            runtime.pending_groups = self.pending_groups;
            self.pending_groups = std.AutoHashMap(u64, void).init(runtime.allocator);
            runtime.signal_pipeline.providers.items.len = self.signal_provider_count;
            runtime.auto_consolidation_enabled = self.auto_consolidation_enabled;
            runtime.auto_consolidation_policy = self.auto_consolidation_policy;
            runtime.feedback_verifier = self.feedback_verifier;
            try runtime.backend.reset(&runtime.store);
        }

        pub fn deinit(self: *Transaction) void {
            self.store.deinit();
            self.experience_groups.deinit();
            self.pending_groups.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Runtime {
        const state = backend_mod.Owned.init(allocator, .symbolic);
        return .{ .allocator = allocator, .store = store_mod.Store.init(allocator), .backend_state = state, .backend = state.provider, .signal_pipeline = signals_mod.Pipeline.init(allocator), .experience_groups = std.AutoHashMap(u64, usize).init(allocator), .pending_groups = std.AutoHashMap(u64, void).init(allocator) };
    }

    /// Begins an in-memory transaction for source-program execution. Direct
    /// Runtime API calls retain their existing immediate-mutation semantics.
    pub fn beginTransaction(self: *Runtime) !Transaction {
        var experience_groups = std.AutoHashMap(u64, usize).init(self.allocator);
        errdefer experience_groups.deinit();
        var experience_it = self.experience_groups.iterator();
        while (experience_it.next()) |entry| try experience_groups.put(entry.key_ptr.*, entry.value_ptr.*);
        var pending_groups = std.AutoHashMap(u64, void).init(self.allocator);
        errdefer pending_groups.deinit();
        var pending_it = self.pending_groups.iterator();
        while (pending_it.next()) |entry| try pending_groups.put(entry.key_ptr.*, {});
        return .{
            .runtime = self,
            .store = try self.store.clone(self.allocator),
            .next_id = self.next_id,
            .clock = self.clock,
            .revision = self.revision,
            .index_checkpoint_revision = self.index_checkpoint_revision,
            .last_consolidated_experiences = self.last_consolidated_experiences,
            .last_consolidation_policy = self.last_consolidation_policy,
            .pending_experiences = self.pending_experiences,
            .experience_groups = experience_groups,
            .pending_groups = pending_groups,
            .signal_provider_count = self.signal_pipeline.providers.items.len,
            .auto_consolidation_enabled = self.auto_consolidation_enabled,
            .auto_consolidation_policy = self.auto_consolidation_policy,
            .feedback_verifier = self.feedback_verifier,
            .feedback_policy = self.feedback_policy,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.store.deinit();
        self.backend_state.deinit();
        self.signal_pipeline.deinit();
        self.experience_groups.deinit();
        self.pending_groups.deinit();
    }

    fn ownedNode(self: *Runtime, kind: model.Kind, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, confidence: f64, timestamp: i64) !model.Node {
        const subject_copy = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(subject_copy);
        const predicate_copy = try self.allocator.dupe(u8, predicate);
        errdefer self.allocator.free(predicate_copy);
        const object_copy = try self.allocator.dupe(u8, object);
        errdefer self.allocator.free(object_copy);
        const context_copy = try self.allocator.dupe(u8, context);
        errdefer self.allocator.free(context_copy);
        const result_copy = try self.allocator.dupe(u8, result);
        errdefer self.allocator.free(result_copy);
        return .{ .id = self.next_id, .kind = kind, .subject = subject_copy, .predicate = predicate_copy, .object = object_copy, .context = context_copy, .result = result_copy, .timestamp = timestamp, .confidence = confidence, .strength = confidence };
    }

    fn make(self: *Runtime, kind: model.Kind, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, confidence: f64, timestamp: i64) !u64 {
        if (!std.math.isFinite(confidence) or confidence < 0 or confidence > 1) return error.InvalidConfidence;
        const entry = try self.ownedNode(kind, subject, predicate, object, context, result, confidence, timestamp);
        const id = self.store.add(entry) catch |err| {
            store_mod.Store.deinitNode(self.allocator, entry);
            return err;
        };
        self.backend.upsert(&self.store, id) catch |err| {
            store_mod.Store.deinitNode(self.allocator, self.store.nodes.pop().?);
            return err;
        };
        self.next_id += 1;
        return id;
    }
    pub fn observe(self: *Runtime, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, timestamp: i64) !u64 {
        self.clock = @max(self.clock, timestamp);
        const id = try self.make(.experience, subject, predicate, object, context, result, 0.5, timestamp);
        self.pending_experiences += 1;
        const key = fingerprint(subject, predicate, object, context, result);
        const entry = try self.experience_groups.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        try self.store.recordFingerprint(key, id);
        try self.pending_groups.put(key, {});
        if (self.auto_consolidation_enabled) _ = try self.consolidatePendingAtomic(self.auto_consolidation_policy);
        return id;
    }

    /// Enable event-triggered consolidation for subsequent observations.
    /// The default Runtime remains observe-only so callers explicitly control
    /// when durable derived structure is created.
    pub fn enableAutoConsolidation(self: *Runtime, policy: ConsolidationPolicy) void {
        self.auto_consolidation_policy = policy;
        self.auto_consolidation_enabled = true;
    }

    pub fn disableAutoConsolidation(self: *Runtime) void {
        self.auto_consolidation_enabled = false;
    }
    pub fn remember(self: *Runtime, id: u64) !u64 {
        const node = self.store.node(id) orelse return error.UnknownNode;
        const out = try self.make(.memory, node.subject, node.predicate, node.object, node.context, node.result, 0.6, self.clock);
        try self.store.link(.{ .from = out, .to = id, .kind = .derived_from, .weight = 1 });
        return out;
    }
    pub fn assert(self: *Runtime, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, confidence: f64) !u64 {
        return self.make(.claim, subject, predicate, object, context, "", confidence, self.clock);
    }

    /// Adds an explicit semantic relation after validating both endpoint IDs and
    /// its normalized weight. Source programs use this instead of Store directly.
    pub fn link(self: *Runtime, from: u64, kind: model.RelationKind, to: u64, weight: f64) !void {
        if (self.store.constNode(from) == null or self.store.constNode(to) == null) return error.UnknownNode;
        if (!std.math.isFinite(weight) or weight < 0 or weight > 1) return error.InvalidRelationWeight;
        try self.store.link(.{ .from = from, .to = to, .kind = kind, .weight = weight });
    }

    /// Removes one explicit relation. An absent edge is an error so source
    /// lifecycle operations cannot silently claim a state transition occurred.
    pub fn unlink(self: *Runtime, from: u64, kind: model.RelationKind, to: u64) !void {
        if (self.store.constNode(from) == null or self.store.constNode(to) == null) return error.UnknownNode;
        if (!self.store.unlink(from, kind, to)) return error.RelationNotFound;
    }
    pub fn support(self: *Runtime, from: u64, to: u64, weight: f64) !void {
        try self.link(from, .supports, to, weight);
        if (self.store.node(to)) |node| if (node.kind == .belief) {
            node.support_count += 1;
            node.last_confirmed_at = self.clock;
            if (node.belief_state == .contested and node.support_count > node.contradiction_count) node.belief_state = .active;
        };
    }
    pub fn contradict(self: *Runtime, from: u64, to: u64) !void {
        try self.link(from, .contradicts, to, 1);
        if (self.store.node(to)) |node| if (node.kind == .belief) {
            node.contradiction_count += 1;
            node.last_contradicted_at = self.clock;
            node.belief_state = .contested;
        };
    }

    /// Configures the host-owned verifier for external tool receipts. The
    /// runtime never accepts a feedback outcome until this verifier succeeds.
    pub fn setFeedbackVerifier(self: *Runtime, verifier: model.FeedbackVerifier) void {
        self.feedback_verifier = verifier;
    }

    pub fn clearFeedbackVerifier(self: *Runtime) void {
        self.feedback_verifier = null;
    }

    pub fn setFeedbackPolicy(self: *Runtime, policy: model.FeedbackPolicy) !void {
        const values = [_]f64{ policy.success_increment, policy.timeout_multiplier, policy.transport_multiplier, policy.tool_error_multiplier, policy.invalid_result_multiplier, policy.unknown_multiplier, policy.neutral_multiplier };
        for (values) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidFeedbackPolicy;
        self.feedback_policy = policy;
    }

    fn feedbackPenalty(self: *const Runtime, class: model.FailureClass) f64 {
        return switch (class) {
            .timeout => self.feedback_policy.timeout_multiplier,
            .transport => self.feedback_policy.transport_multiplier,
            .tool_error => self.feedback_policy.tool_error_multiplier,
            .invalid_result => self.feedback_policy.invalid_result_multiplier,
            .policy_denied, .unauthorized, .cancelled => self.feedback_policy.neutral_multiplier,
            .unknown => self.feedback_policy.unknown_multiplier,
            .none => self.feedback_policy.neutral_multiplier,
        };
    }

    /// Applies a verified external result. Verification happens before any
    /// node, relation, clock, confidence, or audit-record mutation; later
    /// allocation failures restore the complete pre-feedback runtime state.
    pub fn recordFeedback(self: *Runtime, input: model.FeedbackInput) !u64 {
        const verifier = self.feedback_verifier orelse return error.FeedbackVerifierRequired;
        const target = self.store.constNode(input.target) orelse return error.UnknownNode;
        if (target.kind == .evidence) return error.InvalidFeedbackTarget;
        if (input.actor.len == 0 or input.receipt.len == 0 or (input.outcome == .success and input.failure_class != .none) or (input.outcome == .failure and input.failure_class == .none)) return error.InvalidFeedback;
        try verifier.verify(input);
        var transaction = try self.beginTransaction();
        defer transaction.deinit();
        const evidence = self.applyFeedback(input) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return evidence;
    }

    fn applyFeedback(self: *Runtime, input: model.FeedbackInput) !u64 {
        const target = self.store.constNode(input.target) orelse return error.UnknownNode;
        self.clock = @max(self.clock, input.timestamp);
        const result = if (input.outcome == .success) "success" else @tagName(input.failure_class);
        const evidence = try self.make(.evidence, target.subject, target.predicate, target.object, target.context, result, 0.5, input.timestamp);
        try self.store.recordFeedback(.{ .evidence = evidence, .target = input.target, .outcome = input.outcome, .failure_class = input.failure_class, .actor = input.actor, .receipt = input.receipt });
        if (input.outcome == .success) {
            try self.support(evidence, input.target, 1);
            if (self.store.node(input.target)) |node| {
                node.confidence = @min(1, node.confidence + self.feedback_policy.success_increment);
                node.strength = @min(1, node.strength + self.feedback_policy.success_increment);
            }
        } else {
            try self.contradict(evidence, input.target);
            const penalty = self.feedbackPenalty(input.failure_class);
            if (self.store.node(input.target)) |node| {
                node.confidence *= penalty;
                node.strength *= penalty;
            }
        }
        return evidence;
    }

    pub fn infer(self: *Runtime, id: u64) !u64 {
        const node = self.store.node(id) orelse return error.UnknownNode;
        return self.make(.belief, node.subject, node.predicate, node.object, node.context, "inferred", node.confidence, self.clock);
    }

    pub fn setBeliefState(self: *Runtime, id: u64, state: model.BeliefState) !void {
        const node = self.store.node(id) orelse return error.UnknownNode;
        if (node.kind != .belief) return error.NotBelief;
        node.belief_state = state;
    }

    pub fn supersedeBelief(self: *Runtime, old_id: u64, replacement_id: u64) !void {
        const old = self.store.node(old_id) orelse return error.UnknownNode;
        const replacement = self.store.node(replacement_id) orelse return error.UnknownNode;
        if (old.kind != .belief or replacement.kind != .belief) return error.NotBelief;
        old.belief_state = .superseded;
        try self.store.link(.{ .from = replacement_id, .to = old_id, .kind = .derived_from, .weight = 1 });
    }
    pub fn generalize(self: *Runtime, ids: []const u64, concept: []const u8) !u64 {
        if (ids.len == 0) return error.EmptyEvidence;
        const first = self.store.node(ids[0]) orelse return error.UnknownNode;
        const out = try self.make(.concept, first.subject, "generalizes", concept, first.context, "", 0.7, self.clock);
        for (ids) |id| try self.store.link(.{ .from = out, .to = id, .kind = .generalizes, .weight = 1 });
        return out;
    }
    pub fn inferProcedure(self: *Runtime, ids: []const u64, name: []const u8) !u64 {
        if (ids.len == 0) return error.EmptyEvidence;
        const first = self.store.node(ids[0]) orelse return error.UnknownNode;
        const out = try self.make(.procedure, first.subject, "performs", name, first.context, "learned sequence", 0.7, self.clock);
        for (ids, 0..) |id, i| try self.store.link(.{ .from = out, .to = id, .kind = .follows, .weight = 1 / @as(f64, @floatFromInt(i + 1)) });
        return out;
    }
    pub fn consolidate(self: *Runtime) !void {
        var ids = std.ArrayList(u64).empty;
        defer ids.deinit(self.allocator);
        for (self.store.nodes.items) |node| if (node.kind == .claim) try ids.append(self.allocator, node.id);
        if (ids.items.len >= 2) _ = try self.generalize(ids.items, "reliable recurring preference");
    }
    pub fn activate(self: *Runtime, context: model.Context, limit: usize, allocator: std.mem.Allocator) !std.ArrayList(model.Activation) {
        const result = try retrieval.runWithPipeline(&self.store, self.backend, context, limit, allocator, &self.signal_pipeline);
        return result.items;
    }
    pub fn activateWithStats(self: *Runtime, context: model.Context, limit: usize, allocator: std.mem.Allocator) !retrieval.Result {
        return retrieval.runWithPipeline(&self.store, self.backend, context, limit, allocator, &self.signal_pipeline);
    }
    pub fn addSignalProvider(self: *Runtime, provider: signals_mod.Provider) !void {
        try self.signal_pipeline.append(provider);
    }

    /// Stores versioned calibration parameters for the transparent reference
    /// provider. Values are bounded to keep external scores well-defined.
    pub fn setSignalCalibration(self: *Runtime, weight: f64, bias: f64) !void {
        if (!std.math.isFinite(weight) or !std.math.isFinite(bias) or weight < 0 or weight > 4 or bias < -1 or bias > 1) return error.InvalidSignalCalibration;
        try self.store.upsertLearnedSignal("calibrated", weight, bias, 1);
    }

    pub fn addCalibratedSignalProvider(self: *Runtime) !void {
        try self.addSignalProvider(signals_mod.Calibrated.provider());
    }

    pub fn consolidateNeural(self: *Runtime, consolidator: neural_mod.Consolidator) !usize {
        var proposals = try consolidator.propose(&self.store, self.allocator);
        defer proposals.deinit(self.allocator);
        var committed: usize = 0;
        for (proposals.items) |proposal| {
            var already_committed = false;
            for (self.store.nodes.items) |node| {
                if (node.kind != .belief or !std.mem.eql(u8, node.result, "neural consolidation")) continue;
                if (self.hasRelation(node.id, proposal.source_a, .derived_from) and self.hasRelation(node.id, proposal.source_b, .derived_from)) {
                    already_committed = true;
                    break;
                }
            }
            for (self.store.consolidations.items) |record| {
                if (record.source_a == proposal.source_a and record.source_b == proposal.source_b and std.mem.eql(u8, record.rule, consolidator.name())) {
                    already_committed = true;
                    break;
                }
            }
            if (already_committed) continue;
            const id = try self.make(.belief, proposal.subject, proposal.predicate, proposal.object, proposal.context, proposal.result, proposal.confidence, self.clock);
            try self.store.link(.{ .from = id, .to = proposal.source_a, .kind = .derived_from, .weight = proposal.confidence });
            try self.store.link(.{ .from = id, .to = proposal.source_b, .kind = .derived_from, .weight = proposal.confidence });
            try self.store.recordConsolidation(.{ .artifact = id, .rule = try self.allocator.dupe(u8, consolidator.name()), .version = 1, .source_a = proposal.source_a, .source_b = proposal.source_b });
            try self.store.upsertNeuralState(.{ .artifact = id, .activation_count = 1, .strength = proposal.confidence, .version = 1 });
            committed += 1;
        }
        return committed;
    }

    fn hasRelation(self: *const Runtime, from: u64, to: u64, kind: model.RelationKind) bool {
        for (self.store.relations.items) |relation| {
            if (relation.from == from and relation.to == to and relation.kind == kind) return true;
        }
        return false;
    }

    fn sameContent(a: model.Node, b: model.Node) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.subject, b.subject) and
            std.mem.eql(u8, a.predicate, b.predicate) and std.mem.eql(u8, a.object, b.object) and
            std.mem.eql(u8, a.context, b.context) and std.mem.eql(u8, a.result, b.result);
    }

    fn sameSemantic(a: model.Node, b: model.Node) bool {
        return std.mem.eql(u8, a.subject, b.subject) and std.mem.eql(u8, a.predicate, b.predicate) and
            std.mem.eql(u8, a.object, b.object) and std.mem.eql(u8, a.context, b.context);
    }

    fn fingerprint(subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8) u64 {
        var seed: u64 = 0;
        seed = std.hash.Wyhash.hash(seed, subject);
        seed = std.hash.Wyhash.hash(seed, predicate);
        seed = std.hash.Wyhash.hash(seed, object);
        seed = std.hash.Wyhash.hash(seed, context);
        return std.hash.Wyhash.hash(seed, result);
    }

    fn nodeFingerprint(node: model.Node) u64 {
        return fingerprint(node.subject, node.predicate, node.object, node.context, node.result);
    }

    fn recordRule(self: *Runtime, artifact: u64, rule: []const u8, source_a: u64, source_b: u64) !void {
        try self.store.recordConsolidation(.{ .artifact = artifact, .rule = try self.allocator.dupe(u8, rule), .version = 1, .source_a = source_a, .source_b = source_b });
    }

    fn beginConsolidation(self: *Runtime) !Transaction {
        return self.beginTransaction();
    }

    fn maybeAbort(policy: ConsolidationPolicy, report: ConsolidationReport) !void {
        if (policy.abort_after_artifacts) |limit| {
            const artifacts = report.memories_created + report.beliefs_created + report.concepts_created + report.procedures_created + report.neural_artifacts_created;
            if (artifacts >= limit) return error.InjectedConsolidationFailure;
        }
    }

    pub fn consolidateAllAtomic(self: *Runtime, policy: ConsolidationPolicy) !ConsolidationReport {
        var transaction = try self.beginConsolidation();
        defer transaction.deinit();
        const report = self.consolidateWithPolicy(policy) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return report;
    }

    pub fn consolidatePendingAtomic(self: *Runtime, policy: ConsolidationPolicy) !ConsolidationReport {
        var transaction = try self.beginConsolidation();
        defer transaction.deinit();
        const report = self.consolidatePending(policy) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return report;
    }

    /// Run the minimal automatic causal pipeline. Repeated experiences become
    /// persistent memory nodes, beliefs, concepts, procedures, and deterministic
    /// neural artifacts. Re-running is idempotent for the derived kernel nodes.
    pub fn consolidateAll(self: *Runtime) !ConsolidationReport {
        return self.consolidateWithPolicy(.{});
    }

    pub fn consolidateWithPolicy(self: *Runtime, policy: ConsolidationPolicy) !ConsolidationReport {
        return self.consolidateWithPolicyScoped(policy, null);
    }

    fn consolidateWithPolicyScoped(self: *Runtime, policy: ConsolidationPolicy, scope: ?[]const u64) !ConsolidationReport {
        var report = ConsolidationReport{};
        var experiences = std.ArrayList(u64).empty;
        defer experiences.deinit(self.allocator);
        if (scope) |ids| {
            for (ids) |id| try experiences.append(self.allocator, id);
        } else {
            for (self.store.nodes.items) |node| if (node.kind == .experience) try experiences.append(self.allocator, node.id);
        }
        report.scanned_experiences = experiences.items.len;
        report.pending_experiences = self.pending_experiences;
        if (scope == null and experiences.items.len == self.last_consolidated_experiences and policy.key() == self.last_consolidation_policy) {
            report.skipped = true;
            return report;
        }

        if (policy.enable_memory) {
            for (experiences.items) |experience_id| {
                const experience = self.store.constNode(experience_id).?;
                var memory_id: ?u64 = null;
                for (self.store.nodes.items) |node| {
                    if (node.kind == .memory and sameSemantic(node, experience.*) and self.hasRelation(node.id, experience_id, .derived_from)) {
                        memory_id = node.id;
                        break;
                    }
                }
                if (memory_id == null) {
                    const created = try self.make(.memory, experience.subject, experience.predicate, experience.object, experience.context, experience.result, 0.6, self.clock);
                    try self.store.link(.{ .from = created, .to = experience_id, .kind = .derived_from, .weight = 1 });
                    try self.recordRule(created, "experience-to-memory", experience_id, 0);
                    memory_id = created;
                    report.memories_created += 1;
                }
            }
        }
        try maybeAbort(policy, report);

        var i: usize = 0;
        while (i < experiences.items.len) : (i += 1) {
            const left = self.store.constNode(experiences.items[i]).?;
            const group_count = self.experience_groups.get(nodeFingerprint(left.*)) orelse 0;
            if (group_count < policy.repeat_threshold) continue;
            var repetitions: usize = 0;
            for (experiences.items[i..]) |candidate_id| {
                const candidate = self.store.constNode(candidate_id).?;
                if (std.mem.eql(u8, left.subject, candidate.subject) and std.mem.eql(u8, left.predicate, candidate.predicate) and
                    std.mem.eql(u8, left.object, candidate.object) and std.mem.eql(u8, left.context, candidate.context) and
                    std.mem.eql(u8, left.result, candidate.result)) repetitions += 1;
            }
            if (!policy.enable_belief or repetitions < policy.repeat_threshold) continue;
            var belief_id: ?u64 = null;
            for (self.store.nodes.items) |node| if (node.kind == .belief and std.mem.eql(u8, node.result, "consolidated repetition") and sameSemantic(node, left.*)) {
                belief_id = node.id;
                break;
            };
            if (belief_id == null) {
                belief_id = try self.make(.belief, left.subject, left.predicate, left.object, left.context, "consolidated repetition", @min(1, 0.5 + @as(f64, @floatFromInt(repetitions)) * 0.1), self.clock);
                if (self.store.node(belief_id.?)) |belief| {
                    belief.support_count = @intCast(repetitions);
                    belief.last_confirmed_at = self.clock;
                }
                try self.recordRule(belief_id.?, "repeated-experience-to-belief", experiences.items[i], experiences.items[i + repetitions - 1]);
                report.beliefs_created += 1;
            } else if (self.store.node(belief_id.?)) |belief| {
                const updated = @min(1, belief.confidence + 0.05 * @as(f64, @floatFromInt(repetitions)));
                belief.confidence = updated;
                belief.strength = @min(1, belief.strength + 0.05);
                belief.support_count += @intCast(repetitions);
                belief.last_confirmed_at = self.clock;
                if (belief.belief_state == .contested and belief.support_count > belief.contradiction_count) belief.belief_state = .active;
            }
            for (self.store.nodes.items) |node| if (node.kind == .memory and sameSemantic(node, left.*) and !self.hasRelation(belief_id.?, node.id, .derived_from)) {
                try self.store.link(.{ .from = belief_id.?, .to = node.id, .kind = .derived_from, .weight = 1 });
            };
        }
        try maybeAbort(policy, report);

        var beliefs = std.ArrayList(u64).empty;
        defer beliefs.deinit(self.allocator);
        for (self.store.nodes.items) |node| if (node.kind == .belief and std.mem.eql(u8, node.result, "consolidated repetition")) try beliefs.append(self.allocator, node.id);
        for (beliefs.items, 0..) |left_id, left_index| {
            const left = self.store.constNode(left_id).?;
            for (beliefs.items[left_index + 1 ..]) |right_id| {
                const right = self.store.constNode(right_id).?;
                if (std.mem.eql(u8, left.subject, right.subject) and std.mem.eql(u8, left.predicate, right.predicate) and
                    !std.mem.eql(u8, left.object, right.object))
                {
                    const same_context = std.mem.eql(u8, left.context, right.context);
                    if (!self.hasRelation(left.id, right.id, .contradicts)) {
                        try self.store.link(.{ .from = left.id, .to = right.id, .kind = .contradicts, .weight = 1 });
                        if (same_context) {
                            if (self.store.node(left.id)) |node| {
                                node.confidence *= 0.8;
                                node.contradiction_count += 1;
                                node.last_contradicted_at = self.clock;
                                node.belief_state = .contested;
                            }
                            if (self.store.node(right.id)) |node| {
                                node.confidence *= 0.8;
                                node.contradiction_count += 1;
                                node.last_contradicted_at = self.clock;
                                node.belief_state = .contested;
                            }
                        }
                    }
                }
            }
        }
        if (policy.enable_concept and beliefs.items.len >= 2) {
            const first = self.store.constNode(beliefs.items[0]).?;
            const label = try std.fmt.allocPrint(self.allocator, "generalized {s}", .{first.predicate});
            defer self.allocator.free(label);
            var concept_id: ?u64 = null;
            for (self.store.nodes.items) |node| {
                if (node.kind == .concept and std.mem.eql(u8, node.object, label)) concept_id = node.id;
            }
            if (concept_id == null) {
                concept_id = try self.make(.concept, first.subject, "generalizes", label, first.context, "automatic generalization", 0.7, self.clock);
                try self.recordRule(concept_id.?, "beliefs-to-concept", beliefs.items[0], beliefs.items[1]);
                report.concepts_created = 1;
            }
            for (beliefs.items) |belief| if (!self.hasRelation(concept_id.?, belief, .generalizes)) try self.store.link(.{ .from = concept_id.?, .to = belief, .kind = .generalizes, .weight = 1 });
        }
        try maybeAbort(policy, report);

        var procedure_experiences = std.ArrayList(u64).empty;
        defer procedure_experiences.deinit(self.allocator);
        if (policy.enable_procedure) {
            for (self.store.fingerprint_members.items) |member| try procedure_experiences.append(self.allocator, member.experience);
            if (procedure_experiences.items.len == 0) for (experiences.items) |id| try procedure_experiences.append(self.allocator, id);
        }
        if (policy.enable_procedure and procedure_experiences.items.len >= 2) {
            var order_index: usize = 1;
            while (order_index < procedure_experiences.items.len) : (order_index += 1) {
                var position = order_index;
                while (position > 0 and self.store.constNode(procedure_experiences.items[position - 1]).?.timestamp > self.store.constNode(procedure_experiences.items[position]).?.timestamp) {
                    const temp = procedure_experiences.items[position - 1];
                    procedure_experiences.items[position - 1] = procedure_experiences.items[position];
                    procedure_experiences.items[position] = temp;
                    position -= 1;
                }
            }
            const first = self.store.constNode(procedure_experiences.items[0]).?;
            const name = try std.fmt.allocPrint(self.allocator, "learned {s} sequence", .{first.predicate});
            defer self.allocator.free(name);
            var procedure_id: ?u64 = null;
            for (self.store.nodes.items) |node| {
                if (node.kind == .procedure and std.mem.eql(u8, node.object, name)) procedure_id = node.id;
            }
            var success_count: usize = 0;
            for (procedure_experiences.items) |experience_id| {
                if (std.mem.eql(u8, self.store.constNode(experience_id).?.result, "success")) success_count += 1;
            }
            const success_ratio = @as(f64, @floatFromInt(success_count)) / @as(f64, @floatFromInt(procedure_experiences.items.len));
            if (success_ratio >= policy.procedure_success_ratio) {
                if (procedure_id == null) {
                    procedure_id = try self.make(.procedure, first.subject, "performs", name, first.context, "automatic sequence", 0.7, self.clock);
                    try self.recordRule(procedure_id.?, "ordered-successful-experiences-to-procedure", procedure_experiences.items[0], procedure_experiences.items[procedure_experiences.items.len - 1]);
                    report.procedures_created = 1;
                }
                for (procedure_experiences.items, 0..) |experience, index| if (!self.hasRelation(procedure_id.?, experience, .follows)) try self.store.link(.{ .from = procedure_id.?, .to = experience, .kind = .follows, .weight = 1 / @as(f64, @floatFromInt(index + 1)) });
            }
        }
        try maybeAbort(policy, report);
        if (policy.enable_neural) report.neural_artifacts_created = try self.consolidateNeural(neural_mod.Deterministic.consolidator());
        try maybeAbort(policy, report);
        self.last_consolidated_experiences = experiences.items.len;
        self.last_consolidation_policy = policy.key();
        self.pending_experiences = 0;
        self.pending_groups.clearRetainingCapacity();
        return report;
    }

    pub fn consolidatePending(self: *Runtime, policy: ConsolidationPolicy) !ConsolidationReport {
        var ids = std.ArrayList(u64).empty;
        defer ids.deinit(self.allocator);
        var group_it = self.pending_groups.keyIterator();
        while (group_it.next()) |key| {
            for (self.store.fingerprint_members.items) |member| {
                if (member.fingerprint == key.*) try ids.append(self.allocator, member.experience);
            }
        }
        if (ids.items.len == 0) return ConsolidationReport{ .skipped = true };
        const report = try self.consolidateWithPolicyScoped(policy, ids.items);
        self.pending_groups.clearRetainingCapacity();
        self.pending_experiences = 0;
        return report;
    }

    pub fn observeAndConsolidate(self: *Runtime, policy: ConsolidationPolicy, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, timestamp: i64) !ConsolidationReport {
        _ = try self.observe(subject, predicate, object, context, result, timestamp);
        return if (policy.auto_consolidate) self.consolidatePending(policy) else ConsolidationReport{};
    }
    pub fn useVectorBackend(self: *Runtime) !void {
        self.backend_state.deinit();
        self.backend_state = backend_mod.Owned.init(self.allocator, .vector);
        self.backend = self.backend_state.provider;
        try self.backend.reset(&self.store);
    }
    pub fn useGraphBackend(self: *Runtime) !void {
        self.backend_state.deinit();
        self.backend_state = backend_mod.Owned.init(self.allocator, .graph);
        self.backend = self.backend_state.provider;
        try self.backend.reset(&self.store);
    }
    /// Default persistence is journaled and atomic. The raw persistence writer
    /// remains internal to the storage protocol and is not a Runtime API.
    pub fn persist(self: *Runtime, io: std.Io, path: []const u8) !void {
        try self.persistAtomic(io, path);
    }

    /// Persists semantic state through a caller-supplied provider. Provider
    /// indexes remain derived and must be rebuilt from the recovered records.
    pub fn persistTo(self: *Runtime, provider: storage_mod.Provider, io: std.Io, path: []const u8) !void {
        const next_revision = std.math.add(u64, self.revision, 1) catch return error.RevisionOverflow;
        try provider.persist(&self.store, next_revision, self.next_id, self.clock, io, self.allocator, path);
        self.revision = next_revision;
    }

    pub fn persistAtomic(self: *Runtime, io: std.Io, path: []const u8) !void {
        const next_revision = std.math.add(u64, self.revision, 1) catch return error.RevisionOverflow;
        try persistence.saveAtomic(&self.store, next_revision, self.next_id, self.clock, io, self.allocator, path);
        try index_journal.save(&self.store, next_revision, io, self.allocator, path);
        self.revision = next_revision;
        self.index_checkpoint_revision = next_revision;
    }

    /// Commits through an optimistic CAS provider. A stale caller receives
    /// `error.RevisionConflict` and retains its in-memory revision unchanged.
    pub fn persistIfRevision(self: *Runtime, provider: storage_mod.VersionedProvider, expected_revision: u64, io: std.Io, path: []const u8) !void {
        const revision = try provider.persistIfRevision(&self.store, self.next_id, self.clock, expected_revision, io, self.allocator, path);
        self.revision = revision;
    }
    pub fn recover(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Runtime {
        try persistence.recoverJournal(io, allocator, path);
        const loaded = try persistence.load(allocator, io, path);
        var runtime = Runtime.init(allocator);
        runtime.store = loaded.store;
        runtime.next_id = loaded.next_id;
        runtime.clock = loaded.clock;
        runtime.revision = loaded.revision;
        if (try index_journal.recover(&runtime.store, runtime.revision, io, allocator, path)) runtime.index_checkpoint_revision = runtime.revision;
        if (runtime.store.fingerprint_groups.items.len > 0) {
            for (runtime.store.fingerprint_groups.items) |group| try runtime.experience_groups.put(group.fingerprint, group.count);
        } else {
            for (runtime.store.nodes.items) |node| {
                if (node.kind != .experience) continue;
                const key = nodeFingerprint(node);
                const entry = try runtime.experience_groups.getOrPut(key);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
                try runtime.store.recordFingerprint(key, node.id);
            }
        }
        try runtime.backend.reset(&runtime.store);
        return runtime;
    }
};

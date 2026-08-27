const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const backend_mod = @import("backend.zig");
const persistence = @import("persistence.zig");
const index_journal = @import("index_journal.zig");
const storage_mod = @import("storage.zig");
const retrieval = @import("retrieval.zig");
const ranking = @import("ranking.zig");
const signals_mod = @import("signals.zig");
const neural_mod = @import("neural.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    store: store_mod.Store,
    next_id: u64 = 1,
    next_transition_id: u64 = 1,
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
    feedback_attestation_policy: ?model.FeedbackAttestationPolicy = null,
    transition_verifier: ?model.TransitionVerifier = null,
    plasticity_policy: model.PlasticityPolicy = .{},

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
        next_transition_id: u64,
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
        transition_verifier: ?model.TransitionVerifier,
        plasticity_policy: model.PlasticityPolicy,
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
            runtime.next_transition_id = self.next_transition_id;
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
            runtime.transition_verifier = self.transition_verifier;
            runtime.plasticity_policy = self.plasticity_policy;
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
            .next_transition_id = self.next_transition_id,
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
            .transition_verifier = self.transition_verifier,
            .plasticity_policy = self.plasticity_policy,
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
        return self.makeRecord(.{ .kind = kind, .subject = subject, .predicate = predicate, .object = object, .context = context, .result = result, .timestamp = timestamp, .confidence = confidence });
    }

    fn makeRecord(self: *Runtime, input: model.RecordInput) !u64 {
        if (!std.math.isFinite(input.confidence) or input.confidence < 0 or input.confidence > 1) return error.InvalidConfidence;
        if (input.subject.len == 0 or input.predicate.len == 0 or input.object.len == 0) return error.InvalidRecord;
        const entry = try self.ownedNode(input.kind, input.subject, input.predicate, input.object, input.context, input.result, input.confidence, input.timestamp);
        const id = self.store.add(entry) catch |err| {
            store_mod.Store.deinitNode(self.allocator, entry);
            return err;
        };
        self.store.addRecordData(id, input) catch |err| {
            store_mod.Store.deinitNode(self.allocator, self.store.nodes.pop().?);
            return err;
        };
        self.backend.upsert(&self.store, id) catch |err| {
            self.store.removeRecordData(id);
            store_mod.Store.deinitNode(self.allocator, self.store.nodes.pop().?);
            return err;
        };
        self.next_id += 1;
        return id;
    }

    /// Writes a generic structured record. Domain adapters only normalize this
    /// input; they never obtain direct Store mutation access. Direct writes are
    /// deliberately incremental: source programs use beginTransaction() when a
    /// batch requires all-or-nothing semantics.
    pub fn record(self: *Runtime, input: model.RecordInput) !u64 {
        self.clock = @max(self.clock, input.timestamp);
        const id = try self.makeRecord(input);
        if (input.kind != .experience) return id;
        self.pending_experiences += 1;
        const key = self.nodeFingerprint(self.store.constNode(id).?);
        const entry = try self.experience_groups.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        try self.store.recordFingerprint(key, id);
        try self.pending_groups.put(key, {});
        if (self.auto_consolidation_enabled) _ = try self.consolidatePendingAtomic(self.auto_consolidation_policy);
        return id;
    }

    pub fn observe(self: *Runtime, subject: []const u8, predicate: []const u8, object: []const u8, context: []const u8, result: []const u8, timestamp: i64) !u64 {
        return self.record(.{ .subject = subject, .predicate = predicate, .object = object, .context = context, .result = result, .timestamp = timestamp });
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
        if (from == to) return error.InvalidRelation;
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
        };
    }
    pub fn contradict(self: *Runtime, from: u64, to: u64) !void {
        try self.link(from, .contradicts, to, 1);
        if (self.store.node(to)) |node| if (node.kind == .belief) {
            node.contradiction_count += 1;
            node.last_contradicted_at = self.clock;
        };
    }

    /// Configures an optional host-owned verifier for external tool receipts.
    /// Once installed, every subsequent feedback outcome must pass it.
    pub fn setFeedbackVerifier(self: *Runtime, verifier: model.FeedbackVerifier) void {
        self.feedback_verifier = verifier;
    }

    pub fn clearFeedbackVerifier(self: *Runtime) void {
        self.feedback_verifier = null;
    }

    /// Installs an Ed25519 verification policy for feedback attestations. The
    /// policy is deployment configuration and must be reinstalled after recover.
    pub fn setFeedbackAttestationPolicy(self: *Runtime, policy: model.FeedbackAttestationPolicy) !void {
        if (policy.issuers.len == 0 or policy.issuers.len > 64) return error.InvalidAttestationPolicy;
        for (policy.issuers, 0..) |issuer, index| {
            if (issuer.issuer.len == 0 or issuer.key_id.len == 0) return error.InvalidAttestationPolicy;
            for (policy.issuers[index + 1 ..]) |other| if (std.mem.eql(u8, issuer.issuer, other.issuer) and std.mem.eql(u8, issuer.key_id, other.key_id)) return error.InvalidAttestationPolicy;
        }
        self.feedback_attestation_policy = policy;
    }

    pub fn clearFeedbackAttestationPolicy(self: *Runtime) void {
        self.feedback_attestation_policy = null;
    }

    /// Installs the host-owned verifier required for externally requested
    /// cognitive transitions. This boundary intentionally does not execute
    /// actions; it only authorizes durable memory-state changes.
    pub fn setTransitionVerifier(self: *Runtime, verifier: model.TransitionVerifier) void {
        self.transition_verifier = verifier;
    }

    pub fn clearTransitionVerifier(self: *Runtime) void {
        self.transition_verifier = null;
    }

    fn validateTransitionInput(self: *const Runtime, input: model.TransitionInput) !void {
        const target = self.store.constNode(input.target) orelse return error.UnknownNode;
        _ = target;
        if (input.cause) |cause| if (self.store.constNode(cause) == null) return error.UnknownCause;
        if (input.reason.len == 0 or input.reason.len > 512 or input.actor.len == 0 or input.actor.len > 128 or input.receipt.len == 0 or input.receipt.len > 512) return error.InvalidTransition;
        if (!std.math.isFinite(input.amount) or input.amount < 0 or input.amount > 1) return error.InvalidTransition;
        switch (input.kind) {
            .set_state => if (input.target_state == null or input.amount != 0) return error.InvalidTransition,
            .reinforce, .penalize, .stabilize, .decay => if (input.target_state != null or input.amount == 0) return error.InvalidTransition,
        }
    }

    fn applyTransition(self: *Runtime, input: model.TransitionInput) !u64 {
        const target = self.store.node(input.target) orelse return error.UnknownNode;
        const prior_state = target.cognitive_state;
        const prior_confidence = target.confidence;
        const prior_strength = target.strength;
        switch (input.kind) {
            .set_state => target.cognitive_state = input.target_state.?,
            .reinforce => {
                target.confidence = @min(1, target.confidence + input.amount);
                target.strength = @min(1, target.strength + input.amount);
            },
            .penalize, .decay => {
                target.confidence *= 1 - input.amount;
                target.strength *= 1 - input.amount;
            },
            .stabilize => {
                target.cognitive_state = .active;
                target.strength = @min(1, target.strength + input.amount);
            },
        }
        self.clock = @max(self.clock, input.timestamp);
        const id = self.next_transition_id;
        self.next_transition_id += 1;
        try self.store.recordTransition(.{
            .id = id,
            .target = input.target,
            .cause = input.cause,
            .kind = input.kind,
            .prior_state = prior_state,
            .next_state = target.cognitive_state,
            .prior_confidence = prior_confidence,
            .next_confidence = target.confidence,
            .prior_strength = prior_strength,
            .next_strength = target.strength,
            .timestamp = input.timestamp,
            .reason = input.reason,
            .actor = input.actor,
            .receipt = input.receipt,
        });
        return id;
    }

    /// Commits one bounded, verified state change. The receipt and actor are
    /// verified before the transaction begins; allocation failures restore the
    /// node, clock, ID, and audit log together.
    pub fn transition(self: *Runtime, input: model.TransitionInput) !u64 {
        try self.validateTransitionInput(input);
        const verifier = self.transition_verifier orelse return error.TransitionVerifierRequired;
        try verifier.verify(input);
        var transaction = try self.beginTransaction();
        defer transaction.deinit();
        const id = self.applyTransition(input) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return id;
    }

    /// Replays the immutable transition audit without trusting caller state.
    /// It verifies per-target continuity and that each node ends at its last
    /// recorded state; this is the deterministic audit hook for host ledgers.
    pub fn verifyTransitionHistory(self: *const Runtime) !void {
        var last = std.AutoHashMap(u64, model.TransitionRecord).init(self.allocator);
        defer last.deinit();
        for (self.store.transition_records.items) |transition_record| {
            if (last.get(transition_record.target)) |previous| {
                if (previous.next_state != transition_record.prior_state or previous.next_confidence != transition_record.prior_confidence or previous.next_strength != transition_record.prior_strength) return error.InvalidTransitionHistory;
            }
            try last.put(transition_record.target, transition_record);
        }
        var iterator = last.iterator();
        while (iterator.next()) |entry| {
            const node = self.store.constNode(entry.key_ptr.*) orelse return error.InvalidTransitionHistory;
            const transition_record = entry.value_ptr.*;
            if (node.cognitive_state != transition_record.next_state or node.confidence != transition_record.next_confidence or node.strength != transition_record.next_strength) return error.InvalidTransitionHistory;
        }
    }

    pub fn setPlasticityPolicy(self: *Runtime, policy: model.PlasticityPolicy) !void {
        const rules = [_]model.PlasticityRule{ policy.success, policy.timeout, policy.transport, policy.tool_error, policy.invalid_result, policy.policy_denied, policy.unauthorized, policy.cancelled, policy.unknown };
        for (rules) |rule| {
            if (!std.math.isFinite(rule.amount) or rule.amount < 0 or rule.amount > 1) return error.InvalidPlasticityPolicy;
            if (rule.adjustment) |adjustment| switch (adjustment) {
                .reinforce, .penalize, .stabilize, .decay => if (rule.amount == 0) return error.InvalidPlasticityPolicy,
                .set_state => return error.InvalidPlasticityPolicy,
            } else if (rule.amount != 0) return error.InvalidPlasticityPolicy;
        }
        self.plasticity_policy = policy;
    }

    fn plasticityRule(self: *const Runtime, input: model.FeedbackInput) model.PlasticityRule {
        if (input.outcome == .success) return self.plasticity_policy.success;
        return switch (input.failure_class) {
            .timeout => self.plasticity_policy.timeout,
            .transport => self.plasticity_policy.transport,
            .tool_error => self.plasticity_policy.tool_error,
            .invalid_result => self.plasticity_policy.invalid_result,
            .policy_denied => self.plasticity_policy.policy_denied,
            .unauthorized => self.plasticity_policy.unauthorized,
            .cancelled => self.plasticity_policy.cancelled,
            .unknown => self.plasticity_policy.unknown,
            .none => unreachable,
        };
    }

    fn applyPlasticity(self: *Runtime, target: u64, cause: u64, input: model.FeedbackInput, rule: model.PlasticityRule) !void {
        if (rule.state) |state| _ = try self.applyTransition(.{ .target = target, .kind = .set_state, .target_state = state, .cause = cause, .reason = "verified feedback plasticity", .actor = input.actor, .receipt = input.receipt, .timestamp = input.timestamp });
        if (rule.adjustment) |adjustment| _ = try self.applyTransition(.{ .target = target, .kind = adjustment, .amount = rule.amount, .cause = cause, .reason = "verified feedback plasticity", .actor = input.actor, .receipt = input.receipt, .timestamp = input.timestamp });
    }

    /// Returns the canonical public payload that a trusted host signs. The
    /// payload deliberately binds feedback fields to the target's semantics.
    pub fn feedbackAttestationPayload(self: *const Runtime, input: model.FeedbackInput, target: *const model.Node, attestation: model.FeedbackAttestation) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "MEML-FEEDBACK-ATTEST-1\nissuer={d}:{s}\nkey_id={d}:{s}\nnonce={d}:{s}\nissued_at={d}\nexpires_at={d}\ntarget={d}\noutcome={s}\nfailure_class={s}\ntimestamp={d}\nactor={d}:{s}\nreceipt={d}:{s}\nnode_kind={s}\nsubject={d}:{s}\npredicate={d}:{s}\nobject={d}:{s}\ncontext={d}:{s}\nresult={d}:{s}\n", .{
            attestation.issuer.len, attestation.issuer,     attestation.key_id.len, attestation.key_id,      attestation.nonce.len,         attestation.nonce,
            attestation.issued_at,  attestation.expires_at, input.target,           @tagName(input.outcome), @tagName(input.failure_class), input.timestamp,
            input.actor.len,        input.actor,            input.receipt.len,      input.receipt,           @tagName(target.kind),         target.subject.len,
            target.subject,         target.predicate.len,   target.predicate,       target.object.len,       target.object,                 target.context.len,
            target.context,         target.result.len,      target.result,
        });
    }

    fn verifyFeedbackAttestation(self: *const Runtime, input: model.FeedbackInput, target: *const model.Node) !?model.AttestationReplayRecord {
        const policy = self.feedback_attestation_policy orelse return null;
        const attestation = input.attestation orelse return error.AttestationRequired;
        if (attestation.issuer.len == 0 or attestation.key_id.len == 0 or attestation.nonce.len == 0 or attestation.nonce.len > 256 or !std.mem.eql(u8, attestation.issuer, input.actor)) return error.InvalidAttestation;
        if (attestation.issued_at > attestation.expires_at or input.timestamp < attestation.issued_at or input.timestamp > attestation.expires_at or self.clock > attestation.expires_at) return error.ExpiredAttestation;
        var issuer: ?model.FeedbackAttestationIssuer = null;
        for (policy.issuers) |candidate| if (std.mem.eql(u8, candidate.issuer, attestation.issuer) and std.mem.eql(u8, candidate.key_id, attestation.key_id)) {
            issuer = candidate;
            break;
        };
        const trusted = issuer orelse return error.UntrustedAttestationIssuer;
        const payload = try self.feedbackAttestationPayload(input, target, attestation);
        defer self.allocator.free(payload);
        const public_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(trusted.public_key) catch return error.InvalidAttestationKey;
        const signature = std.crypto.sign.Ed25519.Signature.fromBytes(attestation.signature);
        signature.verifyStrict(payload, public_key) catch return error.InvalidAttestationSignature;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        if (self.store.hasAttestationReplay(digest)) return error.ReplayedAttestation;
        return .{ .digest = digest, .expires_at = attestation.expires_at };
    }

    /// Applies an external result. Feedback is writable by default; installing
    /// a legacy verifier or an Ed25519 attestation policy explicitly upgrades
    /// this operation to require that configured proof before semantic mutation.
    pub fn recordFeedback(self: *Runtime, input: model.FeedbackInput) !u64 {
        const target = self.store.constNode(input.target) orelse return error.UnknownNode;
        if (target.kind == .evidence) return error.InvalidFeedbackTarget;
        if (input.actor.len == 0 or input.receipt.len == 0 or (input.outcome == .success and input.failure_class != .none) or (input.outcome == .failure and input.failure_class == .none)) return error.InvalidFeedback;
        if (self.feedback_verifier) |verifier| try verifier.verify(input);
        const replay = try self.verifyFeedbackAttestation(input, target);
        var transaction = try self.beginTransaction();
        defer transaction.deinit();
        if (replay) |replay_record| {
            self.store.pruneExpiredAttestationReplays(input.timestamp);
            self.store.recordAttestationReplay(replay_record) catch |err| {
                transaction.rollback() catch |rollback_err| return rollback_err;
                return err;
            };
        }
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
        if (input.outcome == .success) try self.support(evidence, input.target, 1) else try self.contradict(evidence, input.target);
        try self.applyPlasticity(input.target, evidence, input, self.plasticityRule(input));
        return evidence;
    }

    pub fn infer(self: *Runtime, id: u64) !u64 {
        const node = self.store.node(id) orelse return error.UnknownNode;
        return self.make(.belief, node.subject, node.predicate, node.object, node.context, "inferred", node.confidence, self.clock);
    }

    /// Kernel-owned consolidation operation: a replacement belief supersedes an
    /// older belief and records the lifecycle change in the same audit stream.
    pub fn supersedeBelief(self: *Runtime, old_id: u64, replacement_id: u64) !void {
        const old = self.store.node(old_id) orelse return error.UnknownNode;
        const replacement = self.store.node(replacement_id) orelse return error.UnknownNode;
        if (old.kind != .belief or replacement.kind != .belief) return error.NotBelief;
        try self.store.link(.{ .from = replacement_id, .to = old_id, .kind = .derived_from, .weight = 1 });
        _ = try self.applyTransition(.{ .target = old_id, .kind = .set_state, .target_state = .superseded, .cause = replacement_id, .reason = "kernel belief replacement", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
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

    pub fn stability(self: *const Runtime, id: u64) !model.Stability {
        const node = self.store.constNode(id) orelse return error.UnknownNode;
        return ranking.stability(&self.store, node.*);
    }

    fn scopesCompatible(self: *const Runtime, id: u64, requested: []const model.Scope) bool {
        for (requested) |scope| {
            var found = false;
            for (self.store.scoped_records.items) |scope_record| {
                if (scope_record.node != id or !std.mem.eql(u8, scope_record.scope.key, scope.key)) continue;
                if (!std.mem.eql(u8, scope_record.scope.value, scope.value)) return false;
                found = true;
                break;
            }
            if (!found) return false;
        }
        return true;
    }

    /// Selection uses exact scope equality rather than prediction's directional
    /// compatibility: an unscoped request cannot silently select a procedure
    /// trained only for a hidden environment.
    fn selectionScopesCompatible(self: *const Runtime, id: u64, requested: []const model.Scope) bool {
        var procedure_scopes: usize = 0;
        for (self.store.scoped_records.items) |scope_record| {
            if (scope_record.node != id) continue;
            procedure_scopes += 1;
            var found = false;
            for (requested) |scope| {
                if (std.mem.eql(u8, scope_record.scope.key, scope.key) and std.mem.eql(u8, scope_record.scope.value, scope.value)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return procedure_scopes == requested.len;
    }

    fn validateSelectionGate(gate: model.ProcedureSelectionQualityGate) !void {
        const values = [_]f64{ gate.min_stability, gate.min_success_probability, gate.min_evidence_coverage };
        for (values) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidProcedureSelectionGate;
    }

    fn sortProcedureSelections(_: void, left: model.ProcedureSelection, right: model.ProcedureSelection) bool {
        const left_score = left.counterfactual_score orelse -1;
        const right_score = right.counterfactual_score orelse -1;
        if (left_score == right_score) return left.procedure < right.procedure;
        return left_score > right_score;
    }

    /// Performs a read-only, restricted comparison over exactly the procedure
    /// IDs supplied by the caller. No backend retrieval, graph expansion, or
    /// host action happens here; rejected items receive no score or rank.
    pub fn selectProcedures(self: *const Runtime, candidates: []const u64, context: model.Context, gate: model.ProcedureSelectionQualityGate, allocator: std.mem.Allocator) !std.ArrayList(model.ProcedureSelection) {
        try validateSelectionGate(gate);
        if (candidates.len == 0 or candidates.len > 64) return error.InvalidProcedureCandidates;
        var output = std.ArrayList(model.ProcedureSelection).empty;
        errdefer output.deinit(allocator);
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();
        for (candidates) |procedure| {
            if ((try seen.getOrPut(procedure)).found_existing) return error.DuplicateProcedureCandidate;
            const node = self.store.constNode(procedure) orelse return error.UnknownNode;
            if (node.kind != .procedure) return error.NotProcedure;
            const stability_value = try self.stability(procedure);
            const history = try self.predictProcedureAt(procedure, context, 0);
            const active = !gate.require_active or node.cognitive_state == .active;
            const scope_compatible = !gate.require_scope_compatibility or self.selectionScopesCompatible(procedure, context.scopes);
            const status: model.ProcedureSelectionStatus = .{
                .active = active,
                .scope_compatible = scope_compatible,
                .stability_sufficient = stability_value.score >= gate.min_stability,
                .samples_sufficient = history.samples >= gate.min_samples,
                .success_probability_sufficient = history.success_probability >= gate.min_success_probability,
                .evidence_coverage_sufficient = history.evidence_coverage >= gate.min_evidence_coverage,
            };
            const score: ?f64 = if (status.eligible()) stability_value.score * 0.4 + history.success_probability * 0.4 + history.evidence_coverage * 0.2 else null;
            try output.append(allocator, .{ .procedure = procedure, .stability = stability_value, .history = history, .status = status, .counterfactual_score = score });
        }
        std.sort.heap(model.ProcedureSelection, output.items, {}, sortProcedureSelections);
        var rank: usize = 1;
        for (output.items) |*selection| {
            if (selection.counterfactual_score != null) {
                selection.rank = rank;
                rank += 1;
            }
        }
        return output;
    }

    fn objectivesDuplicate(left: model.ProcedureObjectiveTarget, right: model.ProcedureObjectiveTarget) bool {
        return switch (left) {
            .stability => switch (right) {
                .stability => true,
                else => false,
            },
            .success_probability => switch (right) {
                .success_probability => true,
                else => false,
            },
            .evidence_coverage => switch (right) {
                .evidence_coverage => true,
                else => false,
            },
            .metric => |left_metric| switch (right) {
                .metric => |right_metric| std.mem.eql(u8, left_metric.name, right_metric.name) and std.mem.eql(u8, left_metric.unit, right_metric.unit),
                else => false,
            },
        };
    }

    fn validateComparisonPolicy(policy: model.ProcedureComparisonPolicy) !void {
        if (policy.objectives.len == 0 or policy.objectives.len > model.max_procedure_objectives) return error.InvalidProcedureObjectives;
        var total_weight: f64 = 0;
        for (policy.objectives, 0..) |objective, index| {
            if (objective.direction == .neutral or !std.math.isFinite(objective.weight) or objective.weight < 0) return error.InvalidProcedureObjective;
            if (objective.hard_limit) |limit| if (!std.math.isFinite(limit)) return error.InvalidProcedureObjective;
            switch (objective.target) {
                .stability, .success_probability, .evidence_coverage => if (objective.direction != .maximize) return error.InvalidProcedureObjective,
                .metric => |metric| if (metric.name.len == 0 or metric.name.len > 96 or metric.unit.len == 0 or metric.unit.len > 64) return error.InvalidProcedureObjective,
            }
            for (policy.objectives[0..index]) |previous| if (objectivesDuplicate(objective.target, previous.target)) return error.DuplicateProcedureObjective;
            total_weight += objective.weight;
        }
        if (total_weight <= 0) return error.InvalidProcedureObjective;
    }

    fn procedureMetric(self: *const Runtime, procedure: u64, target: model.ProcedureMetricTarget) ?model.Metric {
        for (self.store.metric_records.items) |metric_record| {
            if (metric_record.node == procedure and std.mem.eql(u8, metric_record.metric.name, target.name) and std.mem.eql(u8, metric_record.metric.unit, target.unit)) return metric_record.metric;
        }
        return null;
    }

    fn objectiveAssessment(self: *const Runtime, procedure: u64, objective: model.ProcedureObjective, stability_value: model.Stability, history: model.ProcedurePrediction) model.ProcedureObjectiveAssessment {
        var assessment: model.ProcedureObjectiveAssessment = .{};
        switch (objective.target) {
            .stability => assessment.observed_value = stability_value.score,
            .success_probability => assessment.observed_value = history.success_probability,
            .evidence_coverage => assessment.observed_value = history.evidence_coverage,
            .metric => |target| {
                const metric = self.procedureMetric(procedure, target) orelse {
                    assessment.rejection = .missing_metric;
                    return assessment;
                };
                if (metric.direction != objective.direction) {
                    assessment.rejection = .metric_direction_mismatch;
                    return assessment;
                }
                assessment.observed_value = metric.value;
                assessment.uncertainty = metric.uncertainty;
            },
        }
        const value = assessment.observed_value.?;
        assessment.conservative_value = if (assessment.uncertainty) |uncertainty| switch (objective.direction) {
            .maximize => value - uncertainty,
            .minimize => value + uncertainty,
            .neutral => unreachable,
        } else value;
        assessment.hard_limit_satisfied = if (objective.hard_limit) |limit| switch (objective.direction) {
            .maximize => assessment.conservative_value.? >= limit,
            .minimize => assessment.conservative_value.? <= limit,
            .neutral => unreachable,
        } else true;
        if (!assessment.hard_limit_satisfied) assessment.rejection = .hard_limit_failed;
        return assessment;
    }

    fn sortProcedureComparisons(_: void, left: model.ProcedureComparison, right: model.ProcedureComparison) bool {
        const left_score = left.counterfactual_score orelse -1;
        const right_score = right.counterfactual_score orelse -1;
        if (left_score == right_score) return left.procedure < right.procedure;
        return left_score > right_score;
    }

    /// Runs an explicitly bounded, read-only counterfactual comparison. The
    /// caller supplies both candidates and objectives; the kernel only measures
    /// durable evidence and never discovers alternatives or invokes actions.
    pub fn compareProcedures(self: *const Runtime, candidates: []const u64, context: model.Context, policy: model.ProcedureComparisonPolicy, allocator: std.mem.Allocator) !std.ArrayList(model.ProcedureComparison) {
        try validateComparisonPolicy(policy);
        if (candidates.len == 0 or candidates.len > 64) return error.InvalidProcedureCandidates;
        var output = std.ArrayList(model.ProcedureComparison).empty;
        errdefer output.deinit(allocator);
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();
        for (candidates) |procedure| {
            if ((try seen.getOrPut(procedure)).found_existing) return error.DuplicateProcedureCandidate;
            const node = self.store.constNode(procedure) orelse return error.UnknownNode;
            if (node.kind != .procedure) return error.NotProcedure;
            const stability_value = try self.stability(procedure);
            const history = try self.predictProcedureAt(procedure, context, 0);
            var comparison = model.ProcedureComparison{
                .procedure = procedure,
                .stability = stability_value,
                .history = history,
                .status = .{
                    .active = !policy.require_active or node.cognitive_state == .active,
                    .scope_compatible = !policy.require_scope_compatibility or self.selectionScopesCompatible(procedure, context.scopes),
                    .samples_sufficient = history.samples >= policy.min_samples,
                    .objectives_sufficient = true,
                },
                .assessment_count = policy.objectives.len,
            };
            for (policy.objectives, 0..) |objective, index| {
                comparison.assessments[index] = self.objectiveAssessment(procedure, objective, stability_value, history);
                if (comparison.assessments[index].rejection != .none) comparison.status.objectives_sufficient = false;
            }
            try output.append(allocator, comparison);
        }
        for (policy.objectives, 0..) |objective, index| {
            var minimum: ?f64 = null;
            var maximum: ?f64 = null;
            for (output.items) |comparison| {
                if (!comparison.status.eligible()) continue;
                const value = comparison.assessments[index].conservative_value orelse continue;
                minimum = if (minimum) |current| @min(current, value) else value;
                maximum = if (maximum) |current| @max(current, value) else value;
            }
            for (output.items) |*comparison| {
                if (!comparison.status.eligible()) continue;
                const value = comparison.assessments[index].conservative_value orelse continue;
                const low = minimum orelse continue;
                const high = maximum orelse continue;
                comparison.assessments[index].normalized_value = if (low == high) 1 else switch (objective.direction) {
                    .maximize => (value - low) / (high - low),
                    .minimize => (high - value) / (high - low),
                    .neutral => unreachable,
                };
            }
        }
        var total_weight: f64 = 0;
        for (policy.objectives) |objective| total_weight += objective.weight;
        for (output.items) |*comparison| {
            if (!comparison.status.eligible()) continue;
            var score: f64 = 0;
            for (policy.objectives, 0..) |objective, index| score += objective.weight * comparison.assessments[index].normalized_value.?;
            comparison.counterfactual_score = score / total_weight;
        }
        std.sort.heap(model.ProcedureComparison, output.items, {}, sortProcedureComparisons);
        var rank: usize = 1;
        for (output.items) |*comparison| if (comparison.counterfactual_score != null) {
            comparison.rank = rank;
            rank += 1;
        };
        return output;
    }

    /// Estimates a procedure's observed success rate from feedback recorded no
    /// later than `cutoff`. Laplace smoothing keeps zero-sample estimates
    /// explicitly uncertain rather than presenting them as certainty.
    pub fn predictProcedureAt(self: *const Runtime, procedure: u64, context: model.Context, cutoff: i64) !model.ProcedurePrediction {
        const node = self.store.constNode(procedure) orelse return error.UnknownNode;
        if (node.kind != .procedure) return error.NotProcedure;
        const compatible = self.scopesCompatible(procedure, context.scopes);
        var successes: usize = 0;
        var failures: usize = 0;
        for (self.store.feedback_records.items) |feedback| {
            if (feedback.target != procedure) continue;
            const evidence = self.store.constNode(feedback.evidence) orelse return error.InvalidFeedbackHistory;
            if (cutoff != 0 and evidence.timestamp > cutoff) continue;
            if (feedback.outcome == .success) successes += 1 else failures += 1;
        }
        const samples = successes + failures;
        return .{
            .procedure = procedure,
            .compatible = compatible,
            .samples = samples,
            .successes = successes,
            .failures = failures,
            .success_probability = @as(f64, @floatFromInt(successes + 1)) / @as(f64, @floatFromInt(samples + 2)),
            .evidence_coverage = @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(samples + 3)),
        };
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
            for (self.store.consolidations.items) |consolidation| {
                if (consolidation.source_a == proposal.source_a and consolidation.source_b == proposal.source_b and std.mem.eql(u8, consolidation.rule, consolidator.name())) {
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

    fn nodeFingerprint(self: *const Runtime, node: *const model.Node) u64 {
        var seed = fingerprint(node.subject, node.predicate, node.object, node.context, node.result);
        for (self.store.scoped_records.items) |scope_record| if (scope_record.node == node.id) {
            seed = std.hash.Wyhash.hash(seed, scope_record.scope.key);
            seed = std.hash.Wyhash.hash(seed, scope_record.scope.value);
        };
        for (self.store.metric_records.items) |metric_record| if (metric_record.node == node.id) {
            seed = std.hash.Wyhash.hash(seed, metric_record.metric.name);
            seed = std.hash.Wyhash.hash(seed, metric_record.metric.unit);
            seed = std.hash.Wyhash.hash(seed, @tagName(metric_record.metric.direction));
            seed = std.hash.Wyhash.hash(seed, std.mem.asBytes(&metric_record.metric.value));
            if (metric_record.metric.uncertainty) |uncertainty| seed = std.hash.Wyhash.hash(seed, std.mem.asBytes(&uncertainty));
        };
        for (self.store.artifact_records.items) |artifact_record| if (artifact_record.node == node.id) {
            seed = std.hash.Wyhash.hash(seed, artifact_record.artifact.kind);
            seed = std.hash.Wyhash.hash(seed, artifact_record.artifact.digest);
            seed = std.hash.Wyhash.hash(seed, artifact_record.artifact.locator);
        };
        for (self.store.structure_records.items) |structure_record| if (structure_record.node == node.id) {
            seed = std.hash.Wyhash.hash(seed, structure_record.structure.kind);
            seed = std.hash.Wyhash.hash(seed, structure_record.structure.fingerprint);
        };
        return seed;
    }

    fn recordRule(self: *Runtime, artifact: u64, rule: []const u8, source_a: u64, source_b: u64) !void {
        const rule_copy = try self.allocator.dupe(u8, rule);
        errdefer self.allocator.free(rule_copy);
        try self.store.recordConsolidation(.{ .artifact = artifact, .rule = rule_copy, .version = 1, .source_a = source_a, .source_b = source_b });
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
            const group_count = self.experience_groups.get(self.nodeFingerprint(left)) orelse 0;
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
                belief.support_count += @intCast(repetitions);
                belief.last_confirmed_at = self.clock;
                _ = try self.applyTransition(.{ .target = belief_id.?, .kind = .reinforce, .amount = @min(0.25, 0.05 * @as(f64, @floatFromInt(repetitions))), .reason = "kernel repeated experience", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
                if (belief.cognitive_state == .contested and belief.support_count > belief.contradiction_count) _ = try self.applyTransition(.{ .target = belief_id.?, .kind = .stabilize, .amount = 0.01, .reason = "kernel support majority", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
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
                                node.contradiction_count += 1;
                                node.last_contradicted_at = self.clock;
                            }
                            _ = try self.applyTransition(.{ .target = left.id, .kind = .set_state, .target_state = .contested, .cause = right.id, .reason = "kernel contextual contradiction", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
                            _ = try self.applyTransition(.{ .target = left.id, .kind = .penalize, .amount = 0.2, .cause = right.id, .reason = "kernel contextual contradiction", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
                            if (self.store.node(right.id)) |node| {
                                node.contradiction_count += 1;
                                node.last_contradicted_at = self.clock;
                            }
                            _ = try self.applyTransition(.{ .target = right.id, .kind = .set_state, .target_state = .contested, .cause = left.id, .reason = "kernel contextual contradiction", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
                            _ = try self.applyTransition(.{ .target = right.id, .kind = .penalize, .amount = 0.2, .cause = left.id, .reason = "kernel contextual contradiction", .actor = "kernel", .receipt = "consolidation", .timestamp = self.clock });
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
        self.revision = next_revision;
        try index_journal.save(&self.store, next_revision, io, self.allocator, path);
        self.index_checkpoint_revision = next_revision;
    }

    /// Commits through an optimistic CAS provider. A stale caller receives
    /// `error.RevisionConflict` and retains its in-memory revision unchanged.
    pub fn persistIfRevision(self: *Runtime, provider: storage_mod.VersionedProvider, expected_revision: u64, io: std.Io, path: []const u8) !void {
        const revision = try provider.persistIfRevision(&self.store, self.next_id, self.clock, expected_revision, io, self.allocator, path);
        self.revision = revision;
    }
    fn recoverLoaded(allocator: std.mem.Allocator, loaded: persistence.Loaded, index_checkpoint_revision: u64) !Runtime {
        var owned = loaded;
        var transferred = false;
        errdefer if (!transferred) owned.store.deinit();
        try owned.store.validate();
        var runtime = Runtime.init(allocator);
        errdefer runtime.deinit();
        runtime.store.deinit();
        runtime.store = owned.store;
        transferred = true;
        runtime.next_id = owned.next_id;
        for (runtime.store.transition_records.items) |transition_record| runtime.next_transition_id = @max(runtime.next_transition_id, transition_record.id + 1);
        runtime.clock = owned.clock;
        runtime.revision = owned.revision;
        runtime.index_checkpoint_revision = index_checkpoint_revision;
        if (runtime.store.fingerprint_groups.items.len > 0) {
            for (runtime.store.fingerprint_groups.items) |group| try runtime.experience_groups.put(group.fingerprint, group.count);
        } else {
            for (runtime.store.nodes.items) |node| {
                if (node.kind != .experience) continue;
                const key = runtime.nodeFingerprint(&node);
                const entry = try runtime.experience_groups.getOrPut(key);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
                try runtime.store.recordFingerprint(key, node.id);
            }
        }
        try runtime.backend.reset(&runtime.store);
        return runtime;
    }

    pub fn recover(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Runtime {
        try persistence.recoverJournal(io, allocator, path);
        var loaded = try persistence.load(allocator, io, path);
        const checkpoint_revision = if (try index_journal.recover(&loaded.store, loaded.revision, io, allocator, path)) loaded.revision else 0;
        return recoverLoaded(allocator, loaded, checkpoint_revision);
    }

    /// Recovers a semantic snapshot supplied by a host-owned CAS provider.
    /// Remote providers never transfer derived indexes; rebuilding them avoids
    /// cross-revision shard inconsistency after a successful CAS commit.
    pub fn recoverFrom(allocator: std.mem.Allocator, provider: storage_mod.VersionedProvider, io: std.Io, path: []const u8) !Runtime {
        const loaded = try provider.recover(allocator, io, path);
        return recoverLoaded(allocator, loaded, 0);
    }
};

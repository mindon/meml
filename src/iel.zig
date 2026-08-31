const std = @import("std");
const model = @import("model.zig");
const runtime_mod = @import("runtime.zig");

/// Information Evolution Language façade. It layers bitemporal provenance,
/// immutable evolution events, decision dependencies, and verification planning
/// over the existing domain-neutral MEML kernel.
pub const Evolution = struct {
    runtime: *runtime_mod.Runtime,

    pub const InformationInput = struct {
        record: model.RecordInput,
        kind: model.InformationKind,
        trust: model.Trust = .unverified,
        retention: model.Retention = .working,
        source: []const u8,
        observed_at: ?i64 = null,
        valid_from: ?i64 = null,
        valid_until: ?i64 = null,
    };

    pub fn init(runtime: *runtime_mod.Runtime) Evolution {
        return .{ .runtime = runtime };
    }

    fn nextEventId(self: *const Evolution) u64 {
        const events = self.runtime.store.evolution_events.items;
        return if (events.len == 0) 1 else events[events.len - 1].id + 1;
    }

    fn appendEvent(self: *Evolution, kind: model.EvolutionKind, target: u64, related: ?u64, timestamp: i64, source: []const u8, reason: []const u8) !void {
        try self.runtime.store.recordEvolutionEvent(.{ .id = self.nextEventId(), .kind = kind, .target = target, .related = related, .timestamp = timestamp, .source = source, .reason = reason });
    }

    fn record(self: *Evolution, input: InformationInput, event_kind: model.EvolutionKind, reason: []const u8) !u64 {
        const observed_at = input.observed_at orelse input.record.timestamp;
        const valid_from = input.valid_from orelse input.record.timestamp;
        if (input.source.len == 0 or input.valid_until != null and input.valid_until.? < valid_from) return error.InvalidInformation;
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        const id = self.runtime.record(input.record) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.runtime.store.recordInformation(.{ .node = id, .kind = input.kind, .trust = input.trust, .retention = input.retention, .source = input.source, .observed_at = observed_at, .valid_from = valid_from, .valid_until = input.valid_until }) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.appendEvent(event_kind, id, null, observed_at, input.source, reason) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return id;
    }

    /// Stage A: capture an observation without upgrading it to a verified fact.
    pub fn observe(self: *Evolution, input: InformationInput) !u64 {
        return self.record(input, .observe, "information observed");
    }

    /// Stage A: record an explicit assertion with its declared epistemic status.
    pub fn declare(self: *Evolution, input: InformationInput) !u64 {
        return self.record(input, .assert, "information asserted");
    }

    /// Stage C: create information derived from one existing source and retain a
    /// lineage edge. The derivation remains a hypothesis unless the caller sets
    /// stronger trust from independently verified evidence.
    pub fn derive(self: *Evolution, input: InformationInput, source: u64) !u64 {
        if (self.runtime.store.constNode(source) == null) return error.UnknownNode;
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        const id = self.record(input, .derive, "information derived") catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.runtime.link(id, .derived_from, source, 1) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return id;
    }

    /// Stage C: add independent support and update the materialized trust view.
    pub fn corroborate(self: *Evolution, evidence: u64, target: u64, timestamp: i64, source: []const u8) !void {
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        self.runtime.support(evidence, target, 1) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.runtime.store.setInformationTrust(target, .corroborated) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.appendEvent(.corroborate, target, evidence, timestamp, source, "independent evidence corroborated") catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
    }

    /// Stage C: preserve conflicting evidence rather than silently overwriting it.
    pub fn contradict(self: *Evolution, evidence: u64, target: u64, timestamp: i64, source: []const u8) !void {
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        self.runtime.contradict(evidence, target) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.appendEvent(.contradict, target, evidence, timestamp, source, "contradictory evidence recorded") catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
    }

    /// Stage C: state changes require the pre-existing host transition verifier.
    /// IEL records the event only after the guarded kernel transition succeeds.
    pub fn supersede(self: *Evolution, old: u64, replacement: u64, transition: model.TransitionInput, source: []const u8) !void {
        if (transition.target != old or transition.cause == null or transition.cause.? != replacement or transition.kind != .set_state or transition.target_state != .superseded) return error.InvalidSupersedeTransition;
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        self.runtime.link(replacement, .supersedes, old, 1) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        _ = self.runtime.transition(transition) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.appendEvent(.supersede, old, replacement, transition.timestamp, source, transition.reason) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
    }

    /// Stage C: expire, archive, and revoke share the verifier-protected state
    /// transition boundary. Revocation additionally lowers the trust view.
    pub fn changeLifecycle(self: *Evolution, kind: model.EvolutionKind, transition: model.TransitionInput, source: []const u8) !void {
        if (kind != .expire and kind != .archive and kind != .revoke) return error.InvalidLifecycleEvent;
        if (transition.kind != .set_state or transition.target_state == null) return error.InvalidLifecycleTransition;
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        _ = self.runtime.transition(transition) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        if (kind == .revoke) self.runtime.store.setInformationTrust(transition.target, .revoked) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        if (kind == .archive) self.runtime.store.setInformationRetention(transition.target, .archived) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        self.appendEvent(kind, transition.target, transition.cause, transition.timestamp, source, transition.reason) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
    }

    /// Stage D: record which information informed a host decision. This does
    /// not authorize or execute the decision's external action.
    pub fn recordDecision(self: *Evolution, input: InformationInput, dependencies: []const u64) !u64 {
        var decision_input = input;
        decision_input.record.kind = .context;
        decision_input.kind = .decision;
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        const decision = self.record(decision_input, .decision, "decision dependency recorded") catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        for (dependencies) |information| self.runtime.store.recordDecisionDependency(.{ .decision = decision, .information = information, .timestamp = decision_input.observed_at orelse decision_input.record.timestamp }) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return decision;
    }

    /// Stage D: write a host-observed outcome back into the information ledger.
    /// The underlying runtime still applies any configured receipt or attestation
    /// policy before this event is materialized.
    pub fn recordFeedback(self: *Evolution, input: model.FeedbackInput, source: []const u8) !u64 {
        var transaction = try self.runtime.beginTransaction();
        defer transaction.deinit();
        const evidence = self.runtime.recordFeedback(input) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        if (input.outcome == .success) self.runtime.store.setInformationTrust(input.target, .corroborated) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        const reason = if (input.outcome == .success) "verified outcome succeeded" else "verified outcome failed";
        self.appendEvent(.feedback, input.target, evidence, input.timestamp, source, reason) catch |err| {
            transaction.rollback() catch |rollback_err| return rollback_err;
            return err;
        };
        transaction.commit();
        return evidence;
    }

    /// Stage E: identify high-value verification work without initiating tools
    /// or trusting any unverified source.
    pub fn verificationCandidates(self: *const Evolution, now: i64, allocator: std.mem.Allocator) !std.ArrayList(model.VerificationCandidate) {
        var output = std.ArrayList(model.VerificationCandidate).empty;
        errdefer output.deinit(allocator);
        for (self.runtime.store.information_records.items) |information| {
            const node = self.runtime.store.constNode(information.node) orelse continue;
            var priority: f64 = 0;
            var reason: []const u8 = "low confidence";
            if (information.trust == .unverified or information.trust == .asserted) {
                priority = 0.55;
                reason = "unverified provenance";
            }
            if (node.cognitive_state == .contested or node.contradiction_count > 0) {
                priority = @max(priority, 0.8);
                reason = "unresolved contradiction";
            }
            if (information.valid_until != null and information.valid_until.? <= now) {
                priority = @max(priority, 0.9);
                reason = "validity interval expired";
            }
            if (node.confidence < 0.5 and priority < 0.5) {
                priority = 0.5;
                reason = "low confidence";
            }
            if (priority > 0) try output.append(allocator, .{ .information = information.node, .priority = priority, .reason = reason });
        }
        std.sort.heap(model.VerificationCandidate, output.items, {}, struct {
            fn lessThan(_: void, left: model.VerificationCandidate, right: model.VerificationCandidate) bool {
                if (left.priority == right.priority) return left.information < right.information;
                return left.priority > right.priority;
            }
        }.lessThan);
        return output;
    }

    /// Re-validates that the immutable event stream still materializes into the
    /// current information graph and decision dependency view after recovery.
    pub fn verifyMaterializedView(self: *const Evolution) !void {
        try self.runtime.store.validate();
        for (self.runtime.store.evolution_events.items) |event| switch (event.kind) {
            .observe, .assert, .derive, .decision => if (self.runtime.store.information(event.target) == null) return error.MissingInformationForEvent,
            .supersede => {
                const replacement = event.related orelse return error.InvalidEvolutionHistory;
                var linked = false;
                for (self.runtime.store.relations.items) |relation| {
                    if (relation.from == replacement and relation.to == event.target and relation.kind == .supersedes) linked = true;
                }
                if (!linked) return error.InvalidEvolutionHistory;
            },
            else => {},
        };
    }
};

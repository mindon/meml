const std = @import("std");
const meml = @import("meml.zig");
const evaluation = @import("evaluation.zig");

fn verifyTrustedFeedback(_: *anyopaque, input: meml.FeedbackInput) !void {
    if (!std.mem.eql(u8, input.actor, "trusted-agent") or !std.mem.startsWith(u8, input.receipt, "receipt-")) return error.UntrustedFeedback;
}

fn trustedFeedbackVerifier() meml.FeedbackVerifier {
    return .{ .context = undefined, .verifyFn = verifyTrustedFeedback };
}

fn verifyTrustedTransition(_: *anyopaque, input: meml.TransitionInput) !void {
    if (!std.mem.eql(u8, input.actor, "trusted-agent") or !std.mem.startsWith(u8, input.receipt, "receipt-")) return error.UntrustedTransition;
}

fn trustedTransitionVerifier() meml.model.TransitionVerifier {
    return .{ .context = undefined, .verifyFn = verifyTrustedTransition };
}

fn signedFeedback(runtime: *meml.Runtime, key_pair: std.crypto.sign.Ed25519.KeyPair, target: u64, nonce: []const u8, timestamp: i64, expires_at: i64) !meml.FeedbackInput {
    var input = meml.FeedbackInput{
        .target = target,
        .outcome = .success,
        .failure_class = .none,
        .actor = "trusted-tool",
        .receipt = "opaque-receipt-reference",
        .timestamp = timestamp,
        .attestation = .{
            .issuer = "trusted-tool",
            .key_id = "test-key-1",
            .nonce = nonce,
            .issued_at = timestamp - 1,
            .expires_at = expires_at,
            .signature = std.mem.zeroes([64]u8),
        },
    };
    const payload = try runtime.feedbackAttestationPayload(input, runtime.store.constNode(target).?, input.attestation.?);
    defer runtime.allocator.free(payload);
    input.attestation.?.signature = (try key_pair.sign(payload, null)).toBytes();
    return input;
}

fn remoteLoadRevision(_: *anyopaque, io: std.Io, path: []const u8) !u64 {
    return meml.storage.VersionedLocal.provider().loadRevision(io, path);
}

fn remotePersistIfRevision(_: *anyopaque, store: *const meml.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
    return meml.storage.VersionedLocal.provider().persistIfRevision(store, next_id, clock, expected_revision, io, allocator, path);
}

fn remoteRecover(_: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !meml.persistence.Loaded {
    return meml.storage.VersionedLocal.provider().recover(allocator, io, path);
}

const FaultingRemote = struct {
    timeout_after_commit: bool = false,
    fail_recover: bool = false,
    persist_attempts: usize = 0,
    successful_commits: usize = 0,
    recover_attempts: usize = 0,

    fn self(context: *anyopaque) *FaultingRemote {
        return @ptrCast(@alignCast(context));
    }

    fn loadRevision(_: *anyopaque, io: std.Io, path: []const u8) !u64 {
        return meml.storage.VersionedLocal.provider().loadRevision(io, path);
    }

    fn persistIfRevision(context: *anyopaque, store: *const meml.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
        const remote = self(context);
        remote.persist_attempts += 1;
        const revision = try meml.storage.VersionedLocal.provider().persistIfRevision(store, next_id, clock, expected_revision, io, allocator, path);
        remote.successful_commits += 1;
        if (remote.timeout_after_commit) return error.RemoteTimeout;
        return revision;
    }

    fn recover(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !meml.persistence.Loaded {
        const remote = self(context);
        remote.recover_attempts += 1;
        if (remote.fail_recover) return error.RemoteUnavailable;
        return meml.storage.VersionedLocal.provider().recover(allocator, io, path);
    }

    fn transport(self_ptr: *FaultingRemote) meml.storage.Remote.Transport {
        return .{ .context = self_ptr, .loadRevisionFn = loadRevision, .persistIfRevisionFn = persistIfRevision, .recoverFn = recover };
    }
};

fn writeTestFile(path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try file.sync(std.testing.io);
}

fn expectMissing(path: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
}

const test_artifacts_dir = "test-artifacts";

/// Returns the path of a test artifact inside the dedicated `test-artifacts/`
/// directory, creating that directory on first use. Keeps the `test-*.state`,
/// `test-*.index` and other persistence sidecars out of the repository root.
/// `name` is comptime so the returned slice points to a static string that
/// remains valid for the whole test, while the directory is ensured lazily.
fn testPath(comptime name: []const u8) []const u8 {
    std.Io.Dir.cwd().createDirPath(std.testing.io, test_artifacts_dir) catch {};
    return test_artifacts_dir ++ "/" ++ name;
}

test "signed feedback attestation binds fields, rejects replay, and survives recovery" {
    const path = testPath("test-signed-feedback.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-signed-feedback.state.journal")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-signed-feedback.state.index.journal")) catch {};

    var seed: [32]u8 = undefined;
    @memset(&seed, 7);
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const issuers = [_]meml.FeedbackAttestationIssuer{.{ .issuer = "trusted-tool", .key_id = "test-key-1", .public_key = key_pair.public_key.toBytes() }};
    const policy = meml.FeedbackAttestationPolicy{ .issuers = &issuers };
    var runtime = meml.Runtime.init(std.testing.allocator);
    try runtime.setFeedbackAttestationPolicy(policy);
    const target = try runtime.assert("agent", "uses", "verified-tool", "current", 0.5);
    const accepted = try signedFeedback(&runtime, key_pair, target, "nonce-1", 10, 20);
    _ = try runtime.recordFeedback(accepted);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.attestation_replays.items.len);
    const nodes_after_accept = runtime.store.nodes.items.len;
    const relations_after_accept = runtime.store.relations.items.len;
    try std.testing.expectError(error.ReplayedAttestation, runtime.recordFeedback(accepted));
    try std.testing.expectEqual(nodes_after_accept, runtime.store.nodes.items.len);
    try std.testing.expectEqual(relations_after_accept, runtime.store.relations.items.len);

    var tampered = try signedFeedback(&runtime, key_pair, target, "nonce-2", 11, 20);
    tampered.receipt = "different-receipt";
    try std.testing.expectError(error.InvalidAttestationSignature, runtime.recordFeedback(tampered));
    try std.testing.expectEqual(nodes_after_accept, runtime.store.nodes.items.len);

    const expired = try signedFeedback(&runtime, key_pair, target, "nonce-3", 21, 20);
    try std.testing.expectError(error.ExpiredAttestation, runtime.recordFeedback(expired));
    try std.testing.expectEqual(nodes_after_accept, runtime.store.nodes.items.len);

    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try recovered.setFeedbackAttestationPolicy(policy);
    try std.testing.expectEqual(@as(usize, 1), recovered.store.attestation_replays.items.len);
    try std.testing.expectError(error.ReplayedAttestation, recovered.recordFeedback(accepted));
}

test "verified transitions alter future activation and persist audit" {
    const path = testPath("test-dynamic-memory.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-dynamic-memory.state.journal")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-dynamic-memory.state.index.journal")) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const target = try runtime.observe("agent", "selects", "strategy", "current", "success", 1);
    try std.testing.expectError(error.TransitionVerifierRequired, runtime.transition(.{ .target = target, .kind = .reinforce, .amount = 0.2, .reason = "test", .actor = "trusted-agent", .receipt = "receipt-x", .timestamp = 2 }));
    runtime.setTransitionVerifier(trustedTransitionVerifier());
    const transition_id = try runtime.transition(.{ .target = target, .kind = .set_state, .target_state = .contested, .reason = "contradictory evidence", .actor = "trusted-agent", .receipt = "receipt-1", .timestamp = 2 });
    try std.testing.expectEqual(@as(u64, 1), transition_id);
    var active = try runtime.activate(.{ .query = "strategy" }, 1, std.testing.allocator);
    defer active.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), active.items.len);
    var contested = try runtime.activate(.{ .query = "strategy", .activation_policy = .include_contested }, 1, std.testing.allocator);
    defer contested.deinit(std.testing.allocator);
    try std.testing.expectEqual(target, contested.items[0].id);
    _ = try runtime.transition(.{ .target = target, .kind = .stabilize, .amount = 0.2, .reason = "repeated evidence", .actor = "trusted-agent", .receipt = "receipt-2", .timestamp = 3 });
    try runtime.verifyTransitionHistory();
    try runtime.persist(std.testing.io, path);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), recovered.store.transition_records.items.len);
    try recovered.verifyTransitionHistory();
}

test "dynamic evaluation measures state-aware activation change" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setTransitionVerifier(trustedTransitionVerifier());
    const target = try runtime.observe("agent", "selects", "method", "current", "success", 1);
    _ = try runtime.transition(.{ .target = target, .kind = .set_state, .target_state = .contested, .reason = "conflict", .actor = "trusted-agent", .receipt = "receipt-1", .timestamp = 2 });
    const cases = [_]meml.DynamicsCase{.{ .task_id = "state-aware-selection", .before = .{ .query = "method", .activation_policy = .include_contested }, .after = .{ .query = "method" }, .expected_before = target, .expected_after = null }};
    const report = try meml.evaluation.evaluateDynamics(&runtime, &cases, 1, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.changed);
    try std.testing.expectEqual(@as(usize, 1), report.expected_before);
}

test "procedural memory carries scoped utility and verified plasticity" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setTransitionVerifier(trustedTransitionVerifier());
    const scopes = [_]meml.Scope{.{ .key = "environment", .value = "current" }};
    const metrics = [_]meml.Metric{.{ .name = "utility", .value = 0.8, .direction = .maximize }};
    const procedure = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "safe-process", .timestamp = 1, .scopes = &scopes, .metrics = &metrics });
    _ = try runtime.transition(.{ .target = procedure, .kind = .reinforce, .amount = 0.15, .reason = "verified-procedure-success", .actor = "trusted-agent", .receipt = "receipt-1", .timestamp = 2 });
    var active = try runtime.activate(.{ .query = "safe-process", .scopes = &scopes }, 1, std.testing.allocator);
    defer active.deinit(std.testing.allocator);
    try std.testing.expectEqual(procedure, active.items[0].id);
    try std.testing.expect(active.items[0].signals.scope > 0.9);
    try std.testing.expect(active.items[0].signals.metric > 0);
    try std.testing.expectEqual(@as(f64, 0.65), runtime.store.constNode(procedure).?.confidence);
}

test "bounded propagation respects cognitive state and edge budgets" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setTransitionVerifier(trustedTransitionVerifier());
    const seed = try runtime.observe("agent", "uses", "seed-process", "current", "success", 1);
    const hidden = try runtime.observe("agent", "uses", "linked-process", "current", "success", 2);
    try runtime.support(seed, hidden, 1);
    _ = try runtime.transition(.{ .target = hidden, .kind = .set_state, .target_state = .contested, .reason = "conflict", .actor = "trusted-agent", .receipt = "receipt-1", .timestamp = 3 });
    var active_only = try runtime.activateWithStats(.{ .query = "seed-process", .propagation = .{ .max_hops = 1, .edge_limit = 1, .candidate_limit = 2 } }, 2, std.testing.allocator);
    defer active_only.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), active_only.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), active_only.stats.edges_examined);
    var include_contested = try runtime.activateWithStats(.{ .query = "seed-process", .activation_policy = .include_contested, .propagation = .{ .max_hops = 1, .edge_limit = 1, .candidate_limit = 2 } }, 2, std.testing.allocator);
    defer include_contested.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), include_contested.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), include_contested.stats.propagated);
}

test "repeated verified evidence produces a derived stable attractor" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    try runtime.setPlasticityPolicy(.{ .success = .{ .adjustment = .reinforce, .amount = 0.25 } });
    const target = try runtime.assert("agent", "uses", "reliable-process", "current", 0.5);
    _ = try runtime.recordFeedback(.{ .target = target, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-1", .timestamp = 1 });
    _ = try runtime.recordFeedback(.{ .target = target, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-2", .timestamp = 2 });
    const stable = try runtime.stability(target);
    try std.testing.expectEqual(meml.AttractorState.stable, stable.state);
    try std.testing.expectEqual(@as(usize, 2), stable.support);
    try std.testing.expectEqual(@as(usize, 2), stable.transitions);
    _ = try runtime.recordFeedback(.{ .target = target, .outcome = .failure, .failure_class = .invalid_result, .actor = "trusted-agent", .receipt = "receipt-3", .timestamp = 3 });
    try std.testing.expectEqual(meml.AttractorState.contested, (try runtime.stability(target)).state);
}

test "procedure prediction excludes feedback beyond cutoff and evaluates calibration" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    const scopes = [_]meml.Scope{.{ .key = "environment", .value = "current" }};
    const procedure = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "reliable-process", .timestamp = 1, .scopes = &scopes });
    _ = try runtime.recordFeedback(.{ .target = procedure, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-1", .timestamp = 10 });
    _ = try runtime.recordFeedback(.{ .target = procedure, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-2", .timestamp = 20 });
    _ = try runtime.recordFeedback(.{ .target = procedure, .outcome = .failure, .failure_class = .tool_error, .actor = "trusted-agent", .receipt = "receipt-3", .timestamp = 30 });
    const before_failure = try runtime.predictProcedureAt(procedure, .{ .scopes = &scopes }, 20);
    try std.testing.expect(before_failure.compatible);
    try std.testing.expectEqual(@as(usize, 2), before_failure.samples);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), before_failure.success_probability, 0.000001);
    const after_failure = try runtime.predictProcedureAt(procedure, .{ .scopes = &scopes }, 30);
    try std.testing.expectEqual(@as(usize, 3), after_failure.samples);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), after_failure.success_probability, 0.000001);
    const path = testPath("test-procedure-prediction.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-procedure-prediction.state.journal")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-procedure-prediction.state.index.journal")) catch {};
    try runtime.persist(std.testing.io, path);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    const recovered_prediction = try recovered.predictProcedureAt(procedure, .{ .scopes = &scopes }, 20);
    try std.testing.expectApproxEqAbs(before_failure.success_probability, recovered_prediction.success_probability, 0.000001);
    const cases = [_]meml.ProcedurePredictionCase{.{ .task_id = "procedure-success-holdout", .procedure = procedure, .context = .{ .scopes = &scopes }, .cutoff = 20, .expected = .success }};
    const report = try meml.evaluation.evaluateProcedurePredictions(&runtime, &cases);
    try std.testing.expect((meml.ProcedurePredictionQualityGate{ .min_accuracy = 1, .max_brier = 0.1 }).accepts(report));
}

test "procedure quality gate selects only stable compatible verified candidates" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    try runtime.setPlasticityPolicy(.{ .success = .{ .adjustment = .reinforce, .amount = 0.25 } });
    const scopes = [_]meml.Scope{.{ .key = "environment", .value = "current" }};
    const reliable = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "reliable-process", .timestamp = 1, .scopes = &scopes });
    const fragile = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "fragile-process", .timestamp = 1, .scopes = &scopes });
    const hidden = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "hidden-process", .timestamp = 1, .scopes = &scopes });
    for (0..3) |index| _ = try runtime.recordFeedback(.{ .target = reliable, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-reliable", .timestamp = @intCast(index + 2) });
    for (0..3) |index| _ = try runtime.recordFeedback(.{ .target = fragile, .outcome = .failure, .failure_class = .tool_error, .actor = "trusted-agent", .receipt = "receipt-fragile", .timestamp = @intCast(index + 10) });
    const gate = meml.ProcedureSelectionQualityGate{ .min_stability = 0.75, .min_samples = 3, .min_success_probability = 0.6, .min_evidence_coverage = 0.5 };
    var selections = try runtime.selectProcedures(&[_]u64{ fragile, reliable }, .{ .scopes = &scopes }, gate, std.testing.allocator);
    defer selections.deinit(std.testing.allocator);
    try std.testing.expectEqual(reliable, selections.items[0].procedure);
    try std.testing.expectEqual(@as(?usize, 1), selections.items[0].rank);
    try std.testing.expect(selections.items[0].status.eligible());
    try std.testing.expectEqual(fragile, selections.items[1].procedure);
    try std.testing.expect(selections.items[1].counterfactual_score == null);
    try std.testing.expect(!selections.items[1].status.active);
    try std.testing.expect(selections.items[0].procedure != hidden);
    var mismatched = try runtime.selectProcedures(&[_]u64{reliable}, .{}, gate, std.testing.allocator);
    defer mismatched.deinit(std.testing.allocator);
    try std.testing.expect(!mismatched.items[0].status.scope_compatible);
    try std.testing.expect(mismatched.items[0].counterfactual_score == null);
    try std.testing.expectError(error.DuplicateProcedureCandidate, runtime.selectProcedures(&[_]u64{ reliable, reliable }, .{ .scopes = &scopes }, gate, std.testing.allocator));
    const cases = [_]meml.ProcedureSelectionCase{.{ .task_id = "quality-gated-choice", .candidates = &[_]u64{ fragile, reliable }, .context = .{ .scopes = &scopes }, .gate = gate, .expected = reliable }};
    const report = try meml.evaluation.evaluateProcedureSelection(&runtime, &cases, std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 1), report.selectionAccuracy(), 0.000001);
}

test "multi-objective comparison ranks explicit procedures and explains rejections" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    try runtime.setPlasticityPolicy(.{ .success = .{ .adjustment = .reinforce, .amount = 0.25 } });
    const scopes = [_]meml.Scope{.{ .key = "environment", .value = "current" }};
    const fast_metrics = [_]meml.Metric{ .{ .name = "cost", .value = 80, .unit = "usd", .direction = .minimize }, .{ .name = "latency", .value = 10, .unit = "ms", .uncertainty = 1, .direction = .minimize } };
    const cheap_metrics = [_]meml.Metric{ .{ .name = "cost", .value = 20, .unit = "usd", .direction = .minimize }, .{ .name = "latency", .value = 30, .unit = "ms", .uncertainty = 1, .direction = .minimize } };
    const incomplete_metrics = [_]meml.Metric{.{ .name = "cost", .value = 5, .unit = "usd", .direction = .minimize }};
    const fast = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "fast", .timestamp = 1, .scopes = &scopes, .metrics = &fast_metrics });
    const cheap = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "cheap", .timestamp = 1, .scopes = &scopes, .metrics = &cheap_metrics });
    const incomplete = try runtime.record(.{ .kind = .procedure, .subject = "agent", .predicate = "uses", .object = "incomplete", .timestamp = 1, .scopes = &scopes, .metrics = &incomplete_metrics });
    const procedures = [_]u64{ fast, cheap, incomplete };
    for (procedures) |procedure| {
        for (0..3) |index| {
            _ = try runtime.recordFeedback(.{ .target = procedure, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-success", .timestamp = @intCast(procedure * 10 + index) });
        }
    }
    const objectives = [_]meml.ProcedureObjective{
        .{ .target = .{ .metric = .{ .name = "cost", .unit = "usd" } }, .direction = .minimize, .weight = 0.2 },
        .{ .target = .{ .metric = .{ .name = "latency", .unit = "ms" } }, .direction = .minimize, .weight = 0.8, .hard_limit = 40 },
    };
    const policy = meml.ProcedureComparisonPolicy{ .min_samples = 3, .objectives = &objectives };
    var comparisons = try runtime.compareProcedures(&[_]u64{ incomplete, cheap, fast }, .{ .scopes = &scopes }, policy, std.testing.allocator);
    defer comparisons.deinit(std.testing.allocator);
    try std.testing.expectEqual(fast, comparisons.items[0].procedure);
    try std.testing.expectEqual(@as(?usize, 1), comparisons.items[0].rank);
    try std.testing.expectEqual(cheap, comparisons.items[1].procedure);
    try std.testing.expectEqual(@as(?usize, 2), comparisons.items[1].rank);
    try std.testing.expectEqual(incomplete, comparisons.items[2].procedure);
    try std.testing.expect(comparisons.items[2].counterfactual_score == null);
    try std.testing.expectEqual(meml.ProcedureComparisonRejection.missing_metric, comparisons.items[2].assessments[1].rejection);
    try std.testing.expectEqual(@as(usize, 3), comparisons.items.len);
    const path = testPath("test-procedure-comparison.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-procedure-comparison.state.journal")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-procedure-comparison.state.index.journal")) catch {};
    try runtime.persist(std.testing.io, path);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    var recovered_comparisons = try recovered.compareProcedures(&[_]u64{ incomplete, cheap, fast }, .{ .scopes = &scopes }, policy, std.testing.allocator);
    defer recovered_comparisons.deinit(std.testing.allocator);
    try std.testing.expectEqual(fast, recovered_comparisons.items[0].procedure);
    try std.testing.expectEqual(@as(?usize, 1), recovered_comparisons.items[0].rank);
    const constrained_objectives = [_]meml.ProcedureObjective{.{ .target = .{ .metric = .{ .name = "cost", .unit = "usd" } }, .direction = .minimize, .weight = 1, .hard_limit = 50 }};
    var constrained = try runtime.compareProcedures(&[_]u64{ fast, cheap }, .{ .scopes = &scopes }, .{ .min_samples = 3, .objectives = &constrained_objectives }, std.testing.allocator);
    defer constrained.deinit(std.testing.allocator);
    try std.testing.expectEqual(cheap, constrained.items[0].procedure);
    try std.testing.expectEqual(meml.ProcedureComparisonRejection.hard_limit_failed, constrained.items[1].assessments[0].rejection);
    try std.testing.expectError(error.DuplicateProcedureObjective, runtime.compareProcedures(&[_]u64{ fast, cheap }, .{ .scopes = &scopes }, .{ .min_samples = 3, .objectives = &[_]meml.ProcedureObjective{ .{ .target = .stability, .direction = .maximize, .weight = 0.5 }, .{ .target = .stability, .direction = .maximize, .weight = 0.5 } } }, std.testing.allocator));
    const cases = [_]meml.ProcedureComparisonCase{.{ .task_id = "weighted-explicit-comparison", .candidates = &[_]u64{ incomplete, cheap, fast }, .context = .{ .scopes = &scopes }, .policy = policy, .expected = fast }};
    const report = try meml.evaluation.evaluateProcedureComparison(&runtime, &cases, std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 1), report.selectionAccuracy(), 0.000001);
    try std.testing.expectEqual(@as(usize, 1), report.rejected);
}

test "memory dynamics DSL performs only verified bounded transitions" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setTransitionVerifier(trustedTransitionVerifier());
    const program =
        \\assert agent selects compact-reply preference confidence 0.5 as style
        \\transition style reinforce 0.2 actor trusted-agent receipt receipt-1 at 10 reason repeated-success
    ;
    var report = try meml.source.execute(&runtime, program, std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.transitions);
    try std.testing.expectEqual(@as(f64, 0.7), runtime.store.nodes.items[0].confidence);
    try runtime.verifyTransitionHistory();
}

test "context changes activated memory" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const python = try runtime.observe("user", "uses", "python", "data", "", 10);
    const typescript = try runtime.observe("user", "uses", "typescript", "browser", "", 20);
    var browser = try runtime.activate(.{ .query = "uses", .goal = "browser", .situation = "browser", .now = 20 }, 1, std.testing.allocator);
    defer browser.deinit(std.testing.allocator);
    var data = try runtime.activate(.{ .query = "uses", .goal = "data", .situation = "data", .now = 20 }, 1, std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(typescript, browser.items[0].id);
    try std.testing.expectEqual(python, data.items[0].id);
}

test "temporal ranking prefers recent" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("u", "uses", "old", "work", "", 1);
    const recent = try runtime.observe("u", "uses", "recent", "work", "", 100);
    var output = try runtime.activate(.{ .query = "uses", .now = 100 }, 2, std.testing.allocator);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(recent, output.items[0].id);
    try std.testing.expect(output.items[0].signals.temporal > output.items[1].signals.temporal);
}

test "procedure ranking and persistence survive reload" {
    const path = testPath("test-procedure-persistence.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    const experience = try runtime.observe("u", "does", "deploy", "browser", "success", 10);
    const procedure = try runtime.inferProcedure(&[_]u64{experience}, "deploy procedure");
    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    var output = try recovered.activate(.{ .query = "deploy", .goal = "how deploy", .preferred = "deploy", .now = 10 }, 1, std.testing.allocator);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(procedure, output.items[0].id);
}

test "scale path activates one thousand experiences" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var i: usize = 0;
    while (i < 1000) : (i += 1) _ = try runtime.observe("user", "uses", if (i % 4 == 0) "typescript" else "python", if (i % 3 == 0) "browser" else "data", "success", @intCast(i + 1));
    var output = try runtime.activate(.{ .query = "uses", .goal = "browser", .situation = "browser", .preferred = "typescript", .now = 1000 }, 10, std.testing.allocator);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), output.items.len);
    try std.testing.expect(output.items[0].score >= output.items[9].score);
}

test "indexed routing exposes candidate and scoring counts" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var i: usize = 0;
    while (i < 1000) : (i += 1) _ = try runtime.observe("user", "uses", if (i % 10 == 0) "typescript" else "python", "data", "success", @intCast(i));
    var result = try runtime.activateWithStats(.{ .query = "typescript", .now = 999 }, 5, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.stats.candidates < 200);
    try std.testing.expectEqual(@as(usize, 5), result.stats.returned);
}

test "conflict resolution follows the active situation" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const old = try runtime.assert("user", "uses", "python", "legacy", 0.9);
    const current = try runtime.assert("user", "uses", "typescript", "browser", 0.7);
    try runtime.contradict(old, current);

    var browser = try runtime.activate(.{ .query = "uses", .situation = "browser", .now = 0 }, 2, std.testing.allocator);
    defer browser.deinit(std.testing.allocator);
    try std.testing.expectEqual(current, browser.items[0].id);
    try std.testing.expect(browser.items[1].signals.contradiction > browser.items[0].signals.contradiction);
}

test "event timestamp and persistence metadata remain stable" {
    const path = testPath("test-persistence.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    const first = try runtime.observe("u", "saw", "early", "lab", "", 100);
    _ = try runtime.observe("u", "saw", "late", "lab", "", 200);
    _ = try runtime.observe("u", "saw", "out-of-order", "lab", "", 50);
    try std.testing.expectEqual(@as(i64, 100), runtime.store.constNode(first).?.timestamp);
    try runtime.persist(std.testing.io, path);
    runtime.deinit();

    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    const next = try recovered.observe("u", "saw", "after reload", "lab", "", 300);
    try std.testing.expectEqual(@as(u64, 4), next);
    try std.testing.expectEqual(@as(i64, 300), recovered.store.constNode(next).?.timestamp);
}

test "persistence round trips delimiter and newline content" {
    const path = testPath("test-escaped-persistence.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    const id = try runtime.observe("u|ser", "notes", "line one\nline two", "a|context", "ok", 7);
    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    const node = recovered.store.constNode(id).?;
    try std.testing.expectEqualStrings("u|ser", node.subject);
    try std.testing.expectEqualStrings("line one\nline two", node.object);
    try std.testing.expectEqualStrings("a|context", node.context);
}

test "provider conformance lifecycle and persistence" {
    const path = testPath("test-provider-persistence.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("user", "uses", "typescript", "browser", "ok", 1);
    const related = try runtime.observe("user", "uses", "python", "data", "ok", 2);
    const claim = try runtime.assert("user", "prefers", "typescript", "browser", 0.9);
    try runtime.support(claim, related, 0.8);
    try runtime.persist(std.testing.io, path);
    try std.testing.expectEqualStrings("symbolic", runtime.backend.name());
    const providers = [_]enum { vector, graph }{ .vector, .graph };
    for (providers) |kind| {
        if (kind == .vector) try runtime.useVectorBackend() else try runtime.useGraphBackend();
        try std.testing.expect(runtime.backend.name().len > 0);
        var output = try runtime.activate(.{ .query = "typescript", .situation = "browser" }, 10, std.testing.allocator);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(output.items.len > 0);
        try runtime.backend.reset(&runtime.store);
        var candidates = try runtime.backend.candidates(&runtime.store, .{ .query = "typescript" }, std.testing.allocator);
        defer candidates.deinit(std.testing.allocator);
        try std.testing.expect(candidates.items.len > 0);
    }
}

test "indexed routing normalizes multi-token contextual queries" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const typescript = try runtime.observe("user", "builds", "TypeScript", "browser extension", "success", 1);
    _ = try runtime.observe("user", "uses", "python", "data", "success", 2);
    const context = meml.model.Context{ .query = "Build TypeScript,", .goal = "Browser Extension", .situation = "browser", .preferred = "TYPESCRIPT" };
    var indexed = try runtime.backend.candidates(&runtime.store, context, std.testing.allocator);
    defer indexed.deinit(std.testing.allocator);
    var found = false;
    for (indexed.items) |id| {
        if (id == typescript) found = true;
    }
    try std.testing.expect(found);

    const exhaustive = meml.backend.Symbolic.exhaustive();
    var all = try exhaustive.candidates(&runtime.store, context, std.testing.allocator);
    defer all.deinit(std.testing.allocator);
    try std.testing.expect(all.items.len >= indexed.items.len);
}

test "runtime write boundaries reject invalid numeric state" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const next_id = runtime.next_id;
    try std.testing.expectError(error.InvalidConfidence, runtime.assert("user", "trusts", "tool", "work", std.math.nan(f64)));
    try std.testing.expectError(error.InvalidConfidence, runtime.assert("user", "trusts", "tool", "work", 1.1));
    try std.testing.expectEqual(next_id, runtime.next_id);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.nodes.items.len);

    const first = try runtime.observe("user", "uses", "tool", "work", "success", 1);
    const second = try runtime.assert("user", "trusts", "tool", "work", 0.8);
    try std.testing.expectError(error.InvalidRelationWeight, runtime.support(first, second, std.math.inf(f64)));
    try std.testing.expectError(error.UnknownNode, runtime.support(first, 999, 0.5));
    try std.testing.expectEqual(@as(usize, 0), runtime.store.relations.items.len);
    try std.testing.expectError(error.InvalidSignalCalibration, runtime.setSignalCalibration(std.math.nan(f64), 0));
    try std.testing.expectError(error.InvalidSignalCalibration, runtime.setSignalCalibration(1, std.math.inf(f64)));
    try std.testing.expect(runtime.store.learnedSignal("calibrated") == null);
}

test "frozen provider contract is conformed to by every backend" {
    try std.testing.expectEqualStrings("MEML-ABI-1", meml.backend.Contract.version);
    try std.testing.expectEqual(@as(usize, 5), meml.backend.Contract.operations.len);
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("u", "uses", "typescript", "browser", "ok", 1);
    const providers = [_]meml.Backend{ meml.backend.Symbolic.exhaustive(), runtime.backend };
    for (providers) |provider| {
        try provider.reset(&runtime.store);
        var ids = try provider.candidates(&runtime.store, .{ .query = "typescript" }, std.testing.allocator);
        defer ids.deinit(std.testing.allocator);
        try std.testing.expect(ids.items.len > 0);
        for (ids.items) |id| try std.testing.expect(runtime.store.constNode(id) != null);
    }
}

test "kernel bounded propagation expands linked candidates after reload" {
    const path = testPath("test-graph-persistence.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    const source = try runtime.observe("u", "uses", "compiler", "build", "ok", 3);
    const linked = try runtime.observe("u", "needs", "cache", "build", "ok", 4);
    try runtime.support(source, linked, 1);
    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try recovered.useGraphBackend();
    var output = try recovered.activateWithStats(.{ .query = "compiler", .propagation = .{ .max_hops = 1, .edge_limit = 4, .candidate_limit = 4 } }, 10, std.testing.allocator);
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(output.items.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), output.stats.propagated);
    try std.testing.expect(output.stats.edges_examined <= 4);
}

test "configurable signals improve and measure retrieval" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const old = try runtime.observe("u", "uses", "python", "data", "ok", 1);
    const recent = try runtime.observe("u", "uses", "typescript", "browser", "ok", 2);
    try runtime.addSignalProvider(meml.signals.Metadata.provider());
    try runtime.addSignalProvider(meml.signals.Embedding.provider());
    var result = try runtime.activate(.{ .query = "typescript", .situation = "browser" }, 2, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(recent, result.items[0].id);
    try std.testing.expect(result.items[0].signals.external > 0);
    const report = try evaluation.evaluate(&runtime, &[_]evaluation.Case{ .{ .query = "typescript", .situation = "browser", .expected = recent }, .{ .query = "python", .situation = "data", .expected = old } }, 2, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), report.hits);
    try std.testing.expectEqual(@as(f64, 1), report.mrr());
    const accepted = evaluation.QualityGate{ .min_cases = 2, .min_recall = 1, .min_mrr = 1, .min_ndcg = 1 };
    const rejected = evaluation.QualityGate{ .min_cases = 3 };
    try std.testing.expect(accepted.accepts(report));
    try std.testing.expect(!rejected.accepts(report));
}

test "neural providers propose kernel memories and signals" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.assert("user", "prefers", "typescript", "browser", 0.8);
    _ = try runtime.assert("user", "prefers", "typescript", "browser", 0.9);
    const before = runtime.store.nodes.items.len;
    const committed = try runtime.consolidateNeural(meml.neural.Deterministic.consolidator());
    try std.testing.expectEqual(@as(usize, 1), committed);
    try std.testing.expect(runtime.store.nodes.items.len > before);
    const consolidated = runtime.store.nodes.items[runtime.store.nodes.items.len - 1];
    try std.testing.expectEqual(meml.Kind.belief, consolidated.kind);
    try std.testing.expectEqual(@as(usize, 2), runtime.store.relations.items.len);
    try runtime.addSignalProvider(meml.neural.retrievalProvider());
    var output = try runtime.activate(.{ .query = "typescript" }, 5, std.testing.allocator);
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(output.items.len > 0);
}

test "neural state persists and changes future neural retrieval" {
    const path = testPath("test-neural-state.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    _ = try runtime.assert("user", "prefers", "typescript", "browser", 0.8);
    _ = try runtime.assert("user", "prefers", "typescript", "browser", 0.9);
    try std.testing.expectEqual(@as(usize, 1), try runtime.consolidateNeural(meml.neural.Deterministic.consolidator()));
    try std.testing.expectEqual(@as(usize, 1), runtime.store.neural_states.items.len);
    const state = runtime.store.neural_states.items[0];
    try std.testing.expect(state.activation_count > 0);
    try std.testing.expect(state.strength > 0);

    try runtime.addSignalProvider(meml.neural.retrievalProvider());
    var with_state = try runtime.activate(.{ .query = "typescript" }, 5, std.testing.allocator);
    defer with_state.deinit(std.testing.allocator);
    var neural_signal: f64 = 0;
    for (with_state.items) |item| {
        if (item.id == state.artifact) neural_signal = item.signals.external;
    }
    try std.testing.expect(neural_signal > 0);

    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.store.neural_states.items.len);
    try std.testing.expectEqual(state.artifact, recovered.store.neural_states.items[0].artifact);
    try std.testing.expectEqual(state.activation_count, recovered.store.neural_states.items[0].activation_count);
    try std.testing.expectEqual(state.version, recovered.store.neural_states.items[0].version);
    try std.testing.expectApproxEqAbs(state.strength, recovered.store.neural_states.items[0].strength, 0.000001);

    try recovered.addSignalProvider(meml.neural.retrievalProvider());
    recovered.store.neural_states.clearRetainingCapacity();
    var without_state = try recovered.activate(.{ .query = "typescript" }, 5, std.testing.allocator);
    defer without_state.deinit(std.testing.allocator);
    var ablated_signal: f64 = 0;
    for (without_state.items) |item| {
        if (item.id == state.artifact) ablated_signal = item.signals.external;
    }
    try std.testing.expect(ablated_signal < neural_signal);
}

test "self-memory example executes, persists feedback, and remains retrievable after restart" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/self-memory.meml", std.testing.allocator, .limited(32 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "line-diagnostics-links-unlinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "plasticity-policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "evaluation supports-annotated-multitask-and-context-drift-suites") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "revision-cas") != null);

    const path = testPath("test-self-memory.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    runtime.setTransitionVerifier(trustedTransitionVerifier());
    var report = try meml.source.execute(&runtime, source, std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.feedback);
    try std.testing.expect(runtime.store.neural_states.items.len > 0);
    try runtime.persist(std.testing.io, path);
    runtime.deinit();

    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    var strategy_id: u64 = 0;
    var evidence_id: u64 = 0;
    for (recovered.store.nodes.items) |node| {
        if (node.kind == .claim and std.mem.eql(u8, node.predicate, "strategy-feedback")) strategy_id = node.id;
        if (node.kind == .evidence and std.mem.eql(u8, node.predicate, "strategy-feedback") and std.mem.eql(u8, node.result, "success")) evidence_id = node.id;
    }
    try std.testing.expect(strategy_id > 0 and evidence_id > 0);
    try std.testing.expect(runtimeHasRelation(&recovered, evidence_id, strategy_id, .supports));
    try std.testing.expect(recovered.store.constNode(strategy_id).?.confidence > 0.8);
    var activated = try recovered.activate(.{ .query = "strategy-feedback", .situation = "agent", .now = 20260824 }, 5, std.testing.allocator);
    defer activated.deinit(std.testing.allocator);
    var found_strategy = false;
    for (activated.items) |item| {
        if (item.id == strategy_id) found_strategy = true;
    }
    try std.testing.expect(found_strategy);
}

test "human-annotated evaluation accepts graded multi-task cases" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const browser = try runtime.assert("agent", "uses", "browser-tool", "browser", 0.9);
    const data = try runtime.assert("agent", "uses", "data-tool", "data", 0.9);
    const cases = [_]meml.AnnotatedCase{
        .{ .task_id = "browser-selection", .context = .{ .query = "browser-tool", .situation = "browser" }, .expected = browser, .relevance = 3 },
        .{ .task_id = "data-selection", .context = .{ .query = "data-tool", .situation = "data" }, .expected = data, .relevance = 2 },
    };
    const report = try evaluation.evaluateAnnotated(&runtime, &cases, 1, std.testing.allocator);
    const gate = evaluation.QualityGate{ .min_cases = 2, .min_recall = 1, .min_mrr = 1, .min_ndcg = 1 };
    try std.testing.expect(gate.accepts(report.asReport()));
    const invalid = [_]meml.AnnotatedCase{.{ .task_id = "bad", .context = .{}, .expected = browser, .relevance = 0 }};
    try std.testing.expectError(error.InvalidAnnotation, evaluation.evaluateAnnotated(&runtime, &invalid, 1, std.testing.allocator));
}

test "versioned annotation tasks calculate graded multi-label retrieval metrics" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const preferred = try runtime.assert("agent", "uses", "browser-tool", "browser", 0.9);
    const related = try runtime.assert("agent", "uses", "browser-helper", "browser", 0.5);
    const labels = [_]meml.RelevanceLabel{ .{ .expected = preferred, .relevance = 3 }, .{ .expected = related, .relevance = 1 } };
    const tasks = [_]meml.AnnotatedTask{.{ .task_id = "browser-retrieval-v1", .context = .{ .query = "browser", .situation = "browser" }, .labels = &labels }};
    const report = try evaluation.evaluateAnnotatedTasks(&runtime, &tasks, 2, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.tasks);
    try std.testing.expectApproxEqAbs(@as(f64, 1), report.recall(), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), report.mrr(), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), report.meanNdcg(), 0.000001);
    const duplicate_labels = [_]meml.RelevanceLabel{ .{ .expected = preferred, .relevance = 3 }, .{ .expected = preferred, .relevance = 1 } };
    const invalid = [_]meml.AnnotatedTask{.{ .task_id = "invalid-v1", .context = .{ .query = "browser" }, .labels = &duplicate_labels }};
    try std.testing.expectError(error.InvalidAnnotation, evaluation.evaluateAnnotatedTasks(&runtime, &invalid, 2, std.testing.allocator));
}

test "agent evaluation suite covers multiple tasks and contextual drift" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const report = try evaluation.evaluateAgentSuite(&runtime, std.testing.allocator);
    try std.testing.expect(report.passed());
}

test "long-horizon agent loop preserves verified feedback across restart" {
    const path = testPath("test-agent-loop.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const report = try evaluation.evaluateAgentLoop(&runtime, trustedFeedbackVerifier(), std.testing.allocator, std.testing.io, path);
    try std.testing.expect(report.passed());
}

test "long horizon self-hosting scenario preserves four memory stages" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const report = try evaluation.evaluateLongHorizon(&runtime, std.testing.allocator);
    try std.testing.expect(report.passed());
}

test "controlled causal evolution distinguishes structure from retrieval" {
    const path = testPath("test-causal-evolution.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const report = try evaluation.evaluateCausalEvolution(&runtime, std.testing.allocator, std.testing.io, path);

    // The controlled observe-only phase changes retrieval by adding raw
    // experiences, but does not create the later semantic structures.
    try std.testing.expectEqual(@as(usize, 0), report.baseline_results);
    try std.testing.expect(report.post_experience_results > report.baseline_results);
    try std.testing.expectEqual(@as(usize, 3), report.repeated_experience_nodes);
    try std.testing.expectEqual(@as(usize, 0), report.memory_nodes_after_observe);
    try std.testing.expectEqual(@as(usize, 0), report.belief_nodes_after_observe);
    try std.testing.expectEqual(@as(usize, 0), report.concept_nodes_after_observe);
    try std.testing.expectEqual(@as(usize, 0), report.procedure_nodes_after_observe);
    try std.testing.expectEqual(@as(usize, 0), report.relation_count_after_observe);

    // Explicit APIs and the proposal-based consolidator do work, but that is
    // evidence of callable capability, not automatic causal evolution.
    try std.testing.expect(report.explicit_beliefs > 0);
    try std.testing.expect(report.explicit_concepts > 0);
    try std.testing.expect(report.explicit_procedures > 0);
    try std.testing.expectEqual(@as(usize, 1), report.neural_committed);
    try std.testing.expect(report.restart_results > 0);
    try std.testing.expectEqual(@as(usize, 1), report.learned_neural_state_artifacts);
    try std.testing.expect(!report.automaticChainSupported());

    const names = [_][]const u8{
        "Experience -> Memory",                     "Repeated Experience -> Belief", "Belief -> Generalization",
        "Generalization -> Concept",                "Concept -> Procedure",          "Procedure -> Neural Consolidation",
        "Neural Consolidation -> Future Retrieval", "Restart Persistence",
    };
    for (names, report.statuses) |name, status| std.debug.print("causal-audit {s}: {s}\n", .{ name, @tagName(status) });
    std.debug.print("causal-audit observe-only nodes: experience={d} memory={d} belief={d} concept={d} procedure={d} relations={d}; retrieval {d}->{d}; restart={d}; learned-neural-state={d}\n", .{
        report.repeated_experience_nodes,      report.memory_nodes_after_observe,    report.belief_nodes_after_observe,
        report.concept_nodes_after_observe,    report.procedure_nodes_after_observe, report.relation_count_after_observe,
        report.baseline_results,               report.post_experience_results,       report.restart_results,
        report.learned_neural_state_artifacts,
    });
}

test "automatic causal consolidation mutates persistent memory structure" {
    const path = testPath("test-automatic-causal-consolidation.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    _ = try runtime.observe("agent", "performed", "deploy", "release", "success", 1);
    _ = try runtime.observe("agent", "performed", "deploy", "release", "success", 2);
    _ = try runtime.observe("agent", "performed", "rollback", "release", "success", 3);
    _ = try runtime.observe("agent", "performed", "rollback", "release", "success", 4);

    const report = try runtime.consolidateAll();
    try std.testing.expectEqual(@as(usize, 4), report.memories_created);
    try std.testing.expectEqual(@as(usize, 2), report.beliefs_created);
    try std.testing.expectEqual(@as(usize, 1), report.concepts_created);
    try std.testing.expectEqual(@as(usize, 1), report.procedures_created);
    try std.testing.expectEqual(@as(usize, 2), report.neural_artifacts_created);
    try std.testing.expectEqual(@as(usize, 4), countKindForTest(&runtime, .memory));
    try std.testing.expect(countKindForTest(&runtime, .belief) > 0);
    try std.testing.expect(countKindForTest(&runtime, .concept) > 0);
    try std.testing.expect(countKindForTest(&runtime, .procedure) > 0);
    try std.testing.expect(runtime.store.relations.items.len >= 8);

    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expect(countKindForTest(&recovered, .memory) > 0);
    try std.testing.expect(countKindForTest(&recovered, .belief) > 0);
    try std.testing.expect(countKindForTest(&recovered, .concept) > 0);
    try std.testing.expect(countKindForTest(&recovered, .procedure) > 0);
    var result = try recovered.activate(.{ .query = "deploy", .situation = "release", .now = 3 }, 8, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.items.len > 0);
}

test "event-triggered consolidation evolves memory during observe" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.enableAutoConsolidation(.{ .enable_concept = false, .enable_procedure = false, .enable_neural = false });

    _ = try runtime.observe("agent", "uses", "zig", "build", "success", 1);
    try std.testing.expectEqual(@as(usize, 0), countKindForTest(&runtime, .belief));
    _ = try runtime.observe("agent", "uses", "zig", "build", "success", 2);

    try std.testing.expectEqual(@as(usize, 2), countKindForTest(&runtime, .memory));
    try std.testing.expectEqual(@as(usize, 1), countKindForTest(&runtime, .belief));
    try std.testing.expect(runtime.store.relations.items.len >= 3);
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_experiences);
    runtime.disableAutoConsolidation();
}

test "token lexical ranking normalizes multi-word and case-variant queries" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const expected = try runtime.observe("agent", "builds", "TypeScript artifact", "browser", "success", 1);
    _ = try runtime.observe("agent", "builds", "Python package", "data", "success", 1);
    var result = try runtime.activate(.{ .query = "BUILD typescript" }, 2, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, result.items[0].id);
    try std.testing.expect(result.items[0].signals.lexical > 0.1);
}

test "hybrid backend unions lexical and vector candidates" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const expected = try runtime.observe("agent", "uses", "allocator memory", "runtime", "success", 1);
    _ = try runtime.observe("agent", "uses", "vector graphics", "ui", "success", 1);
    try runtime.useHybridBackend();
    try std.testing.expectEqualStrings("hybrid", runtime.backend.name());
    var candidates = try runtime.backend.candidates(&runtime.store, .{ .query = "ALLOCATOR" }, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    var found = false;
    for (candidates.items) |id| {
        if (id == expected) found = true;
    }
    try std.testing.expect(found);
}

const LocalEmbeddingTestCache = struct {
    fn query(_: *anyopaque, _: meml.Context) ?[]const f32 {
        return &[_]f32{ 1, 0 };
    }
    fn node(_: *anyopaque, id: u64) ?[]const f32 {
        return switch (id) {
            1 => &[_]f32{ 1, 0 },
            2 => &[_]f32{ 0, 1 },
            else => null,
        };
    }
};

const LocalSemanticTestIndex = struct {
    fn reset(_: *anyopaque, _: *const meml.Store) !void {}
    fn upsert(_: *anyopaque, _: *const meml.Store, _: u64) !void {}
    fn remove(_: *anyopaque, _: u64) void {}
    fn candidates(_: *anyopaque, _: *const meml.Store, _: meml.Context, allocator: std.mem.Allocator) !std.ArrayList(u64) {
        var ids = std.ArrayList(u64).empty;
        try ids.append(allocator, 2);
        return ids;
    }
};

test "host local semantic candidates compose with lexical routing" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const lexical = try runtime.observe("agent", "uses", "browser toolkit", "browser", "success", 1);
    const semantic = try runtime.observe("agent", "uses", "web automation", "browser", "success", 1);
    var local = meml.backend.LocalSemantic{
        .context = undefined,
        .model_version = "test-ann-v1",
        .model_sha256 = "test-sha256",
        .resetFn = LocalSemanticTestIndex.reset,
        .upsertFn = LocalSemanticTestIndex.upsert,
        .removeFn = LocalSemanticTestIndex.remove,
        .candidatesFn = LocalSemanticTestIndex.candidates,
    };
    var hybrid = meml.backend.Hybrid{ .left = runtime.backend, .right = local.provider() };
    try runtime.useCandidateBackend(hybrid.provider());
    try std.testing.expectEqualStrings("hybrid", runtime.backend.name());
    var candidates = try runtime.backend.candidates(&runtime.store, .{ .query = "toolkit" }, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    var found_lexical = false;
    var found_semantic = false;
    for (candidates.items) |id| {
        if (id == lexical) found_lexical = true;
        if (id == semantic) found_semantic = true;
    }
    try std.testing.expect(found_lexical);
    try std.testing.expect(found_semantic);
}

test "local embedding provider reranks cached vectors with provider trace" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const semantic_match = try runtime.observe("agent", "topic", "safe allocation", "runtime", "success", 1);
    _ = try runtime.observe("agent", "topic", "fast rendering", "ui", "success", 1);
    var cache = meml.signals.LocalEmbedding{
        .context = undefined,
        .model_version = "test-local-v1",
        .model_sha256 = "test-sha256",
        .queryFn = LocalEmbeddingTestCache.query,
        .nodeFn = LocalEmbeddingTestCache.node,
    };
    try runtime.addSignalProvider(cache.provider().weighted(2));
    var result = try runtime.activate(.{ .query = "topic" }, 2, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(semantic_match, result.items[0].id);
    try std.testing.expectEqual(@as(u8, 1), result.items[0].provider_trace.count);
    try std.testing.expectEqualStrings("test-local-v1", result.items[0].provider_trace.items[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2), result.items[0].provider_trace.items[0].weight, 0.000001);
    try std.testing.expect(result.items[0].signals.external > 0.9);
}

fn countKindForTest(runtime: *const meml.Runtime, kind: meml.Kind) usize {
    var count: usize = 0;
    for (runtime.store.nodes.items) |node| {
        if (node.kind == kind) count += 1;
    }
    return count;
}

test "consolidation is idempotent and provenance survives reload" {
    const path = testPath("test-consolidation-provenance.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 2);
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 1);
    const first = try runtime.consolidateAll();
    const record_count = runtime.store.consolidations.items.len;
    const second = try runtime.consolidateAll();
    try std.testing.expect(first.memories_created > 0);
    try std.testing.expect(first.neural_artifacts_created > 0);
    try std.testing.expectEqual(@as(usize, 0), second.memories_created);
    try std.testing.expectEqual(@as(usize, 0), second.beliefs_created);
    try std.testing.expectEqual(@as(usize, 0), second.concepts_created);
    try std.testing.expectEqual(@as(usize, 0), second.procedures_created);
    try std.testing.expectEqual(@as(usize, 0), second.neural_artifacts_created);
    try std.testing.expect(second.skipped);
    try std.testing.expectEqual(record_count, runtime.store.consolidations.items.len);
    try runtime.persist(std.testing.io, path);
    runtime.deinit();
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(record_count, recovered.store.consolidations.items.len);
    try std.testing.expectEqualStrings("experience-to-memory", recovered.store.consolidations.items[0].rule);
}

test "belief conflict lowers confidence and creates contradiction relation" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "python", "work", "success", 1);
    _ = try runtime.observe("agent", "uses", "python", "work", "success", 2);
    _ = try runtime.observe("agent", "uses", "zig", "work", "success", 3);
    _ = try runtime.observe("agent", "uses", "zig", "work", "success", 4);
    _ = try runtime.consolidateAll();
    var conflicts: usize = 0;
    for (runtime.store.relations.items) |relation| {
        if (relation.kind == .contradicts) conflicts += 1;
    }
    try std.testing.expect(conflicts > 0);
    var lowered: usize = 0;
    for (runtime.store.nodes.items) |node| {
        if (node.kind == .belief and node.confidence < 0.7) lowered += 1;
        if (node.kind == .belief and node.cognitive_state == .contested) try std.testing.expect(node.contradiction_count > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), lowered);
}

test "belief lifecycle states filter retrieval and survive persistence" {
    const path = testPath("test-belief-state.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    const old = try runtime.assert("agent", "uses", "old", "legacy", 0.9);
    const replacement = try runtime.assert("agent", "uses", "new", "current", 0.9);
    const old_belief = try runtime.infer(old);
    const new_belief = try runtime.infer(replacement);
    try runtime.supersedeBelief(old_belief, new_belief);
    try runtime.persist(std.testing.io, path);
    var output = try runtime.activate(.{ .query = "old", .situation = "legacy" }, 10, std.testing.allocator);
    defer output.deinit(std.testing.allocator);
    for (output.items) |item| try std.testing.expect(item.id != old_belief);
    runtime.deinit();

    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(meml.CognitiveState.superseded, recovered.store.constNode(old_belief).?.cognitive_state);
    try std.testing.expectEqual(meml.CognitiveState.active, recovered.store.constNode(new_belief).?.cognitive_state);
    try std.testing.expect(recovered.store.constNode(old_belief).?.last_confirmed_at >= 0);
}

test "conflicting beliefs remain active across different situations" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "python", "legacy", "success", 1);
    _ = try runtime.observe("agent", "uses", "python", "legacy", "success", 2);
    _ = try runtime.observe("agent", "uses", "typescript", "current", "success", 3);
    _ = try runtime.observe("agent", "uses", "typescript", "current", "success", 4);
    _ = try runtime.consolidateAll();

    var legacy_belief: u64 = 0;
    var current_belief: u64 = 0;
    for (runtime.store.nodes.items) |node| {
        if (node.kind != .belief or !std.mem.eql(u8, node.result, "consolidated repetition")) continue;
        if (std.mem.eql(u8, node.object, "python")) legacy_belief = node.id;
        if (std.mem.eql(u8, node.object, "typescript")) current_belief = node.id;
        try std.testing.expectEqual(meml.CognitiveState.active, node.cognitive_state);
    }
    try std.testing.expect(runtimeHasRelation(&runtime, legacy_belief, current_belief, .contradicts));

    var legacy = try runtime.activate(.{ .query = "uses", .situation = "legacy", .now = 4 }, 20, std.testing.allocator);
    defer legacy.deinit(std.testing.allocator);
    var current = try runtime.activate(.{ .query = "uses", .situation = "current", .now = 4 }, 20, std.testing.allocator);
    defer current.deinit(std.testing.allocator);
    const legacy_legacy_score = activationScore(&legacy, legacy_belief);
    const legacy_current_score = activationScore(&legacy, current_belief);
    const current_legacy_score = activationScore(&current, legacy_belief);
    const current_current_score = activationScore(&current, current_belief);
    try std.testing.expect(legacy_legacy_score > legacy_current_score);
    try std.testing.expect(current_current_score > current_legacy_score);
}

test "atomic consolidation rolls back injected failures and commits success" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 1);
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 2);
    const nodes_before = runtime.store.nodes.items.len;
    const relations_before = runtime.store.relations.items.len;
    const records_before = runtime.store.consolidations.items.len;
    try std.testing.expectError(error.InjectedConsolidationFailure, runtime.consolidateAllAtomic(.{ .abort_after_artifacts = 1 }));
    try std.testing.expectEqual(nodes_before, runtime.store.nodes.items.len);
    try std.testing.expectEqual(relations_before, runtime.store.relations.items.len);
    try std.testing.expectEqual(records_before, runtime.store.consolidations.items.len);
    try std.testing.expect(runtime.pending_experiences > 0);

    const committed = try runtime.consolidateAllAtomic(.{});
    try std.testing.expect(committed.memories_created > 0);
    try std.testing.expect(countKindForTest(&runtime, .memory) > 0);
    try std.testing.expect(runtime.pending_experiences == 0);
}

test "atomic consolidation fully restores neural state and IDs after failure" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 1);
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 2);
    const next_id = runtime.next_id;
    const pending = runtime.pending_experiences;
    try std.testing.expectError(error.InjectedConsolidationFailure, runtime.consolidateAllAtomic(.{ .abort_after_artifacts = 5 }));
    try std.testing.expectEqual(next_id, runtime.next_id);
    try std.testing.expectEqual(pending, runtime.pending_experiences);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.neural_states.items.len);
    try std.testing.expectEqual(@as(usize, 2), runtime.store.nodes.items.len);
    const report = try runtime.consolidateAllAtomic(.{});
    try std.testing.expect(report.neural_artifacts_created > 0);
    for (runtime.store.neural_states.items) |state| try std.testing.expect(runtime.store.constNode(state.artifact) != null);
}

test "strict persistence rejects malformed and dangling state" {
    const path = testPath("test-invalid-state.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const cases = [_][]const u8{
        "MEML15 0 2 0\nN|1|experience|agent|uses|tool|work|success|1|500000|500000|active|0|0|0|0|extra\n",
        "MEML15 0 2 0\nR|1|2|supports|1000000\n",
        "MEML15 0 2 0\nL|1|1|500000|1\n",
        "MEML15 0 2 0\nN|1|experience|agent|uses|tool|work|success|1|500000|500000|active|0|0|0\n",
    };
    for (cases) |input| {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
        defer file.close(std.testing.io);
        var buffer: [1024]u8 = undefined;
        var writer = file.writer(std.testing.io, &buffer);
        try writer.interface.writeAll(input);
        try writer.interface.flush();
        try std.testing.expectError(error.BadFile, meml.persistence.load(std.testing.allocator, std.testing.io, path));
    }
}

test "index checkpoint recovery discards corrupt, stale, and mismatched shards" {
    const path = testPath("test-index-checkpoint-recovery.state");
    const index = testPath("test-index-checkpoint-recovery.state.index");
    const index_journal = testPath("test-index-checkpoint-recovery.state.index.journal");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, index) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, index_journal) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "checkpoint-safe", "current", "success", 1);
    try runtime.persistAtomic(std.testing.io, path);
    try std.testing.expect(runtime.index_checkpoint_revision > 0);

    try writeTestFile(index_journal, "corrupt checkpoint\n");
    var corrupt_recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer corrupt_recovered.deinit();
    try std.testing.expectEqual(@as(u64, 1), corrupt_recovered.index_checkpoint_revision);
    try expectMissing(index_journal);
    var corrupt_results = try corrupt_recovered.activate(.{ .query = "checkpoint-safe" }, 1, std.testing.allocator);
    defer corrupt_results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), corrupt_results.items.len);

    try writeTestFile(index, "MEMLIDX1 0\n1\n");
    var stale_recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer stale_recovered.deinit();
    try std.testing.expectEqual(@as(u64, 0), stale_recovered.index_checkpoint_revision);
    try expectMissing(index);

    try writeTestFile(index, "MEMLIDX1 1\n1\n999\n");
    var mismatch_recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer mismatch_recovered.deinit();
    try std.testing.expectEqual(@as(u64, 0), mismatch_recovered.index_checkpoint_revision);
    try expectMissing(index);
}

test "journal recovery replays a complete interrupted state" {
    const path = testPath("test-journal-recovery.state");
    const journal = testPath("test-journal-recovery.state.journal");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, journal) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    const original = try runtime.observe("agent", "uses", "old", "legacy", "success", 1);
    try runtime.persistAtomic(std.testing.io, path);
    const newer = try runtime.observe("agent", "uses", "new", "current", "success", 2);
    try meml.persistence.save(&runtime.store, runtime.revision + 1, runtime.next_id, runtime.clock, std.testing.io, journal);
    runtime.deinit();

    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expect(recovered.store.constNode(original) != null);
    try std.testing.expect(recovered.store.constNode(newer) != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, journal, .{}));
}

test "atomic persistence rejects a concurrent writer and releases lock" {
    const path = testPath("test-persistence-lock.state");
    const lock_path = testPath("test-persistence-lock.state.lock");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lock_path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 1);
    var held = try std.Io.Dir.cwd().createFile(std.testing.io, lock_path, .{ .truncate = false, .exclusive = true, .lock = .exclusive, .lock_nonblocking = true });
    try std.testing.expectError(error.WouldBlock, runtime.persistAtomic(std.testing.io, path));
    held.close(std.testing.io);
    try runtime.persistAtomic(std.testing.io, path);
}

fn activationScore(result: *const std.ArrayList(meml.Activation), id: u64) f64 {
    for (result.items) |item| if (item.id == id) return item.score;
    return -1;
}

test "consolidation policy separates online and batch modes" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const batch = meml.Runtime.ConsolidationPolicy{ .auto_consolidate = false };
    const deferred = try runtime.observeAndConsolidate(batch, "agent", "uses", "tool", "work", "success", 1);
    try std.testing.expectEqual(@as(usize, 0), deferred.memories_created);
    try std.testing.expectEqual(@as(usize, 1), countKindForTest(&runtime, .experience));
    const online = meml.Runtime.ConsolidationPolicy{};
    _ = try runtime.observeAndConsolidate(online, "agent", "uses", "tool", "work", "success", 2);
    try std.testing.expect(countKindForTest(&runtime, .memory) > 0);

    var rules = meml.Runtime.init(std.testing.allocator);
    defer rules.deinit();
    _ = try rules.observe("agent", "uses", "tool", "work", "success", 1);
    _ = try rules.observe("agent", "uses", "tool", "work", "success", 2);
    const memory_only = meml.Runtime.ConsolidationPolicy{ .enable_belief = false, .enable_concept = false, .enable_procedure = false, .enable_neural = false };
    _ = try rules.consolidateWithPolicy(memory_only);
    try std.testing.expect(countKindForTest(&rules, .memory) > 0);
    try std.testing.expectEqual(@as(usize, 0), countKindForTest(&rules, .belief));
    _ = try rules.consolidateAll();
    try std.testing.expect(countKindForTest(&rules, .belief) > 0);
}

test "procedure induction requires success ratio and follows timestamps" {
    var failed = meml.Runtime.init(std.testing.allocator);
    defer failed.deinit();
    _ = try failed.observe("agent", "runs", "a", "job", "success", 1);
    _ = try failed.observe("agent", "runs", "b", "job", "failure", 2);
    _ = try failed.observe("agent", "runs", "c", "job", "failure", 3);
    _ = try failed.consolidateAll();
    try std.testing.expectEqual(@as(usize, 0), countKindForTest(&failed, .procedure));

    var ordered = meml.Runtime.init(std.testing.allocator);
    defer ordered.deinit();
    const last = try ordered.observe("agent", "runs", "last", "job", "success", 30);
    const first = try ordered.observe("agent", "runs", "first", "job", "success", 10);
    _ = try ordered.observe("agent", "runs", "middle", "job", "success", 20);
    _ = try ordered.consolidateAll();
    try std.testing.expectEqual(@as(usize, 1), countKindForTest(&ordered, .procedure));
    var follows = std.ArrayList(u64).empty;
    defer follows.deinit(std.testing.allocator);
    for (ordered.store.relations.items) |relation| {
        if (relation.kind == .follows) try follows.append(std.testing.allocator, relation.to);
    }
    try std.testing.expectEqual(@as(usize, 3), follows.items.len);
    try std.testing.expectEqual(first, follows.items[0]);
    try std.testing.expectEqual(last, follows.items[2]);
}

test "pending consolidation uses persisted fingerprint members after restart" {
    const path = testPath("test-pending-fingerprint-index.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 1);
    _ = try runtime.observe("agent", "uses", "tool", "work", "success", 2);
    _ = try runtime.observe("agent", "uses", "other", "work", "success", 3);
    _ = try runtime.consolidateAll();
    try runtime.persist(std.testing.io, path);
    runtime.deinit();

    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    _ = try recovered.observe("agent", "uses", "tool", "work", "success", 4);
    const report = try recovered.consolidatePending(.{});
    try std.testing.expectEqual(@as(usize, 3), report.scanned_experiences);
    try std.testing.expect(report.pending_experiences > 0);
    try std.testing.expect(!report.skipped);
    try std.testing.expectEqual(@as(usize, 0), recovered.pending_experiences);
    const skipped = try recovered.consolidatePending(.{});
    try std.testing.expect(skipped.skipped);
    try std.testing.expectEqual(@as(usize, 0), skipped.scanned_experiences);
}

test "pending group invalidates cross-group concept and procedure dependencies" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "does", "alpha", "job", "success", 1);
    _ = try runtime.observe("agent", "does", "alpha", "job", "success", 2);
    _ = try runtime.observe("agent", "does", "beta", "job", "success", 3);
    _ = try runtime.observe("agent", "does", "beta", "job", "success", 4);
    _ = try runtime.consolidateAll();
    try std.testing.expectEqual(@as(usize, 1), countKindForTest(&runtime, .concept));
    try std.testing.expectEqual(@as(usize, 1), countKindForTest(&runtime, .procedure));

    _ = try runtime.observe("agent", "does", "gamma", "job", "success", 5);
    _ = try runtime.observe("agent", "does", "gamma", "job", "success", 6);
    const report = try runtime.consolidatePending(.{});
    try std.testing.expectEqual(@as(usize, 2), report.scanned_experiences);
    try std.testing.expectEqual(@as(usize, 0), report.concepts_created);
    try std.testing.expectEqual(@as(usize, 0), report.procedures_created);

    var gamma_belief: u64 = 0;
    var concept: u64 = 0;
    var procedure: u64 = 0;
    for (runtime.store.nodes.items) |node| {
        if (node.kind == .belief and std.mem.eql(u8, node.object, "gamma") and std.mem.eql(u8, node.result, "consolidated repetition")) gamma_belief = node.id;
        if (node.kind == .concept) concept = node.id;
        if (node.kind == .procedure) procedure = node.id;
    }
    try std.testing.expect(gamma_belief > 0);
    try std.testing.expect(runtimeHasRelation(&runtime, concept, gamma_belief, .generalizes));
    try std.testing.expect(runtimeHasProcedureStepForObject(&runtime, procedure, "gamma"));
}

fn runtimeHasRelation(runtime: *const meml.Runtime, from: u64, to: u64, kind: meml.RelationKind) bool {
    for (runtime.store.relations.items) |relation| {
        if (relation.from == from and relation.to == to and relation.kind == kind) return true;
    }
    return false;
}

fn runtimeHasProcedureStepForObject(runtime: *const meml.Runtime, procedure: u64, object: []const u8) bool {
    for (runtime.store.relations.items) |relation| {
        if (relation.from == procedure and relation.kind == .follows) {
            if (runtime.store.constNode(relation.to)) |node| if (std.mem.eql(u8, node.object, object)) return true;
        }
    }
    return false;
}

test "source programs parse check and execute before mutating runtime" {
    const input =
        \\context browser {
        \\    query: uses
        \\    goal: browser
        \\    situation: browser
        \\    now: 20
        \\}
        \\observe user uses typescript browser success at 20
        \\signals metadata embedding
        \\activate browser top 1
    ;
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var report = try meml.source.execute(&runtime, input, std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.observed);
    try std.testing.expectEqual(@as(usize, 1), report.activations.items.len);
    try std.testing.expectEqual(@as(usize, 1), report.activations.items[0].items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.nodes.items.len);

    const invalid = "observe user uses python data success at 30\nactivate missing top 1\n";
    try std.testing.expectError(error.ValidationFailed, meml.source.execute(&runtime, invalid, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), runtime.store.nodes.items.len);
}

test "source labels links and diagnostics are validated before execution" {
    const input =
        \\observe user uses typescript browser success at 20 as browser_use
        \\assert user trusts typescript browser confidence 0.9 as browser_belief
        \\link browser_belief supports browser_use weight 0.8
    ;
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var report = try meml.source.execute(&runtime, input, std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), runtime.store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.relations.items.len);
    try std.testing.expectEqual(meml.model.RelationKind.supports, runtime.store.relations.items[0].kind);

    const invalid = "link missing supports missing weight 1\n";
    const compilation = meml.source.compile(invalid, std.testing.allocator);
    switch (compilation) {
        .program => unreachable,
        .diagnostic => |diagnostic| {
            try std.testing.expectEqual(meml.source.DiagnosticPhase.validation, diagnostic.phase);
            try std.testing.expectEqualStrings("InvalidLink", diagnostic.code);
            try std.testing.expectEqual(@as(usize, 1), diagnostic.span.line);
        },
    }
    try std.testing.expectError(error.ValidationFailed, meml.source.execute(&runtime, invalid, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 2), runtime.store.nodes.items.len);
}

test "memory imports replay multiple documents atomically without snapshot merging" {
    const documents = [_]meml.source.ImportDocument{
        .{ .name = "preferences.meml", .input = "observe user prefers zig systems success at 10 as preference\nassert user trusts zig systems confidence 0.9 as belief\nlink belief supports preference weight 0.8\n" },
        .{ .name = "history.meml", .input = "observe user uses typescript frontend success at 20\n" },
    };
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const report = try meml.source.importDocuments(&runtime, &documents, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), report.documents);
    try std.testing.expectEqual(@as(usize, 2), report.observed);
    try std.testing.expectEqual(@as(usize, 1), report.asserted);
    try std.testing.expectEqual(@as(usize, 1), report.links);
    try std.testing.expectEqual(@as(usize, 3), runtime.store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.relations.items.len);

    const invalid_documents = [_]meml.source.ImportDocument{
        .{ .name = "valid.meml", .input = "observe user uses python backend success at 30\n" },
        .{ .name = "not-memory-only.meml", .input = "consolidate\n" },
    };
    try std.testing.expectError(error.MemoryImportOnly, meml.source.importDocuments(&runtime, &invalid_documents, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 3), runtime.store.nodes.items.len);

    const cross_document_label = [_]meml.source.ImportDocument{
        .{ .name = "first.meml", .input = "observe user uses go backend success at 40 as go_use\n" },
        .{ .name = "second.meml", .input = "assert user trusts go backend confidence 0.8 as go_belief\nlink go_belief supports go_use\n" },
    };
    try std.testing.expectError(error.ValidationFailed, meml.source.importDocuments(&runtime, &cross_document_label, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 3), runtime.store.nodes.items.len);
}

test "source unlink removes explicit relation with precise lifecycle validation" {
    const input =
        \\assert agent uses browser-tool browser confidence 0.8 as strategy
        \\observe agent uses browser-tool browser success at 1 as experience
        \\link strategy supports experience weight 1
        \\unlink strategy supports experience
    ;
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var report = try meml.source.execute(&runtime, input, std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.relations.items.len);

    const invalid = "unlink missing supports missing\n";
    const compilation = meml.source.compile(invalid, std.testing.allocator);
    switch (compilation) {
        .program => unreachable,
        .diagnostic => |diagnostic| {
            try std.testing.expectEqual(meml.source.DiagnosticPhase.validation, diagnostic.phase);
            try std.testing.expectEqualStrings("InvalidLink", diagnostic.code);
            try std.testing.expectEqual(@as(usize, 1), diagnostic.span.line);
        },
    }
}

test "agent feedback becomes evidence and changes future strategy confidence" {
    const input =
        \\assert agent uses browser-automation browser confidence 0.6 as browser_strategy
        \\feedback browser_strategy success none actor trusted-agent receipt receipt-success at 10
        \\feedback browser_strategy failure tool_error actor trusted-agent receipt receipt-tool-error at 20
    ;
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    var report = try meml.source.execute(&runtime, input, std.testing.allocator);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), report.feedback);
    try std.testing.expectEqual(@as(usize, 3), runtime.store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 2), runtime.store.relations.items.len);
    const strategy = runtime.store.constNode(1).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), strategy.confidence, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), strategy.strength, 0.000001);
    try std.testing.expectEqual(@as(usize, 2), runtime.store.feedback_records.items.len);
    try std.testing.expectEqual(meml.FailureClass.tool_error, runtime.store.feedback_records.items[1].failure_class);
    try std.testing.expectEqualStrings("trusted-agent", runtime.store.feedback_records.items[0].actor);
    try std.testing.expectEqualStrings("receipt-tool-error", runtime.store.feedback_records.items[1].receipt);
    try std.testing.expect(runtimeHasRelation(&runtime, 2, 1, .supports));
    try std.testing.expect(runtimeHasRelation(&runtime, 3, 1, .contradicts));

    const invalid = "feedback missing success none actor trusted-agent receipt receipt-missing at 30\n";
    try std.testing.expectError(error.ValidationFailed, meml.source.execute(&runtime, invalid, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 3), runtime.store.nodes.items.len);
}

test "plasticity policy is domain-configurable and transaction-safe" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    try runtime.setPlasticityPolicy(.{ .success = .{ .adjustment = .reinforce, .amount = 0.2 }, .tool_error = .{ .state = .contested, .adjustment = .penalize, .amount = 0.5 } });
    const strategy = try runtime.assert("agent", "uses", "domain-tool", "browser", 0.6);
    _ = try runtime.recordFeedback(.{ .target = strategy, .outcome = .success, .failure_class = .none, .actor = "trusted-agent", .receipt = "receipt-domain-success", .timestamp = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), runtime.store.constNode(strategy).?.confidence, 0.000001);
    _ = try runtime.recordFeedback(.{ .target = strategy, .outcome = .failure, .failure_class = .tool_error, .actor = "trusted-agent", .receipt = "receipt-domain-failure", .timestamp = 2 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), runtime.store.constNode(strategy).?.confidence, 0.000001);
    try std.testing.expectError(error.InvalidPlasticityPolicy, runtime.setPlasticityPolicy(.{ .tool_error = .{ .adjustment = .penalize, .amount = std.math.nan(f64) } }));
    _ = try runtime.recordFeedback(.{ .target = strategy, .outcome = .failure, .failure_class = .tool_error, .actor = "trusted-agent", .receipt = "receipt-domain-failure-2", .timestamp = 3 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), runtime.store.constNode(strategy).?.confidence, 0.000001);
}

test "feedback writes without proof until a verifier policy is configured" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const target = try runtime.assert("agent", "uses", "default-feedback", "current", 0.5);
    _ = try runtime.recordFeedback(.{ .target = target, .outcome = .success, .failure_class = .none, .actor = "host", .receipt = "local-outcome-1", .timestamp = 1 });
    try std.testing.expectEqual(@as(usize, 1), runtime.store.feedback_records.items.len);
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    try std.testing.expectError(error.UntrustedFeedback, runtime.recordFeedback(.{ .target = target, .outcome = .success, .failure_class = .none, .actor = "forged-agent", .receipt = "local-outcome-2", .timestamp = 2 }));
    try std.testing.expectEqual(@as(usize, 1), runtime.store.feedback_records.items.len);
}

test "untrusted feedback is rejected without semantic mutation" {
    const input =
        \\assert agent uses protected-tool browser confidence 0.8 as strategy
        \\feedback strategy success none actor forged-agent receipt receipt-forged at 10
    ;
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(trustedFeedbackVerifier());
    try std.testing.expectError(error.UntrustedFeedback, meml.source.execute(&runtime, input, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), runtime.store.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.feedback_records.items.len);
    try std.testing.expectEqual(@as(u64, 1), runtime.next_id);
}

test "calibrated signal checkpoint persists and affects retrieval" {
    const path = testPath("test-calibrated-signal.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    _ = try runtime.observe("user", "uses", "typescript", "browser", "success", 10);
    try runtime.setSignalCalibration(1.5, 0.1);
    try runtime.addCalibratedSignalProvider();
    var before = try runtime.activate(.{ .query = "typescript", .situation = "browser", .now = 10 }, 1, std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    try std.testing.expect(before.items[0].signals.external > 0);
    try runtime.persist(std.testing.io, path);
    runtime.deinit();

    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expect(recovered.store.learnedSignal("calibrated") != null);
    const state = recovered.store.learnedSignal("calibrated").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.weight, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.bias, 0.000001);
    try recovered.addCalibratedSignalProvider();
    var after = try recovered.activate(.{ .query = "typescript", .situation = "browser", .now = 10 }, 1, std.testing.allocator);
    defer after.deinit(std.testing.allocator);
    try std.testing.expect(after.items[0].signals.external > 0);
    try std.testing.expectError(error.InvalidSignalCalibration, recovered.setSignalCalibration(-0.1, 0));
}

test "default runtime persistence is journaled and atomic" {
    const path = testPath("test-default-atomic.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-default-atomic.state.journal")) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "atomic-save", "local", "success", 1);
    try runtime.persist(std.testing.io, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, testPath("test-default-atomic.state.journal"), .{}));
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.store.nodes.items.len);
}

test "index checkpoint is revision-bound and rebuilt safely after restart" {
    const path = testPath("test-index-checkpoint.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-index-checkpoint.state.index")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-index-checkpoint.state.index.journal")) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.observe("agent", "uses", "index-checkpoint", "local", "success", 1);
    try runtime.persist(std.testing.io, path);
    try std.testing.expectEqual(runtime.revision, runtime.index_checkpoint_revision);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(recovered.revision, recovered.index_checkpoint_revision);
    var result = try recovered.activate(.{ .query = "index-checkpoint" }, 1, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
}

test "local storage provider persists semantic records through the provider contract" {
    const path = testPath("test-storage-provider.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const id = try runtime.observe("agent", "uses", "storage", "local", "success", 1);
    const provider = meml.storage.Local.provider();
    try runtime.persistTo(provider, std.testing.io, path);
    var loaded = try provider.recover(std.testing.allocator, std.testing.io, path);
    defer loaded.store.deinit();
    try std.testing.expectEqual(id, loaded.store.nodes.items[0].id);
    try std.testing.expectEqualStrings("storage", loaded.store.nodes.items[0].object);
}

test "versioned local provider rejects stale revision without replacing state" {
    const path = testPath("test-versioned-provider.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var first = meml.Runtime.init(std.testing.allocator);
    defer first.deinit();
    _ = try first.observe("agent", "uses", "first", "local", "success", 1);
    const provider = meml.storage.VersionedLocal.provider();
    try first.persistIfRevision(provider, 0, std.testing.io, path);
    try std.testing.expectEqual(@as(u64, 1), first.revision);
    try meml.persistence.save(&first.store, 1, first.next_id, first.clock, std.testing.io, testPath("test-versioned-provider.state.journal"));
    try meml.persistence.recoverJournal(std.testing.io, std.testing.allocator, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, testPath("test-versioned-provider.state.journal"), .{}));

    var stale = meml.Runtime.init(std.testing.allocator);
    defer stale.deinit();
    _ = try stale.observe("agent", "uses", "stale", "local", "success", 2);
    try std.testing.expectError(error.RevisionConflict, stale.persistIfRevision(provider, 0, std.testing.io, path));
    try std.testing.expectEqual(@as(u64, 0), stale.revision);

    var loaded = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded.revision);
    try std.testing.expectEqualStrings("first", loaded.store.nodes.items[0].object);
}

test "remote CAS timeout after commit recovers through authoritative revision" {
    const path = testPath("test-remote-cas-timeout.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-remote-cas-timeout.state.journal")) catch {};
    var remote = FaultingRemote{ .timeout_after_commit = true };
    var transport = remote.transport();
    const provider = meml.storage.Remote.provider(&transport);
    var writer = meml.Runtime.init(std.testing.allocator);
    defer writer.deinit();
    _ = try writer.observe("agent", "uses", "remote-timeout", "current", "success", 1);
    try std.testing.expectError(error.RemoteTimeout, writer.persistIfRevision(provider, 0, std.testing.io, path));
    try std.testing.expectEqual(@as(usize, 1), remote.persist_attempts);
    try std.testing.expectEqual(@as(usize, 1), remote.successful_commits);
    try std.testing.expectEqual(@as(u64, 1), try provider.loadRevision(std.testing.io, path));

    remote.timeout_after_commit = false;
    var recovered = try meml.Runtime.recoverFrom(std.testing.allocator, provider, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 1), recovered.revision);
    try std.testing.expectEqualStrings("remote-timeout", recovered.store.nodes.items[0].object);
    try std.testing.expectEqual(@as(usize, 1), remote.recover_attempts);
    _ = try recovered.observe("agent", "uses", "recovered-writer", "current", "success", 2);
    try recovered.persistIfRevision(provider, recovered.revision, std.testing.io, path);
    try std.testing.expectEqual(@as(u64, 2), try provider.loadRevision(std.testing.io, path));
}

test "remote CAS recovery failure leaves caller state untouched" {
    const path = testPath("test-remote-recover-failure.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var remote = FaultingRemote{ .fail_recover = true };
    var transport = remote.transport();
    const provider = meml.storage.Remote.provider(&transport);
    try std.testing.expectError(error.RemoteUnavailable, meml.Runtime.recoverFrom(std.testing.allocator, provider, std.testing.io, path));
    try std.testing.expectEqual(@as(usize, 1), remote.recover_attempts);
    try expectMissing(path);
}

test "remote transport adapter preserves revision CAS contract" {
    const path = testPath("test-remote-cas.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var transport = meml.storage.Remote.Transport{ .context = undefined, .loadRevisionFn = remoteLoadRevision, .persistIfRevisionFn = remotePersistIfRevision, .recoverFn = remoteRecover };
    const provider = meml.storage.Remote.provider(&transport);
    var writer = meml.Runtime.init(std.testing.allocator);
    defer writer.deinit();
    _ = try writer.observe("agent", "uses", "remote-transport", "service", "success", 1);
    try writer.persistIfRevision(provider, 0, std.testing.io, path);
    try std.testing.expectEqual(@as(u64, 1), try provider.loadRevision(std.testing.io, path));
    var recovered = try meml.Runtime.recoverFrom(std.testing.allocator, provider, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 1), recovered.revision);
    try std.testing.expectEqualStrings("remote-transport", recovered.store.nodes.items[0].object);
    try std.testing.expectEqual(@as(u64, 0), recovered.index_checkpoint_revision);

    var stale = meml.Runtime.init(std.testing.allocator);
    defer stale.deinit();
    _ = try stale.observe("agent", "uses", "stale-transport", "service", "success", 2);
    try std.testing.expectError(error.RevisionConflict, stale.persistIfRevision(provider, 0, std.testing.io, path));
    try std.testing.expectEqual(@as(u64, 0), stale.revision);
}

test "documented MEML examples parse and execute" {
    const paths = [_][]const u8{ "examples/contextual_retrieval.meml", "examples/self-memory.meml" };
    for (paths) |path| {
        const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(32 * 1024));
        defer std.testing.allocator.free(input);
        var runtime = meml.Runtime.init(std.testing.allocator);
        defer runtime.deinit();
        runtime.setFeedbackVerifier(trustedFeedbackVerifier());
        runtime.setTransitionVerifier(trustedTransitionVerifier());
        var report = try meml.source.execute(&runtime, input, std.testing.allocator);
        defer report.deinit(std.testing.allocator);
        try std.testing.expect(runtime.store.nodes.items.len > 0);
    }
}

test "structured records isolate scope and survive MEML15 recovery" {
    const path = testPath("test-structured-meml15.state");
    const journal = testPath("test-structured-meml15.state.journal");
    const index_journal = testPath("test-structured-meml15.state.index.journal");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, journal) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, index_journal) catch {};
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    const current_scopes = [_]meml.Scope{ .{ .key = "backend", .value = "alpha" }, .{ .key = "code", .value = "v2" } };
    const stale_scopes = [_]meml.Scope{ .{ .key = "backend", .value = "beta" }, .{ .key = "code", .value = "v1" } };
    const metrics = [_]meml.Metric{.{ .name = "quality", .value = 0.99, .unit = "ratio", .uncertainty = 0.01, .direction = .maximize }};
    const artifacts = [_]meml.Artifact{.{ .kind = "output", .digest = "0123456789abcdef" }};
    const current = try runtime.record(.{ .subject = "agent", .predicate = "uses", .object = "strategy", .context = "run", .result = "success", .timestamp = 10, .confidence = 0.8, .scopes = &current_scopes, .metrics = &metrics, .artifacts = &artifacts, .structure = .{ .kind = "workflow", .fingerprint = "fedcba9876543210" } });
    _ = try runtime.record(.{ .subject = "agent", .predicate = "uses", .object = "strategy", .context = "run", .result = "success", .timestamp = 10, .confidence = 0.8, .scopes = &stale_scopes });

    var activated = try runtime.activate(.{ .query = "strategy", .scopes = &current_scopes, .structure = .{ .kind = "workflow", .fingerprint = "fedcba9876543210" }, .now = 10 }, 2, std.testing.allocator);
    defer activated.deinit(std.testing.allocator);
    try std.testing.expectEqual(current, activated.items[0].id);
    try std.testing.expect(activated.items[0].signals.scope > 0.9);
    try std.testing.expect(activated.items[0].signals.metric > 0);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.artifact_records.items.len);

    try runtime.persist(std.testing.io, path);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 4), recovered.store.scoped_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.store.metric_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.store.artifact_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.store.structure_records.items.len);
}

test "model artifact manifest metadata survives semantic persistence" {
    const path = testPath("test-artifact-manifest.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-artifact-manifest.state.journal")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-artifact-manifest.state.index")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("test-artifact-manifest.state.index.journal")) catch {};
    const manifest = meml.ArtifactManifest{
        .provider = "deterministic-neural",
        .model_version = "v1",
        .checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .byte_length = 4096,
        .locator = "host-managed://checkpoints/neural-v1",
    };
    const data = try manifest.recordData();
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = try runtime.record(.{ .subject = "agent", .predicate = "uses", .object = "neural-provider", .context = "current", .timestamp = 1, .scopes = &data.scopes, .metrics = &data.metrics, .artifacts = &data.artifacts });
    try runtime.persist(std.testing.io, path);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), recovered.store.scoped_records.items.len);
    try std.testing.expectEqualStrings("model.version", recovered.store.scoped_records.items[0].scope.key);
    try std.testing.expectEqualStrings("provider", recovered.store.scoped_records.items[1].scope.key);
    try std.testing.expectEqual(@as(usize, 1), recovered.store.metric_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.store.artifact_records.items.len);
    try std.testing.expectEqualStrings(manifest.checksum, recovered.store.artifact_records.items[0].artifact.digest);
}

test "structured evaluation enforces explainable feasibility" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const scopes = [_]meml.Scope{.{ .key = "environment", .value = "current" }};
    const metrics = [_]meml.Metric{.{ .name = "quality", .value = 1, .direction = .maximize }};
    const expected = try runtime.record(.{ .subject = "agent", .predicate = "selects", .object = "method", .timestamp = 1, .scopes = &scopes, .metrics = &metrics, .structure = .{ .kind = "workflow", .fingerprint = "0123456789abcdef" } });
    const cases = [_]meml.StructuredCase{.{ .task_id = "structured-selection", .context = .{ .query = "method", .scopes = &scopes, .structure = .{ .kind = "workflow", .fingerprint = "0123456789abcdef" } }, .expected = expected, .min_scope = 1, .min_metric = 0.5, .min_structure = 1 }};
    const report = try meml.evaluation.evaluateStructured(&runtime, &cases, 1, std.testing.allocator);
    try std.testing.expect((meml.StructuredQualityGate{ .min_recall = 1, .min_feasibility = 1 }).accepts(report));
}

test "MEML15 loader rejects old state headers without compatibility" {
    const path = testPath("test-unsupported-version.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [128]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll("MEML12 0 1 0\n");
    try writer.interface.flush();
    try std.testing.expectError(error.UnsupportedVersion, meml.persistence.load(std.testing.allocator, std.testing.io, path));
}

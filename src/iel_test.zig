const std = @import("std");
const meml = @import("meml.zig");

fn verifyTrustedTransition(_: *anyopaque, input: meml.TransitionInput) !void {
    if (!std.mem.eql(u8, input.actor, "iel-test") or !std.mem.startsWith(u8, input.receipt, "receipt-")) return error.UntrustedTransition;
}

fn transitionVerifier() meml.TransitionVerifier {
    return .{ .context = undefined, .verifyFn = verifyTrustedTransition };
}

const artifacts_dir = "test-artifacts";
fn testPath(comptime name: []const u8) []const u8 {
    std.Io.Dir.cwd().createDirPath(std.testing.io, artifacts_dir) catch {};
    return artifacts_dir ++ "/" ++ name;
}

test "IEL stages A through E preserve information evolution across recovery" {
    const path = testPath("iel-evolution.state");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("iel-evolution.state.journal")) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, testPath("iel-evolution.state.index.journal")) catch {};

    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setTransitionVerifier(transitionVerifier());
    var evolution = meml.iel.Evolution.init(&runtime);

    const observation = try evolution.observe(.{
        .record = .{ .kind = .experience, .subject = "service", .predicate = "latency", .object = "high", .context = "release", .timestamp = 10, .confidence = 0.4 },
        .kind = .observation,
        .source = "telemetry",
        .valid_from = 10,
        .valid_until = 20,
    });
    const claim = try evolution.declare(.{
        .record = .{ .kind = .claim, .subject = "service", .predicate = "needs", .object = "rollback", .context = "release", .timestamp = 11, .confidence = 0.6 },
        .kind = .claim,
        .trust = .asserted,
        .retention = .long_term,
        .source = "operator",
    });
    const hypothesis = try evolution.derive(.{
        .record = .{ .kind = .belief, .subject = "service", .predicate = "root_cause", .object = "configuration", .context = "release", .timestamp = 12, .confidence = 0.45 },
        .kind = .hypothesis,
        .source = "analysis",
    }, observation);
    try evolution.corroborate(observation, claim, 13, "telemetry");
    try evolution.contradict(hypothesis, claim, 14, "analysis");

    const replacement = try evolution.declare(.{
        .record = .{ .kind = .claim, .subject = "service", .predicate = "needs", .object = "configuration-fix", .context = "release", .timestamp = 15, .confidence = 0.8 },
        .kind = .claim,
        .trust = .verified,
        .retention = .long_term,
        .source = "verified-diagnosis",
    });
    try evolution.supersede(claim, replacement, .{ .target = claim, .cause = replacement, .kind = .set_state, .target_state = .superseded, .reason = "verified replacement", .actor = "iel-test", .receipt = "receipt-supersede", .timestamp = 16 }, "verified-diagnosis");
    try evolution.changeLifecycle(.archive, .{ .target = replacement, .kind = .set_state, .target_state = .archived, .reason = "retained audit history", .actor = "iel-test", .receipt = "receipt-archive", .timestamp = 17 }, "retention-policy");

    const decision = try evolution.recordDecision(.{
        .record = .{ .subject = "release", .predicate = "decision", .object = "investigate", .context = "release", .timestamp = 18, .confidence = 0.7 },
        .kind = .decision,
        .trust = .asserted,
        .source = "planner",
    }, &[_]u64{ observation, replacement });
    _ = try evolution.recordFeedback(.{ .target = decision, .outcome = .success, .failure_class = .none, .actor = "host", .receipt = "receipt-decision", .timestamp = 19 }, "verified-host");
    try std.testing.expectEqual(meml.Kind.context, runtime.store.constNode(decision).?.kind);
    try std.testing.expectEqual(meml.Trust.corroborated, runtime.store.information(claim).?.trust);
    try std.testing.expectEqual(meml.Retention.archived, runtime.store.information(replacement).?.retention);
    try std.testing.expectEqual(meml.CognitiveState.superseded, runtime.store.constNode(claim).?.cognitive_state);
    try evolution.verifyMaterializedView();

    var candidates = try evolution.verificationCandidates(21, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    try std.testing.expect(candidates.items.len > 0);
    try std.testing.expectEqual(observation, candidates.items[0].information);
    try std.testing.expectEqualStrings("validity interval expired", candidates.items[0].reason);

    try runtime.persist(std.testing.io, path);
    var recovered = try meml.Runtime.recover(std.testing.allocator, std.testing.io, path);
    defer recovered.deinit();
    var restored = meml.iel.Evolution.init(&recovered);
    try restored.verifyMaterializedView();
    try std.testing.expectEqual(runtime.store.information_records.items.len, recovered.store.information_records.items.len);
    try std.testing.expectEqual(runtime.store.evolution_events.items.len, recovered.store.evolution_events.items.len);
    try std.testing.expectEqual(@as(usize, 2), recovered.store.decision_dependencies.items.len);
    try std.testing.expectEqual(meml.Trust.corroborated, recovered.store.information(claim).?.trust);
}

test "IEL decision recording rolls back when any dependency is invalid" {
    var runtime = meml.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var evolution = meml.iel.Evolution.init(&runtime);
    const evidence = try evolution.observe(.{
        .record = .{ .kind = .experience, .subject = "agent", .predicate = "saw", .object = "signal", .timestamp = 1 },
        .kind = .observation,
        .source = "test",
    });
    const node_count = runtime.store.nodes.items.len;
    const information_count = runtime.store.information_records.items.len;
    const event_count = runtime.store.evolution_events.items.len;
    try std.testing.expectError(error.InvalidDecisionDependency, evolution.recordDecision(.{
        .record = .{ .subject = "agent", .predicate = "decision", .object = "act", .timestamp = 2 },
        .kind = .decision,
        .source = "planner",
    }, &[_]u64{ evidence, 999 }));
    try std.testing.expectEqual(node_count, runtime.store.nodes.items.len);
    try std.testing.expectEqual(information_count, runtime.store.information_records.items.len);
    try std.testing.expectEqual(event_count, runtime.store.evolution_events.items.len);
}

const std = @import("std");
const meml = @import("meml.zig");

const Json = std.json;
const Value = Json.Value;
const ObjectMap = Json.ObjectMap;
const Array = Json.Array;
const Allocator = std.mem.Allocator;

/// Long-lived runtime state shared across all requests in one process.
const State = struct {
    allocator: Allocator,
    io: std.Io,
    runtime: meml.Runtime,
    trusted_actors: std.ArrayList([]const u8),
    receipt_prefix: []const u8 = "",

    fn init(allocator: Allocator, io: std.Io) State {
        return .{
            .allocator = allocator,
            .io = io,
            .runtime = meml.Runtime.init(allocator),
            .trusted_actors = .empty,
        };
    }

    fn deinit(self: *State) void {
        for (self.trusted_actors.items) |actor| self.allocator.free(actor);
        self.trusted_actors.deinit(self.allocator);
        if (self.receipt_prefix.len > 0) self.allocator.free(self.receipt_prefix);
        self.runtime.deinit();
    }
};

// ---------------------------------------------------------------------------
// JSON field extraction helpers. `ObjectMap` is a StringArrayHashMap(Value),
// so `get` returns a shallow-copied `?Value`.
// ---------------------------------------------------------------------------

fn fStr(o: ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn fOptStr(o: ObjectMap, key: []const u8) []const u8 {
    return fStr(o, key) orelse "";
}

fn fInt(o: ObjectMap, key: []const u8, default: i64) i64 {
    const v = o.get(key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        else => default,
    };
}

fn fU64(o: ObjectMap, key: []const u8, default: u64) u64 {
    const v = o.get(key) orelse return default;
    return switch (v) {
        .integer => |i| if (i < 0) default else @intCast(i),
        else => default,
    };
}

fn fF64(o: ObjectMap, key: []const u8, default: f64) f64 {
    const v = o.get(key) orelse return default;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => default,
    };
}

fn fBool(o: ObjectMap, key: []const u8, default: bool) bool {
    const v = o.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

fn fArray(o: ObjectMap, key: []const u8) ?Array {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .array => |arr| arr,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Output helpers.
// ---------------------------------------------------------------------------

fn writeValue(writer: *std.Io.Writer, v: Value) !void {
    try Json.Stringify.value(v, .{}, writer);
    try writer.writeAll("\n");
}

fn writeError(writer: *std.Io.Writer, a: Allocator, msg: []const u8) !void {
    var map = ObjectMap.empty;
    try map.put(a, "ok", .{ .bool = false });
    try map.put(a, "error", .{ .string = msg });
    try writeValue(writer, .{ .object = map });
}

fn okObject(a: Allocator) ObjectMap {
    var map = ObjectMap.empty;
    map.put(a, "ok", .{ .bool = true }) catch unreachable;
    return map;
}

// ---------------------------------------------------------------------------
// Feedback verifier. MEML treats the verifier as a host boundary: the CLI only
// accepts feedback whose actor is in `trusted_actors` and whose receipt carries
// the configured prefix.
// ---------------------------------------------------------------------------

fn verifierVerify(ctx: *anyopaque, input: meml.FeedbackInput) anyerror!void {
    const state: *State = @ptrCast(@alignCast(ctx));
    var actor_ok = false;
    for (state.trusted_actors.items) |actor| {
        if (std.mem.eql(u8, actor, input.actor)) {
            actor_ok = true;
            break;
        }
    }
    if (!actor_ok) return error.UntrustedActor;
    if (state.receipt_prefix.len > 0 and !std.mem.startsWith(u8, input.receipt, state.receipt_prefix))
        return error.UntrustedReceipt;
}

// ---------------------------------------------------------------------------
// Per-command handlers. Each builds a response ObjectMap in the request arena
// and writes it as one JSON line.
// ---------------------------------------------------------------------------

fn signalProvider(name: []const u8) !meml.SignalProvider {
    if (std.mem.eql(u8, name, "metadata")) return meml.signals.Metadata.provider();
    if (std.mem.eql(u8, name, "embedding")) return meml.signals.Embedding.provider();
    if (std.mem.eql(u8, name, "reranker")) return meml.signals.Reranker.provider();
    if (std.mem.eql(u8, name, "calibrated")) return meml.signals.Calibrated.provider();
    if (std.mem.eql(u8, name, "neural")) return meml.neural.retrievalProvider();
    return error.InvalidProvider;
}

fn encodeActivation(a: Allocator, runtime: *const meml.Runtime, act: meml.Activation, want_details: bool) !Value {
    var map = ObjectMap.empty;
    try map.put(a, "id", .{ .integer = @intCast(act.id) });
    try map.put(a, "score", .{ .float = act.score });

    var sig = ObjectMap.empty;
    try sig.put(a, "semantic", .{ .float = act.signals.semantic });
    try sig.put(a, "lexical", .{ .float = act.signals.lexical });
    try sig.put(a, "temporal", .{ .float = act.signals.temporal });
    try sig.put(a, "causal", .{ .float = act.signals.causal });
    try sig.put(a, "procedural", .{ .float = act.signals.procedural });
    try sig.put(a, "preference", .{ .float = act.signals.preference });
    try sig.put(a, "goal", .{ .float = act.signals.goal });
    try sig.put(a, "confidence", .{ .float = act.signals.confidence });
    try sig.put(a, "contradiction", .{ .float = act.signals.contradiction });
    try sig.put(a, "external", .{ .float = act.signals.external });
    try map.put(a, "signals", .{ .object = sig });

    if (want_details) {
        if (runtime.store.constNode(act.id)) |node| {
            try map.put(a, "kind", .{ .string = @tagName(node.kind) });
            try map.put(a, "subject", .{ .string = node.subject });
            try map.put(a, "predicate", .{ .string = node.predicate });
            try map.put(a, "object", .{ .string = node.object });
            try map.put(a, "context", .{ .string = node.context });
            try map.put(a, "result", .{ .string = node.result });
            try map.put(a, "confidence", .{ .float = node.confidence });
            try map.put(a, "strength", .{ .float = node.strength });
        }
    }
    return .{ .object = map };
}

fn cmdObserve(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const id = try state.runtime.observe(
        fOptStr(o, "subject"),
        fOptStr(o, "predicate"),
        fOptStr(o, "object"),
        fOptStr(o, "context"),
        fOptStr(o, "result"),
        fInt(o, "timestamp", 0),
    );
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "id", .{ .integer = @intCast(id) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdAssert(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const id = try state.runtime.assert(
        fOptStr(o, "subject"),
        fOptStr(o, "predicate"),
        fOptStr(o, "object"),
        fOptStr(o, "context"),
        fF64(o, "confidence", 1.0),
    );
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "id", .{ .integer = @intCast(id) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdLink(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const kind = std.meta.stringToEnum(meml.RelationKind, fOptStr(o, "kind")) orelse return error.InvalidRelationKind;
    try state.runtime.link(fU64(o, "from", 0), kind, fU64(o, "to", 0), fF64(o, "weight", 1.0));
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdUnlink(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const kind = std.meta.stringToEnum(meml.RelationKind, fOptStr(o, "kind")) orelse return error.InvalidRelationKind;
    try state.runtime.unlink(fU64(o, "from", 0), kind, fU64(o, "to", 0));
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdSupport(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    try state.runtime.support(fU64(o, "from", 0), fU64(o, "to", 0), fF64(o, "weight", 1.0));
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdContradict(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    try state.runtime.contradict(fU64(o, "from", 0), fU64(o, "to", 0));
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdRemember(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const id = try state.runtime.remember(fU64(o, "id", 0));
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "id", .{ .integer = @intCast(id) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdInfer(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const id = try state.runtime.infer(fU64(o, "id", 0));
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "id", .{ .integer = @intCast(id) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdSetBeliefState(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const s = std.meta.stringToEnum(meml.BeliefState, fOptStr(o, "state")) orelse return error.InvalidBeliefState;
    try state.runtime.setBeliefState(fU64(o, "id", 0), s);
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdSupersede(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    try state.runtime.supersedeBelief(fU64(o, "old", 0), fU64(o, "replacement", 0));
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdGeneralize(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const ids = try idList(a, o);
    const id = try state.runtime.generalize(ids, fOptStr(o, "concept"));
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "id", .{ .integer = @intCast(id) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdProcedure(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const ids = try idList(a, o);
    const id = try state.runtime.inferProcedure(ids, fOptStr(o, "name"));
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "id", .{ .integer = @intCast(id) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdActivate(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const ctx = meml.Context{
        .query = fOptStr(o, "query"),
        .goal = fOptStr(o, "goal"),
        .user = fOptStr(o, "user"),
        .situation = fOptStr(o, "situation"),
        .now = fInt(o, "now", 0),
        .preferred = fOptStr(o, "preferred"),
        .resolve_conflicts = fBool(o, "resolve_conflicts", true),
    };
    const limit: usize = @intCast(fU64(o, "limit", 10));
    const want_details = fBool(o, "details", false);

    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });

    if (fBool(o, "stats", false)) {
        const result = try state.runtime.activateWithStats(ctx, limit, a);
        try resp.put(a, "candidates", .{ .integer = @intCast(result.stats.candidates) });
        try resp.put(a, "scored", .{ .integer = @intCast(result.stats.scored) });
        try resp.put(a, "returned", .{ .integer = @intCast(result.stats.returned) });

        var arr = Array.init(a);
        for (result.items.items) |act| try arr.append(try encodeActivation(a, &state.runtime, act, want_details));
        try resp.put(a, "activations", .{ .array = arr });
    } else {
        const items = try state.runtime.activate(ctx, limit, a);
        var arr = Array.init(a);
        for (items.items) |act| try arr.append(try encodeActivation(a, &state.runtime, act, want_details));
        try resp.put(a, "activations", .{ .array = arr });
    }
    try writeValue(writer, .{ .object = resp });
}

fn cmdFeedback(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const outcome = std.meta.stringToEnum(meml.Outcome, fOptStr(o, "outcome")) orelse return error.InvalidOutcome;
    const failure_class = std.meta.stringToEnum(meml.FailureClass, fOptStr(o, "failure_class")) orelse return error.InvalidFailureClass;
    const evidence = try state.runtime.recordFeedback(.{
        .target = fU64(o, "target", 0),
        .outcome = outcome,
        .failure_class = failure_class,
        .actor = fOptStr(o, "actor"),
        .receipt = fOptStr(o, "receipt"),
        .timestamp = fInt(o, "timestamp", 0),
    });
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "evidence", .{ .integer = @intCast(evidence) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdConsolidate(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const policy = policyFrom(a, o);
    const report = try state.runtime.consolidateWithPolicy(policy);

    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try putReport(&resp, a, report);
    try writeValue(writer, .{ .object = resp });
}

fn cmdAutoConsolidate(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const enable = fBool(o, "enable", true);
    if (enable) {
        state.runtime.enableAutoConsolidation(policyFrom(a, o));
    } else {
        state.runtime.disableAutoConsolidation();
    }
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdSignals(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const arr = fArray(o, "providers") orelse return error.MissingProviders;
    var count: usize = 0;
    for (arr.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => return error.InvalidProvider,
        };
        try state.runtime.addSignalProvider(try signalProvider(name));
        count += 1;
    }
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "providers", .{ .integer = @intCast(count) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdBackend(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const backend = fOptStr(o, "backend");
    if (std.mem.eql(u8, backend, "vector")) {
        try state.runtime.useVectorBackend();
    } else if (std.mem.eql(u8, backend, "graph")) {
        try state.runtime.useGraphBackend();
    } else {
        return error.InvalidBackend;
    }
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdPersist(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const path = fOptStr(o, "path");
    if (path.len == 0) return error.MissingPath;
    if (fBool(o, "atomic", false)) {
        try state.runtime.persistAtomic(state.io, path);
    } else {
        try state.runtime.persist(state.io, path);
    }
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdRecover(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const path = fOptStr(o, "path");
    if (path.len == 0) return error.MissingPath;
    const fresh = try meml.Runtime.recover(state.allocator, state.io, path);
    state.runtime.deinit();
    state.runtime = fresh;
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdExec(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const program = fOptStr(o, "program");
    if (program.len == 0) return error.MissingProgram;
    const report = try meml.source.execute(&state.runtime, program, a);

    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "observed", .{ .integer = @intCast(report.observed) });
    try resp.put(a, "asserted", .{ .integer = @intCast(report.asserted) });
    try resp.put(a, "feedback", .{ .integer = @intCast(report.feedback) });
    try resp.put(a, "consolidated", .{ .integer = @intCast(report.consolidated) });
    try resp.put(a, "neural_artifacts", .{ .integer = @intCast(report.neural_artifacts) });
    try resp.put(a, "activation_groups", .{ .integer = @intCast(report.activations.items.len) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdSetVerifier(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    // Replace any previously configured trust rules.
    for (state.trusted_actors.items) |actor| state.allocator.free(actor);
    state.trusted_actors.clearRetainingCapacity();
    if (state.receipt_prefix.len > 0) {
        state.allocator.free(state.receipt_prefix);
        state.receipt_prefix = "";
    }

    if (fArray(o, "trusted_actors")) |arr| {
        for (arr.items) |item| {
            const name = switch (item) {
                .string => |s| s,
                else => return error.InvalidActor,
            };
            try state.trusted_actors.append(state.allocator, try state.allocator.dupe(u8, name));
        }
    }
    const prefix = fOptStr(o, "receipt_prefix");
    if (prefix.len > 0) state.receipt_prefix = try state.allocator.dupe(u8, prefix);

    state.runtime.setFeedbackVerifier(.{ .context = state, .verifyFn = verifierVerify });
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdClearVerifier(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    _ = o;
    state.runtime.clearFeedbackVerifier();
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdSetFeedbackPolicy(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const policy = meml.FeedbackPolicy{
        .success_increment = fF64(o, "success_increment", 0.1),
        .timeout_multiplier = fF64(o, "timeout_multiplier", 0.95),
        .transport_multiplier = fF64(o, "transport_multiplier", 0.9),
        .tool_error_multiplier = fF64(o, "tool_error_multiplier", 0.8),
        .invalid_result_multiplier = fF64(o, "invalid_result_multiplier", 0.7),
        .unknown_multiplier = fF64(o, "unknown_multiplier", 0.85),
        .neutral_multiplier = fF64(o, "neutral_multiplier", 1.0),
    };
    try state.runtime.setFeedbackPolicy(policy);
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdPing(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    _ = state;
    _ = o;
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "pong", .{ .bool = true });
    try writeValue(writer, .{ .object = resp });
}

// ---------------------------------------------------------------------------
// Small response helpers.
// ---------------------------------------------------------------------------

fn idList(a: Allocator, o: ObjectMap) ![]const u64 {
    const arr = fArray(o, "ids") orelse return error.MissingIds;
    const ids = try a.alloc(u64, arr.items.len);
    for (arr.items, 0..) |item, i| {
        ids[i] = switch (item) {
            .integer => |n| if (n < 0) return error.InvalidId else @intCast(n),
            else => return error.InvalidId,
        };
    }
    return ids;
}

fn policyFrom(a: Allocator, o: ObjectMap) meml.Runtime.ConsolidationPolicy {
    _ = a;
    const abort: ?usize = blk: {
        const v = o.get("abort_after_artifacts") orelse break :blk null;
        break :blk switch (v) {
            .integer => |n| if (n < 0) null else @intCast(n),
            else => null,
        };
    };
    return .{
        .repeat_threshold = @intCast(fU64(o, "repeat_threshold", 2)),
        .procedure_success_ratio = fF64(o, "procedure_success_ratio", 0.75),
        .auto_consolidate = fBool(o, "auto_consolidate", true),
        .enable_memory = fBool(o, "enable_memory", true),
        .enable_belief = fBool(o, "enable_belief", true),
        .enable_concept = fBool(o, "enable_concept", true),
        .enable_procedure = fBool(o, "enable_procedure", true),
        .enable_neural = fBool(o, "enable_neural", true),
        .abort_after_artifacts = abort,
    };
}

fn putReport(resp: *ObjectMap, a: Allocator, report: meml.Runtime.ConsolidationReport) !void {
    try resp.put(a, "scanned_experiences", .{ .integer = @intCast(report.scanned_experiences) });
    try resp.put(a, "pending_experiences", .{ .integer = @intCast(report.pending_experiences) });
    try resp.put(a, "skipped", .{ .bool = report.skipped });
    try resp.put(a, "memories_created", .{ .integer = @intCast(report.memories_created) });
    try resp.put(a, "beliefs_created", .{ .integer = @intCast(report.beliefs_created) });
    try resp.put(a, "concepts_created", .{ .integer = @intCast(report.concepts_created) });
    try resp.put(a, "procedures_created", .{ .integer = @intCast(report.procedures_created) });
    try resp.put(a, "neural_artifacts_created", .{ .integer = @intCast(report.neural_artifacts_created) });
}

// ---------------------------------------------------------------------------
// Dispatch.
// ---------------------------------------------------------------------------

fn dispatch(state: *State, op: []const u8, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    if (std.mem.eql(u8, op, "ping")) return cmdPing(state, o, a, writer);
    if (std.mem.eql(u8, op, "observe")) return cmdObserve(state, o, a, writer);
    if (std.mem.eql(u8, op, "assert")) return cmdAssert(state, o, a, writer);
    if (std.mem.eql(u8, op, "remember")) return cmdRemember(state, o, a, writer);
    if (std.mem.eql(u8, op, "infer")) return cmdInfer(state, o, a, writer);
    if (std.mem.eql(u8, op, "link")) return cmdLink(state, o, a, writer);
    if (std.mem.eql(u8, op, "unlink")) return cmdUnlink(state, o, a, writer);
    if (std.mem.eql(u8, op, "support")) return cmdSupport(state, o, a, writer);
    if (std.mem.eql(u8, op, "contradict")) return cmdContradict(state, o, a, writer);
    if (std.mem.eql(u8, op, "set_belief_state")) return cmdSetBeliefState(state, o, a, writer);
    if (std.mem.eql(u8, op, "supersede")) return cmdSupersede(state, o, a, writer);
    if (std.mem.eql(u8, op, "generalize")) return cmdGeneralize(state, o, a, writer);
    if (std.mem.eql(u8, op, "procedure")) return cmdProcedure(state, o, a, writer);
    if (std.mem.eql(u8, op, "activate")) return cmdActivate(state, o, a, writer);
    if (std.mem.eql(u8, op, "feedback")) return cmdFeedback(state, o, a, writer);
    if (std.mem.eql(u8, op, "consolidate")) return cmdConsolidate(state, o, a, writer);
    if (std.mem.eql(u8, op, "auto_consolidate")) return cmdAutoConsolidate(state, o, a, writer);
    if (std.mem.eql(u8, op, "signals")) return cmdSignals(state, o, a, writer);
    if (std.mem.eql(u8, op, "backend")) return cmdBackend(state, o, a, writer);
    if (std.mem.eql(u8, op, "persist")) return cmdPersist(state, o, a, writer);
    if (std.mem.eql(u8, op, "recover")) return cmdRecover(state, o, a, writer);
    if (std.mem.eql(u8, op, "exec")) return cmdExec(state, o, a, writer);
    if (std.mem.eql(u8, op, "set_verifier")) return cmdSetVerifier(state, o, a, writer);
    if (std.mem.eql(u8, op, "clear_verifier")) return cmdClearVerifier(state, o, a, writer);
    if (std.mem.eql(u8, op, "set_feedback_policy")) return cmdSetFeedbackPolicy(state, o, a, writer);
    return error.UnknownOp;
}

// ---------------------------------------------------------------------------
// Request processing. One JSON object per line in, one JSON object per line
// out. Each request runs in its own arena.
// ---------------------------------------------------------------------------

fn processLine(state: *State, line: []const u8, writer: *std.Io.Writer) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = Json.parseFromSlice(Value, a, trimmed, .{}) catch {
        try writeError(writer, a, "invalid json");
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try writeError(writer, a, "request must be a JSON object");
            return;
        },
    };

    const op = switch (obj.get("op") orelse {
        try writeError(writer, a, "missing 'op' field");
        return;
    }) {
        .string => |s| s,
        else => {
            try writeError(writer, a, "'op' must be a string");
            return;
        },
    };

    dispatch(state, op, obj, a, writer) catch |err| {
        try writeError(writer, a, @errorName(err));
    };
}

fn processAll(state: *State, input: []const u8, writer: *std.Io.Writer) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        try processLine(state, line, writer);
    }
}

const help_text =
    \\MEML CLI — a JSON-lines bridge to the MEML agent memory runtime.
    \\
    \\Usage:
    \\  meml-cli                 read JSON requests from stdin (one per line) until EOF
    \\  meml-cli '<json>'        process a single JSON request and exit
    \\  meml-cli --file <path>   read JSON requests from a file (one per line)
    \\
    \\Each request is a JSON object with an "op" field. Each response is one JSON
    \\line: {"ok":true,...} or {"ok":false,"error":"..."}.
    \\
    \\Ops: ping observe assert remember infer link unlink support contradict
    \\     set_belief_state supersede generalize procedure activate feedback
    \\     consolidate auto_consolidate signals backend persist recover exec
    \\     set_verifier clear_verifier set_feedback_policy
    \\
;

pub fn main(minimal: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(minimal.args);
    _ = args.next(); // skip program name
    const first = args.next();

    var state = State.init(allocator, io);
    defer state.deinit();

    var out_file = std.Io.File.stdout().writer(io, &.{});
    var out_writer = &out_file.interface;

    if (first) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out_writer.writeAll(help_text);
        } else if (std.mem.eql(u8, arg, "--file")) {
            const path = args.next() orelse return error.MissingFile;
            const input = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(64 << 20));
            defer allocator.free(input);
            try processAll(&state, input, out_writer);
        } else {
            try processLine(&state, arg, out_writer);
        }
    } else {
        var stdin = std.Io.File.stdin();
        var reader = stdin.reader(io, &.{});
        const input = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(64 << 20));
        defer allocator.free(input);
        try processAll(&state, input, out_writer);
    }
}

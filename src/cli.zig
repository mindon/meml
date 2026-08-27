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
    environ: std.process.Environ,
    runtime: meml.Runtime,
    trusted_actors: std.ArrayList([]const u8),
    receipt_prefix: []const u8 = "",

    fn init(allocator: Allocator, io: std.Io, environ: std.process.Environ) State {
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
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

fn fObject(o: ObjectMap, key: []const u8) ?ObjectMap {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .object => |map| map,
        else => null,
    };
}

fn defaultStatePath(environ: std.process.Environ, allocator: Allocator) ![]const u8 {
    const home = std.process.Environ.getAlloc(environ, allocator, "HOME") catch return error.HomeDirectoryUnavailable;
    return std.fmt.allocPrint(allocator, "{s}/.meml/state/memory.state", .{home});
}

fn requestedStatePath(environ: std.process.Environ, o: ObjectMap, allocator: Allocator) ![]const u8 {
    const explicit = fOptStr(o, "path");
    return if (explicit.len > 0) explicit else defaultStatePath(environ, allocator);
}

fn ensureParentDirectory(io: std.Io, path: []const u8) !void {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (separator == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, path[0..separator]);
}

fn requiredF64(o: ObjectMap, key: []const u8) !f64 {
    const value = o.get(key) orelse return error.MissingMetricValue;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => error.InvalidMetricValue,
    };
}

fn recordInputFromJson(a: Allocator, o: ObjectMap) !meml.RecordInput {
    var scopes = std.ArrayList(meml.Scope).empty;
    defer scopes.deinit(a);
    if (fArray(o, "scopes")) |items| {
        if (items.items.len > 16) return error.MetadataLimitExceeded;
        for (items.items) |item| {
            const scope = switch (item) {
                .object => |value| value,
                else => return error.InvalidScope,
            };
            try scopes.append(a, .{ .key = fStr(scope, "key") orelse return error.InvalidScope, .value = fStr(scope, "value") orelse return error.InvalidScope });
        }
    }
    var metrics = std.ArrayList(meml.Metric).empty;
    defer metrics.deinit(a);
    if (fArray(o, "metrics")) |items| {
        if (items.items.len > 32) return error.MetadataLimitExceeded;
        for (items.items) |item| {
            const metric = switch (item) {
                .object => |value| value,
                else => return error.InvalidMetric,
            };
            const direction = std.meta.stringToEnum(meml.MetricDirection, fOptStr(metric, "direction")) orelse if (fOptStr(metric, "direction").len == 0) meml.MetricDirection.neutral else return error.InvalidMetric;
            const uncertainty: ?f64 = if (metric.get("uncertainty")) |value| switch (value) {
                .float => |number| number,
                .integer => |number| @floatFromInt(number),
                else => return error.InvalidMetric,
            } else null;
            try metrics.append(a, .{ .name = fStr(metric, "name") orelse return error.InvalidMetric, .value = try requiredF64(metric, "value"), .unit = fOptStr(metric, "unit"), .uncertainty = uncertainty, .direction = direction });
        }
    }
    var artifacts = std.ArrayList(meml.Artifact).empty;
    defer artifacts.deinit(a);
    if (fArray(o, "artifacts")) |items| {
        if (items.items.len > 16) return error.MetadataLimitExceeded;
        for (items.items) |item| {
            const artifact = switch (item) {
                .object => |value| value,
                else => return error.InvalidArtifact,
            };
            try artifacts.append(a, .{ .kind = fStr(artifact, "kind") orelse return error.InvalidArtifact, .digest = fStr(artifact, "digest") orelse return error.InvalidArtifact, .locator = fOptStr(artifact, "locator") });
        }
    }
    const structure: ?meml.Structure = if (fObject(o, "structure")) |value| .{ .kind = fStr(value, "kind") orelse return error.InvalidStructure, .fingerprint = fStr(value, "fingerprint") orelse return error.InvalidStructure } else null;
    const kind = std.meta.stringToEnum(meml.Kind, fOptStr(o, "kind")) orelse if (fOptStr(o, "kind").len == 0) meml.Kind.experience else return error.InvalidKind;
    const input = meml.RecordInput{
        .kind = kind,
        .subject = fOptStr(o, "subject"),
        .predicate = fOptStr(o, "predicate"),
        .object = fOptStr(o, "object"),
        .context = fOptStr(o, "context"),
        .result = fOptStr(o, "result"),
        .timestamp = fInt(o, "timestamp", 0),
        .confidence = fF64(o, "confidence", 0.5),
        .scopes = try scopes.toOwnedSlice(a),
        .metrics = try metrics.toOwnedSlice(a),
        .artifacts = try artifacts.toOwnedSlice(a),
        .structure = structure,
    };
    return input;
}

fn contextScopesFromJson(a: Allocator, o: ObjectMap) ![]const meml.Scope {
    const items = fArray(o, "scopes") orelse return &.{};
    if (items.items.len > 16) return error.MetadataLimitExceeded;
    const scopes = try a.alloc(meml.Scope, items.items.len);
    for (items.items, 0..) |item, index| {
        const scope = switch (item) {
            .object => |value| value,
            else => return error.InvalidScope,
        };
        scopes[index] = .{ .key = fStr(scope, "key") orelse return error.InvalidScope, .value = fStr(scope, "value") orelse return error.InvalidScope };
    }
    return scopes;
}

fn contextStructureFromJson(o: ObjectMap) !?meml.Structure {
    const value = fObject(o, "structure") orelse return null;
    return .{ .kind = fStr(value, "kind") orelse return error.InvalidStructure, .fingerprint = fStr(value, "fingerprint") orelse return error.InvalidStructure };
}

fn propagationFromJson(o: ObjectMap) !meml.PropagationBudget {
    const value = fObject(o, "propagation") orelse return .{};
    const hops = fU64(value, "max_hops", 0);
    if (hops > 8) return error.InvalidPropagationBudget;
    return .{
        .seed_limit = @intCast(fU64(value, "seed_limit", 64)),
        .max_hops = @intCast(hops),
        .edge_limit = @intCast(fU64(value, "edge_limit", 256)),
        .candidate_limit = @intCast(fU64(value, "candidate_limit", 128)),
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

fn trustedReceipt(state: *const State, actor_name: []const u8, receipt: []const u8) !void {
    for (state.trusted_actors.items) |actor| {
        if (std.mem.eql(u8, actor, actor_name)) {
            if (state.receipt_prefix.len > 0 and !std.mem.startsWith(u8, receipt, state.receipt_prefix)) return error.UntrustedReceipt;
            return;
        }
    }
    return error.UntrustedActor;
}

fn verifierVerify(ctx: *anyopaque, input: meml.FeedbackInput) anyerror!void {
    const state: *State = @ptrCast(@alignCast(ctx));
    try trustedReceipt(state, input.actor, input.receipt);
}

fn transitionVerifierVerify(ctx: *anyopaque, input: meml.TransitionInput) anyerror!void {
    const state: *State = @ptrCast(@alignCast(ctx));
    try trustedReceipt(state, input.actor, input.receipt);
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
    try sig.put(a, "scope", .{ .float = act.signals.scope });
    try sig.put(a, "metric", .{ .float = act.signals.metric });
    try sig.put(a, "structure", .{ .float = act.signals.structure });
    try sig.put(a, "lineage", .{ .float = act.signals.lineage });
    try sig.put(a, "stability", .{ .float = act.signals.stability });
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
    const id = try state.runtime.record(try recordInputFromJson(a, o));
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

fn cmdTransition(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const kind = std.meta.stringToEnum(meml.TransitionKind, fOptStr(o, "kind")) orelse return error.InvalidTransitionKind;
    const target_state: ?meml.CognitiveState = if (o.get("target_state") != null) std.meta.stringToEnum(meml.CognitiveState, fOptStr(o, "target_state")) orelse return error.InvalidCognitiveState else null;
    const transition_id = try state.runtime.transition(.{
        .target = fU64(o, "target", 0),
        .kind = kind,
        .target_state = target_state,
        .amount = fF64(o, "amount", 0),
        .cause = if (o.get("cause")) |_| fU64(o, "cause", 0) else null,
        .reason = fOptStr(o, "reason"),
        .actor = fOptStr(o, "actor"),
        .receipt = fOptStr(o, "receipt"),
        .timestamp = fInt(o, "timestamp", 0),
    });
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "transition", .{ .integer = @intCast(transition_id) });
    try writeValue(writer, .{ .object = resp });
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

fn cmdPredictProcedure(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const context = meml.Context{ .scopes = try contextScopesFromJson(a, o) };
    const prediction = try state.runtime.predictProcedureAt(fU64(o, "procedure", 0), context, fInt(o, "cutoff", 0));
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "procedure", .{ .integer = @intCast(prediction.procedure) });
    try resp.put(a, "compatible", .{ .bool = prediction.compatible });
    try resp.put(a, "samples", .{ .integer = @intCast(prediction.samples) });
    try resp.put(a, "successes", .{ .integer = @intCast(prediction.successes) });
    try resp.put(a, "failures", .{ .integer = @intCast(prediction.failures) });
    try resp.put(a, "success_probability", .{ .float = prediction.success_probability });
    try resp.put(a, "evidence_coverage", .{ .float = prediction.evidence_coverage });
    try writeValue(writer, .{ .object = resp });
}

fn selectionGateFrom(o: ObjectMap) meml.ProcedureSelectionQualityGate {
    const value = fObject(o, "gate") orelse return .{};
    return .{
        .min_stability = fF64(value, "min_stability", 0.75),
        .min_samples = @intCast(fU64(value, "min_samples", 3)),
        .min_success_probability = fF64(value, "min_success_probability", 0.5),
        .min_evidence_coverage = fF64(value, "min_evidence_coverage", 0.5),
        .require_active = fBool(value, "require_active", true),
        .require_scope_compatibility = fBool(value, "require_scope_compatibility", true),
    };
}

fn encodeProcedureSelection(a: Allocator, selection: meml.ProcedureSelection) !Value {
    var object = ObjectMap.empty;
    try object.put(a, "procedure", .{ .integer = @intCast(selection.procedure) });
    if (selection.counterfactual_score) |score| try object.put(a, "counterfactual_score", .{ .float = score });
    if (selection.rank) |rank| try object.put(a, "rank", .{ .integer = @intCast(rank) });
    var stability = ObjectMap.empty;
    try stability.put(a, "state", .{ .string = @tagName(selection.stability.state) });
    try stability.put(a, "score", .{ .float = selection.stability.score });
    try stability.put(a, "support", .{ .integer = @intCast(selection.stability.support) });
    try stability.put(a, "contradiction", .{ .integer = @intCast(selection.stability.contradiction) });
    try object.put(a, "stability", .{ .object = stability });
    var history = ObjectMap.empty;
    try history.put(a, "samples", .{ .integer = @intCast(selection.history.samples) });
    try history.put(a, "success_probability", .{ .float = selection.history.success_probability });
    try history.put(a, "evidence_coverage", .{ .float = selection.history.evidence_coverage });
    try object.put(a, "history", .{ .object = history });
    var status = ObjectMap.empty;
    try status.put(a, "active", .{ .bool = selection.status.active });
    try status.put(a, "scope_compatible", .{ .bool = selection.status.scope_compatible });
    try status.put(a, "stability_sufficient", .{ .bool = selection.status.stability_sufficient });
    try status.put(a, "samples_sufficient", .{ .bool = selection.status.samples_sufficient });
    try status.put(a, "success_probability_sufficient", .{ .bool = selection.status.success_probability_sufficient });
    try status.put(a, "evidence_coverage_sufficient", .{ .bool = selection.status.evidence_coverage_sufficient });
    try status.put(a, "eligible", .{ .bool = selection.status.eligible() });
    try object.put(a, "status", .{ .object = status });
    return .{ .object = object };
}

fn cmdSelectProcedures(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const candidates = try idList(a, o);
    const context = meml.Context{ .scopes = try contextScopesFromJson(a, o) };
    var selections = try state.runtime.selectProcedures(candidates, context, selectionGateFrom(o), a);
    defer selections.deinit(a);
    var response = ObjectMap.empty;
    try response.put(a, "ok", .{ .bool = true });
    var values = Array.init(a);
    for (selections.items) |selection| try values.append(try encodeProcedureSelection(a, selection));
    try response.put(a, "selections", .{ .array = values });
    try writeValue(writer, .{ .object = response });
}

fn optionalF64(o: ObjectMap, key: []const u8) !?f64 {
    const value = o.get(key) orelse return null;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => error.InvalidProcedureObjective,
    };
}

fn comparisonObjectivesFrom(a: Allocator, o: ObjectMap) !std.ArrayList(meml.ProcedureObjective) {
    const input = fArray(o, "objectives") orelse return error.InvalidProcedureObjectives;
    if (input.items.len == 0 or input.items.len > 8) return error.InvalidProcedureObjectives;
    var objectives = std.ArrayList(meml.ProcedureObjective).empty;
    errdefer objectives.deinit(a);
    for (input.items) |item| {
        const value = switch (item) {
            .object => |object| object,
            else => return error.InvalidProcedureObjective,
        };
        const target_name = fStr(value, "target") orelse return error.InvalidProcedureObjective;
        const target: meml.ProcedureObjectiveTarget = if (std.mem.eql(u8, target_name, "stability")) .stability else if (std.mem.eql(u8, target_name, "success_probability")) .success_probability else if (std.mem.eql(u8, target_name, "evidence_coverage")) .evidence_coverage else if (std.mem.eql(u8, target_name, "metric")) .{ .metric = .{ .name = fStr(value, "name") orelse return error.InvalidProcedureObjective, .unit = fStr(value, "unit") orelse return error.InvalidProcedureObjective } } else return error.InvalidProcedureObjective;
        const direction = std.meta.stringToEnum(meml.MetricDirection, fOptStr(value, "direction")) orelse return error.InvalidProcedureObjective;
        try objectives.append(a, .{ .target = target, .direction = direction, .weight = try requiredF64(value, "weight"), .hard_limit = try optionalF64(value, "hard_limit") });
    }
    return objectives;
}

fn encodeProcedureComparison(a: Allocator, comparison: meml.ProcedureComparison) !Value {
    var object = ObjectMap.empty;
    try object.put(a, "procedure", .{ .integer = @intCast(comparison.procedure) });
    if (comparison.counterfactual_score) |score| try object.put(a, "counterfactual_score", .{ .float = score });
    if (comparison.rank) |rank| try object.put(a, "rank", .{ .integer = @intCast(rank) });
    var stability = ObjectMap.empty;
    try stability.put(a, "state", .{ .string = @tagName(comparison.stability.state) });
    try stability.put(a, "score", .{ .float = comparison.stability.score });
    try object.put(a, "stability", .{ .object = stability });
    var history = ObjectMap.empty;
    try history.put(a, "samples", .{ .integer = @intCast(comparison.history.samples) });
    try history.put(a, "success_probability", .{ .float = comparison.history.success_probability });
    try history.put(a, "evidence_coverage", .{ .float = comparison.history.evidence_coverage });
    try object.put(a, "history", .{ .object = history });
    var status = ObjectMap.empty;
    try status.put(a, "active", .{ .bool = comparison.status.active });
    try status.put(a, "scope_compatible", .{ .bool = comparison.status.scope_compatible });
    try status.put(a, "samples_sufficient", .{ .bool = comparison.status.samples_sufficient });
    try status.put(a, "objectives_sufficient", .{ .bool = comparison.status.objectives_sufficient });
    try status.put(a, "eligible", .{ .bool = comparison.status.eligible() });
    try object.put(a, "status", .{ .object = status });
    var assessments = Array.init(a);
    for (comparison.assessments[0..comparison.assessment_count]) |assessment| {
        var entry = ObjectMap.empty;
        if (assessment.observed_value) |value| try entry.put(a, "observed_value", .{ .float = value });
        if (assessment.uncertainty) |value| try entry.put(a, "uncertainty", .{ .float = value });
        if (assessment.conservative_value) |value| try entry.put(a, "conservative_value", .{ .float = value });
        if (assessment.normalized_value) |value| try entry.put(a, "normalized_value", .{ .float = value });
        try entry.put(a, "hard_limit_satisfied", .{ .bool = assessment.hard_limit_satisfied });
        try entry.put(a, "rejection", .{ .string = @tagName(assessment.rejection) });
        try assessments.append(.{ .object = entry });
    }
    try object.put(a, "assessments", .{ .array = assessments });
    return .{ .object = object };
}

fn cmdCompareProcedures(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const candidates = try idList(a, o);
    var objectives = try comparisonObjectivesFrom(a, o);
    defer objectives.deinit(a);
    const policy = meml.ProcedureComparisonPolicy{
        .require_active = fBool(o, "require_active", true),
        .require_scope_compatibility = fBool(o, "require_scope_compatibility", true),
        .min_samples = @intCast(fU64(o, "min_samples", 3)),
        .objectives = objectives.items,
    };
    const context = meml.Context{ .scopes = try contextScopesFromJson(a, o) };
    var comparisons = try state.runtime.compareProcedures(candidates, context, policy, a);
    defer comparisons.deinit(a);
    var response = ObjectMap.empty;
    try response.put(a, "ok", .{ .bool = true });
    var values = Array.init(a);
    for (comparisons.items) |comparison| try values.append(try encodeProcedureComparison(a, comparison));
    try response.put(a, "comparisons", .{ .array = values });
    try writeValue(writer, .{ .object = response });
}

fn cmdActivate(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const ctx = meml.Context{
        .query = fOptStr(o, "query"),
        .goal = fOptStr(o, "goal"),
        .user = fOptStr(o, "user"),
        .situation = fOptStr(o, "situation"),
        .now = fInt(o, "now", 0),
        .preferred = fOptStr(o, "preferred"),
        .scopes = try contextScopesFromJson(a, o),
        .structure = try contextStructureFromJson(o),
        .activation_policy = std.meta.stringToEnum(meml.ActivationPolicy, fOptStr(o, "activation_policy")) orelse if (fOptStr(o, "activation_policy").len == 0) .active_only else return error.InvalidActivationPolicy,
        .minimum_stability = fF64(o, "minimum_stability", 0),
        .propagation = try propagationFromJson(o),
        .resolve_conflicts = fBool(o, "resolve_conflicts", true),
    };
    const limit: usize = @intCast(fU64(o, "limit", 10));
    const want_details = fBool(o, "details", false);

    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });

    if (fBool(o, "stats", false)) {
        const result = try state.runtime.activateWithStats(ctx, limit, a);
        try resp.put(a, "candidates", .{ .integer = @intCast(result.stats.candidates) });
        try resp.put(a, "seeds", .{ .integer = @intCast(result.stats.seeds) });
        try resp.put(a, "propagated", .{ .integer = @intCast(result.stats.propagated) });
        try resp.put(a, "edges_examined", .{ .integer = @intCast(result.stats.edges_examined) });
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
    const path = try requestedStatePath(state.environ, o, a);
    try ensureParentDirectory(state.io, path);
    if (fBool(o, "atomic", false)) {
        try state.runtime.persistAtomic(state.io, path);
    } else {
        try state.runtime.persist(state.io, path);
    }
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdRecover(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const path = try requestedStatePath(state.environ, o, a);
    const fresh = try meml.Runtime.recover(state.allocator, state.io, path);
    state.runtime.deinit();
    state.runtime = fresh;
    try writeValue(writer, .{ .object = okObject(a) });
}

fn isSafeImportPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or !std.mem.endsWith(u8, path, ".meml")) return false;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn cmdImportMeml(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const files = fArray(o, "files") orelse return error.MissingImportFiles;
    if (files.items.len == 0 or files.items.len > 64) return error.InvalidImportFiles;

    var documents = std.ArrayList(meml.source.ImportDocument).empty;
    defer documents.deinit(a);
    var total_bytes: usize = 0;
    for (files.items) |value| {
        const path = switch (value) {
            .string => |text| text,
            else => return error.InvalidImportFiles,
        };
        if (!isSafeImportPath(path)) return error.UnsafeImportPath;
        const source = try std.Io.Dir.cwd().readFileAlloc(state.io, path, a, .limited(512 * 1024));
        total_bytes = std.math.add(usize, total_bytes, source.len) catch return error.ImportTooLarge;
        if (total_bytes > 4 * 1024 * 1024) return error.ImportTooLarge;
        try documents.append(a, .{ .name = path, .input = source });
    }

    const report = try meml.source.importDocuments(&state.runtime, documents.items, a);
    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "documents", .{ .integer = @intCast(report.documents) });
    try resp.put(a, "observed", .{ .integer = @intCast(report.observed) });
    try resp.put(a, "asserted", .{ .integer = @intCast(report.asserted) });
    try resp.put(a, "links", .{ .integer = @intCast(report.links) });
    try writeValue(writer, .{ .object = resp });
}

fn cmdExec(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const program = fOptStr(o, "program");
    if (program.len == 0) return error.MissingProgram;
    var report = try meml.source.execute(&state.runtime, program, a);
    defer report.deinit(a);

    var resp = ObjectMap.empty;
    try resp.put(a, "ok", .{ .bool = true });
    try resp.put(a, "observed", .{ .integer = @intCast(report.observed) });
    try resp.put(a, "asserted", .{ .integer = @intCast(report.asserted) });
    try resp.put(a, "feedback", .{ .integer = @intCast(report.feedback) });
    try resp.put(a, "transitions", .{ .integer = @intCast(report.transitions) });
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
    state.runtime.setTransitionVerifier(.{ .context = state, .verifyFn = transitionVerifierVerify });
    try writeValue(writer, .{ .object = okObject(a) });
}

fn cmdClearVerifier(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    _ = o;
    state.runtime.clearFeedbackVerifier();
    state.runtime.clearTransitionVerifier();
    try writeValue(writer, .{ .object = okObject(a) });
}

fn plasticityRuleFrom(o: ObjectMap, key: []const u8, default_rule: meml.PlasticityRule) !meml.PlasticityRule {
    const value = fObject(o, key) orelse return default_rule;
    const state_value: ?meml.CognitiveState = if (value.get("state") != null) std.meta.stringToEnum(meml.CognitiveState, fOptStr(value, "state")) orelse return error.InvalidCognitiveState else null;
    const adjustment: ?meml.TransitionKind = if (value.get("adjustment") != null) std.meta.stringToEnum(meml.TransitionKind, fOptStr(value, "adjustment")) orelse return error.InvalidTransitionKind else null;
    return .{ .state = state_value, .adjustment = adjustment, .amount = fF64(value, "amount", 0) };
}

fn cmdSetPlasticityPolicy(state: *State, o: ObjectMap, a: Allocator, writer: *std.Io.Writer) !void {
    const defaults = meml.PlasticityPolicy{};
    const policy = meml.PlasticityPolicy{
        .success = try plasticityRuleFrom(o, "success", defaults.success),
        .timeout = try plasticityRuleFrom(o, "timeout", defaults.timeout),
        .transport = try plasticityRuleFrom(o, "transport", defaults.transport),
        .tool_error = try plasticityRuleFrom(o, "tool_error", defaults.tool_error),
        .invalid_result = try plasticityRuleFrom(o, "invalid_result", defaults.invalid_result),
        .policy_denied = try plasticityRuleFrom(o, "policy_denied", defaults.policy_denied),
        .unauthorized = try plasticityRuleFrom(o, "unauthorized", defaults.unauthorized),
        .cancelled = try plasticityRuleFrom(o, "cancelled", defaults.cancelled),
        .unknown = try plasticityRuleFrom(o, "unknown", defaults.unknown),
    };
    try state.runtime.setPlasticityPolicy(policy);
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
    if (std.mem.eql(u8, op, "transition")) return cmdTransition(state, o, a, writer);
    if (std.mem.eql(u8, op, "supersede")) return cmdSupersede(state, o, a, writer);
    if (std.mem.eql(u8, op, "generalize")) return cmdGeneralize(state, o, a, writer);
    if (std.mem.eql(u8, op, "procedure")) return cmdProcedure(state, o, a, writer);
    if (std.mem.eql(u8, op, "predict_procedure")) return cmdPredictProcedure(state, o, a, writer);
    if (std.mem.eql(u8, op, "select_procedures")) return cmdSelectProcedures(state, o, a, writer);
    if (std.mem.eql(u8, op, "compare_procedures")) return cmdCompareProcedures(state, o, a, writer);
    if (std.mem.eql(u8, op, "activate")) return cmdActivate(state, o, a, writer);
    if (std.mem.eql(u8, op, "feedback")) return cmdFeedback(state, o, a, writer);
    if (std.mem.eql(u8, op, "consolidate")) return cmdConsolidate(state, o, a, writer);
    if (std.mem.eql(u8, op, "auto_consolidate")) return cmdAutoConsolidate(state, o, a, writer);
    if (std.mem.eql(u8, op, "signals")) return cmdSignals(state, o, a, writer);
    if (std.mem.eql(u8, op, "backend")) return cmdBackend(state, o, a, writer);
    if (std.mem.eql(u8, op, "persist")) return cmdPersist(state, o, a, writer);
    if (std.mem.eql(u8, op, "recover")) return cmdRecover(state, o, a, writer);
    if (std.mem.eql(u8, op, "import_meml")) return cmdImportMeml(state, o, a, writer);
    if (std.mem.eql(u8, op, "exec")) return cmdExec(state, o, a, writer);
    if (std.mem.eql(u8, op, "set_verifier")) return cmdSetVerifier(state, o, a, writer);
    if (std.mem.eql(u8, op, "clear_verifier")) return cmdClearVerifier(state, o, a, writer);
    if (std.mem.eql(u8, op, "set_plasticity_policy")) return cmdSetPlasticityPolicy(state, o, a, writer);
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

fn processReader(state: *State, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => break,
                    error.ReadFailed => |cause| return cause,
                };
                try writer.writeAll("{\"ok\":false,\"error\":\"request too large\"}\n");
                continue;
            },
            error.EndOfStream => break,
            error.ReadFailed => |cause| return cause,
        };
        try processLine(state, line, writer);
        reader.toss(@min(1, reader.bufferedLen()));
    }
}

const help_text =
    \\MEML CLI — a JSON-lines bridge to the MEML agent memory runtime.
    \\
    \\Usage:
    \\  meml                 read JSON requests from stdin (one per line) until EOF
    \\  meml '<json>'        process a single JSON request and exit
    \\  meml --file <path>   read JSON requests from a file (one per line)
    \\
    \\Each request is a JSON object with an "op" field. Each response is one JSON
    \\line: {"ok":true,...} or {"ok":false,"error":"..."}.
    \\
    \\Ops: ping observe assert remember infer link unlink support contradict
    \\     transition supersede generalize procedure predict_procedure select_procedures compare_procedures activate feedback
    \\     consolidate auto_consolidate signals backend persist recover import_meml exec
    \\     set_verifier clear_verifier set_plasticity_policy
    \\
;

pub fn main(minimal: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(minimal.args, allocator);
    defer args.deinit();
    _ = args.next(); // skip program name
    const first = args.next();

    var state = State.init(allocator, io, minimal.environ);
    defer state.deinit();

    var out_file = std.Io.File.stdout().writer(io, &.{});
    var out_writer = &out_file.interface;

    if (first) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out_writer.writeAll(help_text);
        } else if (std.mem.eql(u8, arg, "--file")) {
            const path = args.next() orelse return error.MissingFile;
            var input_file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer input_file.close(io);
            var input_buffer: [64 * 1024]u8 = undefined;
            var reader = input_file.reader(io, &input_buffer);
            try processReader(&state, &reader.interface, out_writer);
        } else {
            try processLine(&state, arg, out_writer);
        }
    } else {
        var stdin = std.Io.File.stdin();
        var input_buffer: [64 * 1024]u8 = undefined;
        var reader = stdin.reader(io, &input_buffer);
        try processReader(&state, &reader.interface, out_writer);
    }
}

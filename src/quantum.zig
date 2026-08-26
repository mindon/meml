const std = @import("std");
const model = @import("model.zig");
const science = @import("science.zig");

/// Optional quantum adapter. Quantum terms are confined here rather than in
/// the MEML kernel, and are emitted as ordinary scopes, metrics, artifacts,
/// and a structure fingerprint.
pub const CompilationInput = struct {
    backend: []const u8,
    calibration: []const u8,
    compiler: []const u8,
    circuit_digest: []const u8,
    topology_fingerprint: []const u8,
    depth: f64,
    two_qubit_gates: f64,
    fidelity: ?f64 = null,
    timestamp: i64,
};

/// Caller-owned buffers make the returned record safe to pass directly into
/// `Runtime.record` or `science.Adapter.record` without heap allocation.
pub const CompilationStorage = struct {
    scopes: [3]model.Scope = undefined,
    metrics: [3]model.Metric = undefined,
    artifacts: [1]model.Artifact = undefined,
};

pub fn compilationRecord(input: CompilationInput, storage: *CompilationStorage) model.RecordInput {
    storage.scopes = .{
        .{ .key = "backend", .value = input.backend },
        .{ .key = "calibration", .value = input.calibration },
        .{ .key = "compiler", .value = input.compiler },
    };
    storage.metrics = if (input.fidelity) |fidelity| .{
        .{ .name = "depth", .value = input.depth, .direction = .minimize },
        .{ .name = "fidelity", .value = fidelity, .direction = .maximize },
        .{ .name = "two_qubit_gates", .value = input.two_qubit_gates, .direction = .minimize },
    } else .{
        .{ .name = "depth", .value = input.depth, .direction = .minimize },
        .{ .name = "two_qubit_gates", .value = input.two_qubit_gates, .direction = .minimize },
        .{ .name = "unused", .value = 0 },
    };
    storage.artifacts = .{.{ .kind = "circuit", .digest = input.circuit_digest }};
    const metric_count: usize = if (input.fidelity == null) 2 else 3;
    return .{
        .subject = "compiler",
        .predicate = "produced_strategy",
        .object = input.circuit_digest,
        .context = input.backend,
        .result = "compiled",
        .timestamp = input.timestamp,
        .scopes = storage.scopes[0..],
        .metrics = storage.metrics[0..metric_count],
        .artifacts = storage.artifacts[0..],
        .structure = .{ .kind = "topology", .fingerprint = input.topology_fingerprint },
    };
}

fn name(_: *anyopaque) []const u8 {
    return "quantum";
}

fn normalize(_: *anyopaque, input: model.RecordInput) !model.RecordInput {
    try science.validateRecord(input);
    if (input.structure) |structure| {
        if (!std.mem.eql(u8, structure.kind, "topology") and !std.mem.eql(u8, structure.kind, "circuit-dag")) return error.InvalidQuantumStructure;
    }
    return input;
}

pub fn adapter() science.Adapter {
    return .{ .context = undefined, .nameFn = name, .normalizeFn = normalize };
}

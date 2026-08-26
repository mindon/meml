const std = @import("std");
const model = @import("model.zig");
const runtime_mod = @import("runtime.zig");

/// Adapter contract for domain packages. Adapters may validate and normalize a
/// RecordInput, but Runtime remains the sole state-mutation boundary.
pub const Adapter = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    normalizeFn: *const fn (*anyopaque, model.RecordInput) anyerror!model.RecordInput,

    pub fn name(self: Adapter) []const u8 {
        return self.nameFn(self.context);
    }

    pub fn normalize(self: Adapter, input: model.RecordInput) !model.RecordInput {
        return self.normalizeFn(self.context, input);
    }

    pub fn record(self: Adapter, runtime: *runtime_mod.Runtime, input: model.RecordInput) !u64 {
        return runtime.record(try self.normalize(input));
    }
};

/// Shared validation used by scientific, engineering, and ordinary agent
/// adapters. It intentionally does not assume a domain ontology.
pub fn validateRecord(input: model.RecordInput) !void {
    if (input.subject.len == 0 or input.predicate.len == 0 or input.object.len == 0) return error.InvalidRecord;
    if (input.scopes.len > 16 or input.metrics.len > 32 or input.artifacts.len > 16) return error.MetadataLimitExceeded;
    for (input.scopes, 0..) |scope, index| {
        if (!validText(scope.key, 96) or !validText(scope.value, 512)) return error.InvalidScope;
        if (index > 0 and std.mem.order(u8, input.scopes[index - 1].key, scope.key) != .lt) return error.NonCanonicalScopes;
    }
    for (input.metrics, 0..) |metric, index| {
        if (!validText(metric.name, 96) or metric.unit.len > 64 or !std.math.isFinite(metric.value)) return error.InvalidMetric;
        if (metric.uncertainty) |uncertainty| if (!std.math.isFinite(uncertainty) or uncertainty < 0) return error.InvalidMetric;
        if (index > 0) {
            const previous = input.metrics[index - 1];
            const order = std.mem.order(u8, previous.name, metric.name);
            if (order == .gt or (order == .eq and std.mem.order(u8, previous.unit, metric.unit) != .lt)) return error.NonCanonicalMetrics;
        }
    }
    for (input.artifacts, 0..) |artifact, index| {
        if (!validText(artifact.kind, 96) or !validDigest(artifact.digest) or artifact.locator.len > 1024) return error.InvalidArtifact;
        if (index > 0 and std.mem.order(u8, input.artifacts[index - 1].digest, artifact.digest) != .lt) return error.NonCanonicalArtifacts;
    }
    if (input.structure) |structure| if (!validText(structure.kind, 96) or !validDigest(structure.fingerprint)) return error.InvalidStructure;
}

fn validText(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn validDigest(value: []const u8) bool {
    if (value.len < 8 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn genericName(_: *anyopaque) []const u8 {
    return "generic-structured";
}

fn genericNormalize(_: *anyopaque, input: model.RecordInput) !model.RecordInput {
    try validateRecord(input);
    return input;
}

pub const Generic = struct {
    pub fn adapter() Adapter {
        return .{ .context = undefined, .nameFn = genericName, .normalizeFn = genericNormalize };
    }
};

const std = @import("std");
const model = @import("model.zig");
const runtime_mod = @import("runtime.zig");
const science = @import("science.zig");
const quantum = @import("quantum.zig");

test "generic adapter rejects noncanonical structured input before mutation" {
    var runtime = runtime_mod.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const scopes = [_]model.Scope{ .{ .key = "model", .value = "v2" }, .{ .key = "code", .value = "v1" } };
    const adapter = science.Generic.adapter();
    try std.testing.expectError(error.NonCanonicalScopes, adapter.record(&runtime, .{ .subject = "agent", .predicate = "selected", .object = "method", .timestamp = 1, .scopes = &scopes }));
    try std.testing.expectEqual(@as(usize, 0), runtime.store.nodes.items.len);
}

test "quantum adapter maps compilation data to generic structured evidence" {
    var runtime = runtime_mod.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var storage: quantum.CompilationStorage = .{};
    const input = quantum.compilationRecord(.{
        .backend = "alpha",
        .calibration = "c1",
        .compiler = "qew-1",
        .circuit_digest = "0123456789abcdef",
        .topology_fingerprint = "fedcba9876543210",
        .depth = 24,
        .two_qubit_gates = 12,
        .fidelity = 0.99,
        .timestamp = 1,
    }, &storage);
    const id = try quantum.adapter().record(&runtime, input);
    try std.testing.expectEqual(@as(usize, 3), runtime.store.scoped_records.items.len);
    try std.testing.expectEqual(@as(usize, 3), runtime.store.metric_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.artifact_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.structure_records.items.len);

    const scopes = [_]model.Scope{.{ .key = "backend", .value = "alpha" }};
    var activation = try runtime.activate(.{ .query = "0123456789abcdef", .scopes = &scopes, .structure = .{ .kind = "topology", .fingerprint = "fedcba9876543210" } }, 1, std.testing.allocator);
    defer activation.deinit(std.testing.allocator);
    try std.testing.expectEqual(id, activation.items[0].id);
    try std.testing.expectEqual(@as(f64, 1), activation.items[0].signals.scope);
    try std.testing.expectEqual(@as(f64, 1), activation.items[0].signals.structure);
}

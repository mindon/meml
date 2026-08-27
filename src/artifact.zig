const std = @import("std");
const model = @import("model.zig");

/// Immutable metadata for a host-managed model or checkpoint. It contains no
/// model bytes and MEML never opens `locator`; hosts must verify and load blobs.
pub const Manifest = struct {
    provider: []const u8,
    model_version: []const u8,
    checksum: []const u8,
    byte_length: u64,
    locator: []const u8 = "",

    pub fn validate(self: Manifest) !void {
        if (!validText(self.provider, 96) or !validText(self.model_version, 128) or self.byte_length == 0 or self.locator.len > 1024) return error.InvalidArtifactManifest;
        if (self.checksum.len != 64) return error.InvalidArtifactManifest;
        for (self.checksum) |byte| if (!std.ascii.isHex(byte)) return error.InvalidArtifactManifest;
        for (self.locator) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidArtifactManifest;
    }

    pub const RecordData = struct {
        scopes: [2]model.Scope,
        metrics: [1]model.Metric,
        artifacts: [1]model.Artifact,
    };

    /// Converts immutable checkpoint metadata into canonical generic record
    /// data. The caller supplies the record's domain-neutral semantic fields;
    /// MEML persists provider/version/size alongside the SHA-256 reference.
    pub fn recordData(self: Manifest) !RecordData {
        try self.validate();
        return .{
            .scopes = .{
                .{ .key = "model.version", .value = self.model_version },
                .{ .key = "provider", .value = self.provider },
            },
            .metrics = .{.{ .name = "artifact.byte_length", .value = @floatFromInt(self.byte_length), .unit = "bytes", .direction = .neutral }},
            .artifacts = .{.{ .kind = "model-checkpoint", .digest = self.checksum, .locator = self.locator }},
        };
    }

    /// Returns the integrity-bearing generic Artifact reference only. Prefer
    /// `recordData()` when writing a semantic record so manifest metadata is
    /// retained across persistence and recovery.
    pub fn artifact(self: Manifest) !model.Artifact {
        return (try self.recordData()).artifacts[0];
    }
};

fn validText(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

test "model artifact manifest validates immutable metadata without loading blobs" {
    const manifest = Manifest{
        .provider = "deterministic-neural",
        .model_version = "v1",
        .checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .byte_length = 4096,
        .locator = "host-managed://checkpoints/neural-v1",
    };
    const data = try manifest.recordData();
    try std.testing.expectEqualStrings("model.version", data.scopes[0].key);
    try std.testing.expectEqualStrings("provider", data.scopes[1].key);
    try std.testing.expectEqualStrings("model-checkpoint", data.artifacts[0].kind);
    try std.testing.expectEqual(@as(f64, 4096), data.metrics[0].value);
    const invalid = Manifest{ .provider = "provider", .model_version = "v1", .checksum = "bad", .byte_length = 1 };
    try std.testing.expectError(error.InvalidArtifactManifest, invalid.validate());
}

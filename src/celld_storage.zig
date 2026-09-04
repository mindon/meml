const std = @import("std");
const persistence = @import("persistence.zig");
const storage = @import("storage.zig");
const store_mod = @import("store.zig");

/// The public Worker endpoint for a MEML-aware celld deployment. This is an
/// application protocol layered over celld's Worker API, never celld's
/// internal operator listener.
pub const Config = struct {
    endpoint: []const u8,
    key: []const u8,
    bearer_token: ?[]const u8 = null,

    pub fn validate(self: Config) !void {
        if (!isSafeKey(self.key)) return error.InvalidCelldKey;
        if (self.endpoint.len == 0 or std.mem.endsWith(u8, self.endpoint, "/")) return error.InvalidCelldEndpoint;
        if (std.mem.indexOf(u8, self.endpoint, "\r") != null or std.mem.indexOf(u8, self.endpoint, "\n") != null) return error.InvalidCelldEndpoint;
        if (std.mem.indexOf(u8, self.endpoint, "?") != null or std.mem.indexOf(u8, self.endpoint, "#") != null) return error.InvalidCelldEndpoint;
        if (!std.mem.startsWith(u8, self.endpoint, "https://") and !std.mem.startsWith(u8, self.endpoint, "http://localhost") and !std.mem.startsWith(u8, self.endpoint, "http://127.0.0.1") and !std.mem.startsWith(u8, self.endpoint, "http://[::1]")) return error.InsecureCelldEndpoint;
        if (self.bearer_token) |token| {
            if (token.len == 0 or std.mem.indexOf(u8, token, "\r") != null or std.mem.indexOf(u8, token, "\n") != null) return error.InvalidCelldToken;
        }
    }
};

pub const OwnedConfig = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn deinit(self: *OwnedConfig) void {
        self.allocator.free(self.config.endpoint);
        self.allocator.free(self.config.key);
        if (self.config.bearer_token) |token| self.allocator.free(token);
        self.* = undefined;
    }
};

/// Reads a fixed endpoint and key from the process environment. Request JSON
/// cannot override either value, preventing it from becoming an SSRF surface.
pub fn fromEnvironment(allocator: std.mem.Allocator, environ: std.process.Environ) !OwnedConfig {
    const endpoint = environ.getAlloc(allocator, "CELLD_MEML_ENDPOINT") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.CelldNotConfigured,
        else => return err,
    };
    errdefer allocator.free(endpoint);
    const key = environ.getAlloc(allocator, "CELLD_MEML_KEY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, "default"),
        else => return err,
    };
    errdefer allocator.free(key);
    const token = environ.getAlloc(allocator, "CELLD_MEML_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    errdefer if (token) |value| allocator.free(value);
    var owned = OwnedConfig{ .allocator = allocator, .config = .{ .endpoint = endpoint, .key = key, .bearer_token = token } };
    try owned.config.validate();
    return owned;
}

pub const Provider = struct {
    config: Config,

    pub fn init(config: Config) !Provider {
        try config.validate();
        return .{ .config = config };
    }

    pub fn provider(provider_value: *Provider) storage.VersionedProvider {
        return .{
            .context = provider_value,
            .loadRevisionFn = loadRevision,
            .persistIfRevisionFn = persistIfRevision,
            .recoverFn = recover,
        };
    }

    fn self(context: *anyopaque) *Provider {
        return @ptrCast(@alignCast(context));
    }

    fn loadRevision(context: *anyopaque, io: std.Io, key: []const u8) !u64 {
        var loaded = try self(context).load(io, key, std.heap.page_allocator);
        defer loaded.store.deinit();
        return loaded.revision;
    }

    fn persistIfRevision(context: *anyopaque, store: *const store_mod.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, key: []const u8) !u64 {
        return self(context).persist(store, next_id, clock, expected_revision, io, allocator, key);
    }

    fn recover(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, key: []const u8) !persistence.Loaded {
        return self(context).load(io, key, allocator);
    }

    fn load(self_value: *const Provider, io: std.Io, key: []const u8, allocator: std.mem.Allocator) !persistence.Loaded {
        try self_value.requireConfiguredKey(key);
        var response = BoundedResponse.init(allocator);
        defer response.deinit();
        const status = try self_value.fetch(io, allocator, .GET, null, &.{}, &response.writer);
        switch (status) {
            .ok => return persistence.deserializeSnapshot(allocator, response.written()),
            .not_found => return error.FileNotFound,
            .unauthorized, .forbidden => return error.Unauthorized,
            .too_many_requests, .service_unavailable => return error.RemoteOverloaded,
            else => return error.RemoteUnavailable,
        }
    }

    fn persist(self_value: *const Provider, store: *const store_mod.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, key: []const u8) !u64 {
        try self_value.requireConfiguredKey(key);
        const next_revision = std.math.add(u64, expected_revision, 1) catch return error.RevisionOverflow;
        const snapshot = try persistence.serializeSnapshot(allocator, store, next_revision, next_id, clock);
        defer allocator.free(snapshot);

        var if_match: [32]u8 = undefined;
        const if_match_value = try std.fmt.bufPrint(&if_match, "\"{d}\"", .{expected_revision});
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(snapshot, &digest, .{});
        var idempotency_key: [80]u8 = undefined;
        const idempotency_value = try std.fmt.bufPrint(&idempotency_key, "meml-{x}", .{digest});
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            .{ .name = "If-Match", .value = if_match_value },
            .{ .name = "Idempotency-Key", .value = idempotency_value },
        };
        const status = try self_value.fetch(io, allocator, .PUT, snapshot, &headers, null);
        return switch (status) {
            .ok, .created, .no_content => next_revision,
            .conflict, .precondition_failed => error.RevisionConflict,
            .unauthorized, .forbidden => error.Unauthorized,
            .too_many_requests, .service_unavailable => error.RemoteOverloaded,
            else => error.RemoteUnavailable,
        };
    }

    fn fetch(self_value: *const Provider, io: std.Io, allocator: std.mem.Allocator, method: std.http.Method, payload: ?[]const u8, request_headers: []const std.http.Header, response_writer: ?*std.Io.Writer) !std.http.Status {
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/meml/{s}", .{ self_value.config.endpoint, self_value.config.key });
        defer allocator.free(url);

        var headers: [4]std.http.Header = undefined;
        var count: usize = 0;
        for (request_headers) |header| {
            headers[count] = header;
            count += 1;
        }
        if (self_value.config.bearer_token) |token| {
            const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            defer allocator.free(authorization);
            headers[count] = .{ .name = "Authorization", .value = authorization };
            count += 1;
            return fetchWithHeaders(io, allocator, url, method, payload, headers[0..count], response_writer);
        }
        return fetchWithHeaders(io, allocator, url, method, payload, headers[0..count], response_writer);
    }

    fn requireConfiguredKey(self_value: *const Provider, key: []const u8) !void {
        if (!std.mem.eql(u8, key, self_value.config.key)) return error.InvalidCelldKey;
    }
};

const max_snapshot_bytes = 64 * 1024 * 1024;

const BoundedResponse = struct {
    output: std.Io.Writer.Allocating,
    writer: std.Io.Writer,

    fn init(allocator: std.mem.Allocator) BoundedResponse {
        var response = BoundedResponse{
            .output = std.Io.Writer.Allocating.init(allocator),
            .writer = undefined,
        };
        response.writer = .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drain,
                .flush = std.Io.Writer.noopFlush,
                .rebase = std.Io.Writer.unreachableRebase,
            },
        };
        return response;
    }

    fn deinit(self_value: *BoundedResponse) void {
        self_value.output.deinit();
        self_value.* = undefined;
    }

    fn written(self_value: *BoundedResponse) []u8 {
        return self_value.output.written();
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self_value: *BoundedResponse = @fieldParentPtr("writer", writer);
        var total: usize = writer.end;
        for (data[0 .. data.len - 1]) |bytes| total = std.math.add(usize, total, bytes.len) catch return error.WriteFailed;
        total = std.math.add(usize, total, std.math.mul(usize, data[data.len - 1].len, splat) catch return error.WriteFailed) catch return error.WriteFailed;
        if (total > max_snapshot_bytes) return error.WriteFailed;
        try self_value.output.writer.writeAll(writer.buffered());
        writer.end = 0;
        for (data[0 .. data.len - 1]) |bytes| try self_value.output.writer.writeAll(bytes);
        for (0..splat) |_| try self_value.output.writer.writeAll(data[data.len - 1]);
        return total - writer.buffer.len;
    }
};

fn fetchWithHeaders(io: std.Io, allocator: std.mem.Allocator, url: []const u8, method: std.http.Method, payload: ?[]const u8, headers: []const std.http.Header, response_writer: ?*std.Io.Writer) !std.http.Status {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers,
        .response_writer = response_writer,
    });
    return result.status;
}

fn isSafeKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    for (key) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

test "celld config accepts HTTPS and local development endpoints" {
    try (Config{ .endpoint = "https://memory.example", .key = "agent_1" }).validate();
    try (Config{ .endpoint = "http://127.0.0.1:9876", .key = "default" }).validate();
    try std.testing.expectError(error.InsecureCelldEndpoint, (Config{ .endpoint = "http://memory.example", .key = "default" }).validate());
    try std.testing.expectError(error.InvalidCelldKey, (Config{ .endpoint = "https://memory.example", .key = "tenant/a" }).validate());
}

test "bounded celld response collects a snapshot body" {
    var response = BoundedResponse.init(std.testing.allocator);
    defer response.deinit();
    try response.writer.writeAll("MEML15 0 1 0\n");
    try std.testing.expectEqualStrings("MEML15 0 1 0\n", response.written());
}

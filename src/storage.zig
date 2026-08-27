const std = @import("std");
const persistence = @import("persistence.zig");
const store_mod = @import("store.zig");

/// Storage boundary for local, multi-process and remote implementations.
/// Providers receive only semantic records; backend indexes remain derived data.
pub const Provider = struct {
    context: *anyopaque,
    nameFn: *const fn (*anyopaque) []const u8,
    persistFn: *const fn (*anyopaque, *const store_mod.Store, u64, u64, i64, std.Io, std.mem.Allocator, []const u8) anyerror!void,
    persistAtomicFn: *const fn (*anyopaque, *const store_mod.Store, u64, u64, i64, std.Io, std.mem.Allocator, []const u8) anyerror!void,
    recoverFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!persistence.Loaded,

    pub fn name(self: Provider) []const u8 {
        return self.nameFn(self.context);
    }

    pub fn persist(self: Provider, store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        return self.persistFn(self.context, store, revision, next_id, clock, io, allocator, path);
    }

    pub fn persistAtomic(self: Provider, store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        return self.persistAtomicFn(self.context, store, revision, next_id, clock, io, allocator, path);
    }

    pub fn recover(self: Provider, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !persistence.Loaded {
        return self.recoverFn(self.context, allocator, io, path);
    }
};

/// A remote or multi-process adapter can use this contract to perform
/// optimistic concurrency control. A failed compare-and-swap must return
/// `error.RevisionConflict` without replacing the stored state.
pub const VersionedProvider = struct {
    context: *anyopaque,
    loadRevisionFn: *const fn (*anyopaque, std.Io, []const u8) anyerror!u64,
    persistIfRevisionFn: *const fn (*anyopaque, *const store_mod.Store, u64, i64, u64, std.Io, std.mem.Allocator, []const u8) anyerror!u64,
    recoverFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!persistence.Loaded,

    pub fn loadRevision(self: VersionedProvider, io: std.Io, path: []const u8) !u64 {
        return self.loadRevisionFn(self.context, io, path);
    }

    pub fn persistIfRevision(self: VersionedProvider, store: *const store_mod.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
        return self.persistIfRevisionFn(self.context, store, next_id, clock, expected_revision, io, allocator, path);
    }

    /// Loads the current semantic snapshot. Derived indexes are intentionally
    /// absent from this protocol and are rebuilt by Runtime recovery.
    pub fn recover(self: VersionedProvider, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !persistence.Loaded {
        return self.recoverFn(self.context, allocator, io, path);
    }
};

fn nameLocal(_: *anyopaque) []const u8 {
    return "local-file";
}

fn persistLocal(_: *anyopaque, store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    return persistence.saveAtomic(store, revision, next_id, clock, io, allocator, path);
}

fn persistAtomicLocal(_: *anyopaque, store: *const store_mod.Store, revision: u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    return persistence.saveAtomic(store, revision, next_id, clock, io, allocator, path);
}

fn recoverLocal(_: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !persistence.Loaded {
    try persistence.recoverJournal(io, allocator, path);
    return persistence.load(allocator, io, path);
}

pub const Local = struct {
    pub fn provider() Provider {
        return .{ .context = undefined, .nameFn = nameLocal, .persistFn = persistLocal, .persistAtomicFn = persistAtomicLocal, .recoverFn = recoverLocal };
    }
};

fn loadLocalRevision(_: *anyopaque, io: std.Io, path: []const u8) !u64 {
    var loaded = persistence.load(std.heap.page_allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer loaded.store.deinit();
    return loaded.revision;
}

fn persistLocalIfRevision(_: *anyopaque, store: *const store_mod.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
    return persistence.saveAtomicIfRevision(store, expected_revision, next_id, clock, io, allocator, path);
}

fn recoverLocalVersioned(_: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !persistence.Loaded {
    try persistence.recoverJournal(io, allocator, path);
    return persistence.load(allocator, io, path);
}

/// Revision-aware local adapter. Its CAS behavior is identical to the contract
/// expected from remote providers, making concurrent writer behavior testable.
pub const VersionedLocal = struct {
    pub fn provider() VersionedProvider {
        return .{ .context = undefined, .loadRevisionFn = loadLocalRevision, .persistIfRevisionFn = persistLocalIfRevision, .recoverFn = recoverLocalVersioned };
    }
};

/// Host-owned remote transport. MEML intentionally does not open arbitrary
/// URLs: authentication, allowlists, TLS, and request routing belong to the
/// embedding service. The transport must implement atomic compare-and-swap.
pub const Remote = struct {
    pub const Transport = struct {
        context: *anyopaque,
        loadRevisionFn: *const fn (*anyopaque, std.Io, []const u8) anyerror!u64,
        persistIfRevisionFn: *const fn (*anyopaque, *const store_mod.Store, u64, i64, u64, std.Io, std.mem.Allocator, []const u8) anyerror!u64,
        recoverFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!persistence.Loaded,
    };

    fn loadRevision(context: *anyopaque, io: std.Io, path: []const u8) !u64 {
        const transport: *const Transport = @ptrCast(@alignCast(context));
        return transport.loadRevisionFn(transport.context, io, path);
    }

    fn persistIfRevision(context: *anyopaque, store: *const store_mod.Store, next_id: u64, clock: i64, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
        const transport: *const Transport = @ptrCast(@alignCast(context));
        return transport.persistIfRevisionFn(transport.context, store, next_id, clock, expected_revision, io, allocator, path);
    }

    fn recover(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !persistence.Loaded {
        const transport: *const Transport = @ptrCast(@alignCast(context));
        return transport.recoverFn(transport.context, allocator, io, path);
    }

    /// The caller keeps `transport` alive for as long as the provider is used.
    pub fn provider(transport: *const Transport) VersionedProvider {
        return .{ .context = @constCast(transport), .loadRevisionFn = loadRevision, .persistIfRevisionFn = persistIfRevision, .recoverFn = recover };
    }
};

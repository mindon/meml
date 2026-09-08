const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const backend_mod = @import("backend.zig");
const persistence = @import("persistence.zig");
const index_journal = @import("index_journal.zig");
const storage_mod = @import("storage.zig");

pub fn persistAtomic(store: *const store_mod.Store, revision: *u64, index_checkpoint_revision: *u64, next_id: u64, clock: i64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const next_revision = std.math.add(u64, revision.*, 1) catch return error.RevisionOverflow;
    try persistence.saveAtomic(store, next_revision, next_id, clock, io, allocator, path);
    revision.* = next_revision;
    try index_journal.save(store, next_revision, io, allocator, path);
    index_checkpoint_revision.* = next_revision;
}

pub fn persistTo(store: *const store_mod.Store, revision: *u64, next_id: u64, clock: i64, provider: storage_mod.Provider, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const next_revision = std.math.add(u64, revision.*, 1) catch return error.RevisionOverflow;
    try provider.persist(store, next_revision, next_id, clock, io, allocator, path);
    revision.* = next_revision;
}

pub fn persistIfRevision(store: *const store_mod.Store, revision: *u64, next_id: u64, clock: i64, provider: storage_mod.VersionedProvider, expected_revision: u64, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    revision.* = try provider.persistIfRevision(store, next_id, clock, expected_revision, io, allocator, path);
}

pub const Recovered = struct {
    store: store_mod.Store,
    next_id: u64,
    next_transition_id: u64,
    clock: i64,
    revision: u64,
    index_checkpoint_revision: u64,
};

pub fn recoverLocal(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Recovered {
    try persistence.recoverJournal(io, allocator, path);
    var loaded = try persistence.load(allocator, io, path);
    errdefer loaded.store.deinit();
    const checkpoint_revision = if (try index_journal.recover(&loaded.store, loaded.revision, io, allocator, path)) loaded.revision else 0;
    return fromLoaded(loaded, checkpoint_revision);
}

pub fn recoverFrom(allocator: std.mem.Allocator, provider: storage_mod.VersionedProvider, io: std.Io, path: []const u8) !Recovered {
    return fromLoaded(try provider.recover(allocator, io, path), 0);
}

fn fromLoaded(loaded: persistence.Loaded, index_checkpoint_revision: u64) !Recovered {
    var owned = loaded;
    errdefer owned.store.deinit();
    try owned.store.validate();
    var next_transition_id: u64 = 1;
    for (owned.store.transition_records.items) |record| next_transition_id = @max(next_transition_id, record.id + 1);
    return .{
        .store = owned.store,
        .next_id = owned.next_id,
        .next_transition_id = next_transition_id,
        .clock = owned.clock,
        .revision = owned.revision,
        .index_checkpoint_revision = index_checkpoint_revision,
    };
}

pub fn restoreBackend(backend: backend_mod.Backend, store: *const store_mod.Store) !void {
    try backend.reset(store);
}

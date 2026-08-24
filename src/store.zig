const std = @import("std");
const model = @import("model.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(model.Node),
    relations: std.ArrayList(model.Relation),
    consolidations: std.ArrayList(model.ConsolidationRecord),
    fingerprint_groups: std.ArrayList(model.FingerprintGroup),
    fingerprint_members: std.ArrayList(model.FingerprintMember),
    neural_states: std.ArrayList(model.NeuralState),
    learned_signals: std.ArrayList(model.LearnedSignalState),
    feedback_records: std.ArrayList(model.FeedbackRecord),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .nodes = .empty, .relations = .empty, .consolidations = .empty, .fingerprint_groups = .empty, .fingerprint_members = .empty, .neural_states = .empty, .learned_signals = .empty, .feedback_records = .empty };
    }

    pub fn deinitNode(allocator: std.mem.Allocator, entry: model.Node) void {
        allocator.free(entry.subject);
        allocator.free(entry.predicate);
        allocator.free(entry.object);
        allocator.free(entry.context);
        allocator.free(entry.result);
    }

    pub fn deinit(self: *Store) void {
        for (self.nodes.items) |entry| deinitNode(self.allocator, entry);
        self.nodes.deinit(self.allocator);
        self.relations.deinit(self.allocator);
        for (self.consolidations.items) |record| self.allocator.free(record.rule);
        self.consolidations.deinit(self.allocator);
        self.fingerprint_groups.deinit(self.allocator);
        self.fingerprint_members.deinit(self.allocator);
        self.neural_states.deinit(self.allocator);
        for (self.learned_signals.items) |state| self.allocator.free(state.provider);
        self.learned_signals.deinit(self.allocator);
        for (self.feedback_records.items) |record| {
            self.allocator.free(record.actor);
            self.allocator.free(record.receipt);
        }
        self.feedback_records.deinit(self.allocator);
    }

    fn cloneNode(allocator: std.mem.Allocator, entry: model.Node) !model.Node {
        const subject = try allocator.dupe(u8, entry.subject);
        errdefer allocator.free(subject);
        const predicate = try allocator.dupe(u8, entry.predicate);
        errdefer allocator.free(predicate);
        const object = try allocator.dupe(u8, entry.object);
        errdefer allocator.free(object);
        const context = try allocator.dupe(u8, entry.context);
        errdefer allocator.free(context);
        const result = try allocator.dupe(u8, entry.result);
        errdefer allocator.free(result);
        return .{
            .id = entry.id,
            .kind = entry.kind,
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .context = context,
            .result = result,
            .timestamp = entry.timestamp,
            .confidence = entry.confidence,
            .strength = entry.strength,
            .belief_state = entry.belief_state,
            .support_count = entry.support_count,
            .contradiction_count = entry.contradiction_count,
            .last_confirmed_at = entry.last_confirmed_at,
            .last_contradicted_at = entry.last_contradicted_at,
        };
    }

    pub fn clone(self: *const Store, allocator: std.mem.Allocator) !Store {
        var out = Store.init(allocator);
        errdefer out.deinit();
        for (self.nodes.items) |entry| {
            const copied = try cloneNode(allocator, entry);
            _ = out.add(copied) catch |err| {
                deinitNode(allocator, copied);
                return err;
            };
        }
        try out.relations.appendSlice(allocator, self.relations.items);
        for (self.consolidations.items) |record| {
            const rule = try allocator.dupe(u8, record.rule);
            out.recordConsolidation(.{ .artifact = record.artifact, .rule = rule, .version = record.version, .source_a = record.source_a, .source_b = record.source_b }) catch |err| {
                allocator.free(rule);
                return err;
            };
        }
        try out.fingerprint_groups.appendSlice(allocator, self.fingerprint_groups.items);
        try out.fingerprint_members.appendSlice(allocator, self.fingerprint_members.items);
        try out.neural_states.appendSlice(allocator, self.neural_states.items);
        for (self.learned_signals.items) |state| try out.upsertLearnedSignal(state.provider, state.weight, state.bias, state.version);
        for (self.feedback_records.items) |record| try out.recordFeedback(.{ .evidence = record.evidence, .target = record.target, .outcome = record.outcome, .failure_class = record.failure_class, .actor = record.actor, .receipt = record.receipt });
        return out;
    }

    pub fn add(self: *Store, entry: model.Node) !u64 {
        try self.nodes.append(self.allocator, entry);
        return entry.id;
    }

    pub fn node(self: *Store, id: u64) ?*model.Node {
        for (self.nodes.items) |*entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn constNode(self: *const Store, id: u64) ?*const model.Node {
        for (self.nodes.items) |*entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn link(self: *Store, relation: model.Relation) !void {
        try self.relations.append(self.allocator, relation);
    }

    pub fn unlink(self: *Store, from: u64, kind: model.RelationKind, to: u64) bool {
        for (self.relations.items, 0..) |relation, index| {
            if (relation.from == from and relation.kind == kind and relation.to == to) {
                _ = self.relations.swapRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn recordConsolidation(self: *Store, record: model.ConsolidationRecord) !void {
        try self.consolidations.append(self.allocator, record);
    }

    pub fn recordFingerprint(self: *Store, fingerprint: u64, experience: u64) !void {
        for (self.fingerprint_groups.items) |*group| {
            if (group.fingerprint == fingerprint) {
                try self.fingerprint_members.append(self.allocator, .{ .fingerprint = fingerprint, .experience = experience });
                group.count += 1;
                return;
            }
        }
        try self.fingerprint_members.append(self.allocator, .{ .fingerprint = fingerprint, .experience = experience });
        self.fingerprint_groups.append(self.allocator, .{ .fingerprint = fingerprint, .count = 1 }) catch |err| {
            _ = self.fingerprint_members.pop();
            return err;
        };
    }

    pub fn recordFeedback(self: *Store, input: model.FeedbackRecord) !void {
        const actor = try self.allocator.dupe(u8, input.actor);
        errdefer self.allocator.free(actor);
        const receipt = try self.allocator.dupe(u8, input.receipt);
        errdefer self.allocator.free(receipt);
        try self.feedback_records.append(self.allocator, .{ .evidence = input.evidence, .target = input.target, .outcome = input.outcome, .failure_class = input.failure_class, .actor = actor, .receipt = receipt });
    }

    pub fn upsertNeuralState(self: *Store, state: model.NeuralState) !void {
        for (self.neural_states.items) |*existing| {
            if (existing.artifact == state.artifact) {
                existing.* = state;
                return;
            }
        }
        try self.neural_states.append(self.allocator, state);
    }

    pub fn learnedSignal(self: *const Store, provider: []const u8) ?model.LearnedSignalState {
        for (self.learned_signals.items) |state| if (std.mem.eql(u8, state.provider, provider)) return state;
        return null;
    }

    pub fn upsertLearnedSignal(self: *Store, provider: []const u8, weight: f64, bias: f64, version: u32) !void {
        for (self.learned_signals.items) |*existing| {
            if (std.mem.eql(u8, existing.provider, provider)) {
                existing.weight = weight;
                existing.bias = bias;
                existing.version = version;
                return;
            }
        }
        try self.learned_signals.append(self.allocator, .{ .provider = try self.allocator.dupe(u8, provider), .weight = weight, .bias = bias, .version = version });
    }

    /// Rejects malformed persisted state before it can reach runtime indexing or
    /// consolidation. The persisted graph is untrusted input at this boundary.
    pub fn validate(self: *const Store) !void {
        var node_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer node_ids.deinit();
        for (self.nodes.items) |entry_node| {
            if (entry_node.id == 0 or !std.math.isFinite(entry_node.confidence) or !std.math.isFinite(entry_node.strength) or entry_node.confidence < 0 or entry_node.confidence > 1 or entry_node.strength < 0 or entry_node.strength > 1) return error.BadFile;
            const entry = try node_ids.getOrPut(entry_node.id);
            if (entry.found_existing) return error.BadFile;
        }
        for (self.relations.items) |relation| {
            if (!node_ids.contains(relation.from) or !node_ids.contains(relation.to) or !std.math.isFinite(relation.weight)) return error.BadFile;
        }
        for (self.consolidations.items) |record| {
            if (!node_ids.contains(record.artifact) or !node_ids.contains(record.source_a) or (record.source_b != 0 and !node_ids.contains(record.source_b))) return error.BadFile;
        }
        var group_counts = std.AutoHashMap(u64, usize).init(self.allocator);
        defer group_counts.deinit();
        for (self.fingerprint_groups.items) |group| {
            const entry = try group_counts.getOrPut(group.fingerprint);
            if (entry.found_existing) return error.BadFile;
            entry.value_ptr.* = 0;
        }
        for (self.fingerprint_members.items) |member| {
            const member_node = self.constNode(member.experience) orelse return error.BadFile;
            if (member_node.kind != .experience) return error.BadFile;
            const count = group_counts.getPtr(member.fingerprint) orelse return error.BadFile;
            count.* += 1;
        }
        for (self.fingerprint_groups.items) |group| if (group_counts.get(group.fingerprint).? != group.count) return error.BadFile;
        for (self.neural_states.items) |state| {
            const artifact = self.constNode(state.artifact) orelse return error.BadFile;
            if (artifact.kind != .belief or !std.math.isFinite(state.strength)) return error.BadFile;
        }
        for (self.learned_signals.items, 0..) |state, index| {
            if (state.provider.len == 0 or !std.math.isFinite(state.weight) or !std.math.isFinite(state.bias) or state.weight < 0 or state.weight > 4 or state.bias < -1 or state.bias > 1) return error.BadFile;
            for (self.learned_signals.items[index + 1 ..]) |other| if (std.mem.eql(u8, state.provider, other.provider)) return error.BadFile;
        }
        for (self.feedback_records.items) |record| {
            const evidence = self.constNode(record.evidence) orelse return error.BadFile;
            if (evidence.kind != .evidence or self.constNode(record.target) == null or record.actor.len == 0 or record.receipt.len == 0) return error.BadFile;
            if ((record.outcome == .success and record.failure_class != .none) or (record.outcome == .failure and record.failure_class == .none)) return error.BadFile;
        }
    }
};

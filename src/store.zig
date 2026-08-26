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
    scoped_records: std.ArrayList(model.ScopedRecord),
    metric_records: std.ArrayList(model.MetricRecord),
    artifact_records: std.ArrayList(model.ArtifactRecord),
    structure_records: std.ArrayList(model.StructureRecord),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .nodes = .empty, .relations = .empty, .consolidations = .empty, .fingerprint_groups = .empty, .fingerprint_members = .empty, .neural_states = .empty, .learned_signals = .empty, .feedback_records = .empty, .scoped_records = .empty, .metric_records = .empty, .artifact_records = .empty, .structure_records = .empty };
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
        for (self.scoped_records.items) |record| {
            self.allocator.free(record.scope.key);
            self.allocator.free(record.scope.value);
        }
        self.scoped_records.deinit(self.allocator);
        for (self.metric_records.items) |record| {
            self.allocator.free(record.metric.name);
            self.allocator.free(record.metric.unit);
        }
        self.metric_records.deinit(self.allocator);
        for (self.artifact_records.items) |record| {
            self.allocator.free(record.artifact.kind);
            self.allocator.free(record.artifact.digest);
            self.allocator.free(record.artifact.locator);
        }
        self.artifact_records.deinit(self.allocator);
        for (self.structure_records.items) |record| {
            self.allocator.free(record.structure.kind);
            self.allocator.free(record.structure.fingerprint);
        }
        self.structure_records.deinit(self.allocator);
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
        for (self.scoped_records.items) |record| try out.addScope(record.node, record.scope);
        for (self.metric_records.items) |record| try out.addMetric(record.node, record.metric);
        for (self.artifact_records.items) |record| try out.addArtifact(record.node, record.artifact);
        for (self.structure_records.items) |record| try out.setStructure(record.node, record.structure);
        return out;
    }

    pub fn add(self: *Store, entry: model.Node) !u64 {
        try self.nodes.append(self.allocator, entry);
        return entry.id;
    }

    fn removeScopedAt(self: *Store, index: usize) void {
        const removed = self.scoped_records.swapRemove(index);
        self.allocator.free(removed.scope.key);
        self.allocator.free(removed.scope.value);
    }

    fn removeMetricAt(self: *Store, index: usize) void {
        const removed = self.metric_records.swapRemove(index);
        self.allocator.free(removed.metric.name);
        self.allocator.free(removed.metric.unit);
    }

    fn removeArtifactAt(self: *Store, index: usize) void {
        const removed = self.artifact_records.swapRemove(index);
        self.allocator.free(removed.artifact.kind);
        self.allocator.free(removed.artifact.digest);
        self.allocator.free(removed.artifact.locator);
    }

    fn removeStructureAt(self: *Store, index: usize) void {
        const removed = self.structure_records.swapRemove(index);
        self.allocator.free(removed.structure.kind);
        self.allocator.free(removed.structure.fingerprint);
    }

    pub fn removeRecordData(self: *Store, record_id: u64) void {
        var i = self.scoped_records.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scoped_records.items[i].node == record_id) self.removeScopedAt(i);
        }
        i = self.metric_records.items.len;
        while (i > 0) {
            i -= 1;
            if (self.metric_records.items[i].node == record_id) self.removeMetricAt(i);
        }
        i = self.artifact_records.items.len;
        while (i > 0) {
            i -= 1;
            if (self.artifact_records.items[i].node == record_id) self.removeArtifactAt(i);
        }
        i = self.structure_records.items.len;
        while (i > 0) {
            i -= 1;
            if (self.structure_records.items[i].node == record_id) self.removeStructureAt(i);
        }
    }

    pub fn addScope(self: *Store, record_id: u64, scope: model.Scope) !void {
        const key = try self.allocator.dupe(u8, scope.key);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, scope.value);
        errdefer self.allocator.free(value);
        try self.scoped_records.append(self.allocator, .{ .node = record_id, .scope = .{ .key = key, .value = value } });
    }

    pub fn addMetric(self: *Store, record_id: u64, metric: model.Metric) !void {
        const name = try self.allocator.dupe(u8, metric.name);
        errdefer self.allocator.free(name);
        const unit = try self.allocator.dupe(u8, metric.unit);
        errdefer self.allocator.free(unit);
        try self.metric_records.append(self.allocator, .{ .node = record_id, .metric = .{ .name = name, .value = metric.value, .unit = unit, .uncertainty = metric.uncertainty, .direction = metric.direction } });
    }

    pub fn addArtifact(self: *Store, record_id: u64, artifact: model.Artifact) !void {
        const kind = try self.allocator.dupe(u8, artifact.kind);
        errdefer self.allocator.free(kind);
        const digest = try self.allocator.dupe(u8, artifact.digest);
        errdefer self.allocator.free(digest);
        const locator = try self.allocator.dupe(u8, artifact.locator);
        errdefer self.allocator.free(locator);
        try self.artifact_records.append(self.allocator, .{ .node = record_id, .artifact = .{ .kind = kind, .digest = digest, .locator = locator } });
    }

    pub fn setStructure(self: *Store, record_id: u64, structure: model.Structure) !void {
        for (self.structure_records.items) |record| if (record.node == record_id) return error.DuplicateStructure;
        const kind = try self.allocator.dupe(u8, structure.kind);
        errdefer self.allocator.free(kind);
        const fingerprint = try self.allocator.dupe(u8, structure.fingerprint);
        errdefer self.allocator.free(fingerprint);
        try self.structure_records.append(self.allocator, .{ .node = record_id, .structure = .{ .kind = kind, .fingerprint = fingerprint } });
    }

    pub fn addRecordData(self: *Store, record_id: u64, input: model.RecordInput) !void {
        try validateRecordInput(input);
        const scoped_start = self.scoped_records.items.len;
        const metric_start = self.metric_records.items.len;
        const artifact_start = self.artifact_records.items.len;
        const structure_start = self.structure_records.items.len;
        errdefer {
            while (self.scoped_records.items.len > scoped_start) self.removeScopedAt(self.scoped_records.items.len - 1);
            while (self.metric_records.items.len > metric_start) self.removeMetricAt(self.metric_records.items.len - 1);
            while (self.artifact_records.items.len > artifact_start) self.removeArtifactAt(self.artifact_records.items.len - 1);
            while (self.structure_records.items.len > structure_start) self.removeStructureAt(self.structure_records.items.len - 1);
        }
        for (input.scopes) |scope| try self.addScope(record_id, scope);
        for (input.metrics) |metric| try self.addMetric(record_id, metric);
        for (input.artifacts) |artifact| try self.addArtifact(record_id, artifact);
        if (input.structure) |structure| try self.setStructure(record_id, structure);
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
        const provider_copy = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(provider_copy);
        try self.learned_signals.append(self.allocator, .{ .provider = provider_copy, .weight = weight, .bias = bias, .version = version });
    }

    /// Rejects malformed persisted state before it can reach runtime indexing or
    /// consolidation. The persisted graph is untrusted input at this boundary.
    pub fn validate(self: *const Store) !void {
        var node_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer node_ids.deinit();
        for (self.nodes.items) |entry_node| {
            if (entry_node.id == 0 or !validScaled(entry_node.confidence) or !validScaled(entry_node.strength) or entry_node.confidence < 0 or entry_node.confidence > 1 or entry_node.strength < 0 or entry_node.strength > 1) return error.BadFile;
            const entry = try node_ids.getOrPut(entry_node.id);
            if (entry.found_existing) return error.BadFile;
        }
        var previous_scope_node: u64 = 0;
        var previous_scope_key: []const u8 = "";
        var scope_count: usize = 0;
        for (self.scoped_records.items) |record| {
            if (!node_ids.contains(record.node) or !validText(record.scope.key, 96) or !validText(record.scope.value, 512) or record.node < previous_scope_node or (record.node == previous_scope_node and std.mem.order(u8, previous_scope_key, record.scope.key) != .lt)) return error.BadFile;
            scope_count = if (record.node == previous_scope_node) scope_count + 1 else 1;
            if (scope_count > 16) return error.BadFile;
            previous_scope_node = record.node;
            previous_scope_key = record.scope.key;
        }
        var previous_metric_node: u64 = 0;
        var previous_metric_name: []const u8 = "";
        var previous_metric_unit: []const u8 = "";
        var metric_count: usize = 0;
        for (self.metric_records.items) |record| {
            if (!node_ids.contains(record.node) or !validText(record.metric.name, 96) or record.metric.unit.len > 64 or !validScaled(record.metric.value) or (record.metric.uncertainty != null and (!validScaled(record.metric.uncertainty.?) or record.metric.uncertainty.? < 0)) or record.node < previous_metric_node) return error.BadFile;
            if (record.node == previous_metric_node) {
                const name_order = std.mem.order(u8, previous_metric_name, record.metric.name);
                if (name_order == .gt or (name_order == .eq and std.mem.order(u8, previous_metric_unit, record.metric.unit) != .lt)) return error.BadFile;
            }
            metric_count = if (record.node == previous_metric_node) metric_count + 1 else 1;
            if (metric_count > 32) return error.BadFile;
            previous_metric_node = record.node;
            previous_metric_name = record.metric.name;
            previous_metric_unit = record.metric.unit;
        }
        var previous_artifact_node: u64 = 0;
        var previous_artifact_digest: []const u8 = "";
        var artifact_count: usize = 0;
        for (self.artifact_records.items) |record| {
            if (!node_ids.contains(record.node) or !validText(record.artifact.kind, 96) or !validDigest(record.artifact.digest) or record.artifact.locator.len > 1024 or record.node < previous_artifact_node or (record.node == previous_artifact_node and std.mem.order(u8, previous_artifact_digest, record.artifact.digest) != .lt)) return error.BadFile;
            artifact_count = if (record.node == previous_artifact_node) artifact_count + 1 else 1;
            if (artifact_count > 16) return error.BadFile;
            previous_artifact_node = record.node;
            previous_artifact_digest = record.artifact.digest;
        }
        var previous_structure_node: u64 = 0;
        for (self.structure_records.items) |record| {
            if (!node_ids.contains(record.node) or !validText(record.structure.kind, 96) or !validDigest(record.structure.fingerprint) or record.node <= previous_structure_node) return error.BadFile;
            previous_structure_node = record.node;
        }
        for (self.relations.items) |relation| {
            if (!node_ids.contains(relation.from) or !node_ids.contains(relation.to) or !validScaled(relation.weight)) return error.BadFile;
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
            if (artifact.kind != .belief or !validScaled(state.strength)) return error.BadFile;
        }
        for (self.learned_signals.items, 0..) |state, index| {
            if (state.provider.len == 0 or !validScaled(state.weight) or !validScaled(state.bias) or state.weight < 0 or state.weight > 4 or state.bias < -1 or state.bias > 1) return error.BadFile;
            for (self.learned_signals.items[index + 1 ..]) |other| if (std.mem.eql(u8, state.provider, other.provider)) return error.BadFile;
        }
        for (self.feedback_records.items) |record| {
            const evidence = self.constNode(record.evidence) orelse return error.BadFile;
            if (evidence.kind != .evidence or self.constNode(record.target) == null or record.actor.len == 0 or record.receipt.len == 0) return error.BadFile;
            if ((record.outcome == .success and record.failure_class != .none) or (record.outcome == .failure and record.failure_class == .none)) return error.BadFile;
        }
    }
};

fn validateRecordInput(input: model.RecordInput) !void {
    if (input.scopes.len > 16 or input.metrics.len > 32 or input.artifacts.len > 16) return error.MetadataLimitExceeded;
    for (input.scopes, 0..) |scope, index| {
        if (!validText(scope.key, 96) or !validText(scope.value, 512)) return error.InvalidScope;
        if (index > 0 and std.mem.order(u8, input.scopes[index - 1].key, scope.key) != .lt) return error.NonCanonicalScopes;
    }
    for (input.metrics, 0..) |metric, index| {
        if (!validText(metric.name, 96) or metric.unit.len > 64 or !validScaled(metric.value) or (metric.uncertainty != null and (!validScaled(metric.uncertainty.?) or metric.uncertainty.? < 0))) return error.InvalidMetric;
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

fn validScaled(value: f64) bool {
    if (!std.math.isFinite(value)) return false;
    const scaled = value * 1_000_000;
    return scaled >= @as(f64, @floatFromInt(std.math.minInt(i64))) and scaled <= @as(f64, @floatFromInt(std.math.maxInt(i64)));
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

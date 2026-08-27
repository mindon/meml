const std = @import("std");
const meml = @import("meml.zig");

const Json = std.json;
const Value = Json.Value;
const ObjectMap = Json.ObjectMap;
const seed_path = "eval/datasets/retrieval-v1/seed.jsonl";
const annotations_path = "eval/datasets/retrieval-v1/annotations.jsonl";
const manifest_path = "eval/datasets/retrieval-v1/manifest.json";
const baseline_path = "eval/baselines/retrieval-v1.json";

const Baseline = struct {
    dataset_id: []const u8,
    limit: usize,
    min_tasks: usize,
    min_recall_at_k: f64,
    min_mrr: f64,
    min_ndcg: f64,
};

fn object(value: Value) !ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.InvalidEvaluationData,
    };
}

fn requiredString(map: ObjectMap, key: []const u8) ![]const u8 {
    const value = map.get(key) orelse return error.InvalidEvaluationData;
    return switch (value) {
        .string => |text| if (text.len > 0) text else error.InvalidEvaluationData,
        else => error.InvalidEvaluationData,
    };
}

fn number(value: Value) !f64 {
    return switch (value) {
        .integer => |integer_value| @floatFromInt(integer_value),
        .float => |float_value| float_value,
        else => error.InvalidEvaluationData,
    };
}

fn requiredNumber(map: ObjectMap, key: []const u8) !f64 {
    return number(map.get(key) orelse return error.InvalidEvaluationData);
}

fn optionalString(map: ObjectMap, key: []const u8) ![]const u8 {
    const value = map.get(key) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => error.InvalidEvaluationData,
    };
}

fn requiredPositiveInteger(map: ObjectMap, key: []const u8) !usize {
    const value = map.get(key) orelse return error.InvalidEvaluationData;
    const integer_value = switch (value) {
        .integer => |number_value| number_value,
        else => return error.InvalidEvaluationData,
    };
    if (integer_value <= 0) return error.InvalidEvaluationData;
    return @intCast(integer_value);
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Json.Parsed(Value) {
    if (std.mem.trim(u8, line, " \t\r").len == 0) return error.InvalidEvaluationData;
    return Json.parseFromSlice(Value, allocator, line, .{});
}

fn loadSeed(io: std.Io, runtime: *meml.Runtime, allocator: std.mem.Allocator, keys: *std.StringHashMap(u64)) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, seed_path, allocator, .limited(1 << 20));
    defer allocator.free(source);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = try parseLine(allocator, line);
        defer parsed.deinit();
        const record = try object(parsed.value);
        const record_key = try requiredString(record, "record_key");
        const subject = try requiredString(record, "subject");
        const predicate = try requiredString(record, "predicate");
        const object_text = try requiredString(record, "object");
        const context = try requiredString(record, "context");
        const confidence = try requiredNumber(record, "confidence");
        if (keys.contains(record_key)) return error.InvalidEvaluationData;
        const id = try runtime.assert(subject, predicate, object_text, context, confidence);
        try keys.put(try allocator.dupe(u8, record_key), id);
    }
    if (keys.count() == 0) return error.InvalidEvaluationData;
}

fn validateDigest(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    if (expected.len != 64) return error.InvalidEvaluationData;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(source);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, expected, &actual)) return error.DatasetDigestMismatch;
}

fn validateManifest(io: std.Io, allocator: std.mem.Allocator, baseline: Baseline) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024));
    defer allocator.free(source);
    var parsed = try Json.parseFromSlice(Value, allocator, source, .{});
    defer parsed.deinit();
    const manifest = try object(parsed.value);
    if (try requiredPositiveInteger(manifest, "schema_version") != 1 or !std.mem.eql(u8, try requiredString(manifest, "dataset_id"), baseline.dataset_id) or try requiredPositiveInteger(manifest, "limit") != baseline.limit) return error.InvalidEvaluationData;
    if (!std.mem.eql(u8, try requiredString(manifest, "seed"), "seed.jsonl") or !std.mem.eql(u8, try requiredString(manifest, "annotations"), "annotations.jsonl")) return error.InvalidEvaluationData;
    try validateDigest(io, allocator, seed_path, try requiredString(manifest, "seed_sha256"));
    try validateDigest(io, allocator, annotations_path, try requiredString(manifest, "annotations_sha256"));
}

fn loadBaseline(io: std.Io, allocator: std.mem.Allocator) !Baseline {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, baseline_path, allocator, .limited(64 * 1024));
    defer allocator.free(source);
    var parsed = try Json.parseFromSlice(Value, allocator, source, .{});
    defer parsed.deinit();
    const value = try object(parsed.value);
    if (try requiredPositiveInteger(value, "schema_version") != 1) return error.InvalidEvaluationData;
    return .{
        .dataset_id = try allocator.dupe(u8, try requiredString(value, "dataset_id")),
        .limit = try requiredPositiveInteger(value, "limit"),
        .min_tasks = try requiredPositiveInteger(value, "min_tasks"),
        .min_recall_at_k = try requiredNumber(value, "min_recall_at_k"),
        .min_mrr = try requiredNumber(value, "min_mrr"),
        .min_ndcg = try requiredNumber(value, "min_ndcg"),
    };
}

fn evaluateAnnotations(io: std.Io, runtime: *meml.Runtime, allocator: std.mem.Allocator, keys: *const std.StringHashMap(u64), limit: usize) !meml.VersionedAnnotationReport {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, annotations_path, allocator, .limited(1 << 20));
    defer allocator.free(source);
    var report: meml.VersionedAnnotationReport = .{};
    var task_ids = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = task_ids.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        task_ids.deinit();
    }
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = try parseLine(allocator, line);
        defer parsed.deinit();
        const annotation = try object(parsed.value);
        if (try requiredPositiveInteger(annotation, "schema_version") != 1) return error.InvalidEvaluationData;
        const task_id = try requiredString(annotation, "task_id");
        if (task_ids.contains(task_id)) return error.InvalidEvaluationData;
        try task_ids.put(try allocator.dupe(u8, task_id), {});
        const context_value = annotation.get("context") orelse return error.InvalidEvaluationData;
        const context_object = try object(context_value);
        const labels_value = annotation.get("labels") orelse return error.InvalidEvaluationData;
        const label_values = switch (labels_value) {
            .array => |items| items,
            else => return error.InvalidEvaluationData,
        };
        var labels = std.ArrayList(meml.RelevanceLabel).empty;
        defer labels.deinit(allocator);
        for (label_values.items) |label_value| {
            const label = try object(label_value);
            const record_key = try requiredString(label, "record_key");
            const relevance = try requiredPositiveInteger(label, "relevance");
            if (relevance > 3) return error.InvalidEvaluationData;
            const id = keys.get(record_key) orelse return error.UnknownRecordKey;
            try labels.append(allocator, .{ .expected = id, .relevance = @intCast(relevance) });
        }
        const task = [_]meml.AnnotatedTask{.{
            .task_id = task_id,
            .context = .{
                .query = try requiredString(context_object, "query"),
                .goal = try optionalString(context_object, "goal"),
                .situation = try requiredString(context_object, "situation"),
                .now = if (context_object.get("now")) |value| @intFromFloat(try number(value)) else 0,
            },
            .labels = labels.items,
        }};
        const partial = try meml.evaluation.evaluateAnnotatedTasks(runtime, &task, limit, allocator);
        report.tasks += partial.tasks;
        report.relevant += partial.relevant;
        report.retrieved_relevant += partial.retrieved_relevant;
        report.reciprocal_rank += partial.reciprocal_rank;
        report.ndcg += partial.ndcg;
    }
    return report;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const baseline = try loadBaseline(io, allocator);
    defer allocator.free(baseline.dataset_id);
    if (!std.mem.eql(u8, baseline.dataset_id, "retrieval-v1") or baseline.min_recall_at_k < 0 or baseline.min_recall_at_k > 1 or baseline.min_mrr < 0 or baseline.min_mrr > 1 or baseline.min_ndcg < 0 or baseline.min_ndcg > 1) return error.InvalidEvaluationData;
    try validateManifest(io, allocator, baseline);
    var runtime = meml.Runtime.init(allocator);
    defer runtime.deinit();
    var keys = std.StringHashMap(u64).init(allocator);
    defer {
        var iterator = keys.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        keys.deinit();
    }
    try loadSeed(io, &runtime, allocator, &keys);
    const report = try evaluateAnnotations(io, &runtime, allocator, &keys, baseline.limit);
    const passed = report.tasks >= baseline.min_tasks and report.recall() >= baseline.min_recall_at_k and report.mrr() >= baseline.min_mrr and report.meanNdcg() >= baseline.min_ndcg;
    std.debug.print("{{\"schema_version\":1,\"dataset_id\":\"{s}\",\"limit\":{d},\"tasks\":{d},\"recall_at_k\":{d:.6},\"mrr\":{d:.6},\"ndcg\":{d:.6},\"passed\":{s}}}\n", .{ baseline.dataset_id, baseline.limit, report.tasks, report.recall(), report.mrr(), report.meanNdcg(), if (passed) "true" else "false" });
    if (!passed) return error.QualityGateFailed;
}

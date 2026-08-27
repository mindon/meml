const std = @import("std");
const meml = @import("meml.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const scales = [_]usize{ 10_000, 100_000, 1_000_000 };
    std.debug.print("MEML deterministic benchmark; dataset: kind=experience subject=agent predicate=uses object=(typescript every 10th, python otherwise) situation=(browser every 3rd, data otherwise)\n", .{});
    for (scales) |count| try runScale(allocator, threaded.io(), count);
    std.debug.print("scale=10000000 status=skipped reason=opt-in-only memory/time envelope not assumed\n", .{});
}

fn runScale(allocator: std.mem.Allocator, io: std.Io, count: usize) !void {
    var runtime = meml.Runtime.init(allocator);
    defer runtime.deinit();
    try runtime.addSignalProvider(meml.signals.Metadata.provider());
    try runtime.addSignalProvider(meml.signals.Embedding.provider());
    try runtime.addSignalProvider(meml.neural.retrievalProvider());
    const write_started = std.Io.Clock.now(.awake, io);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = try runtime.observe("agent", "uses", if (i % 10 == 0) "typescript" else "python", if (i % 3 == 0) "browser" else "data", "success", @intCast(i));
    }
    const write_ns = write_started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds;
    const query = meml.evaluation.Case{ .query = "typescript", .now = @intCast(count), .expected = @intCast(lastMatchingId(count)) };
    const query_started = std.Io.Clock.now(.awake, io);
    var result = try runtime.activateWithStats(.{ .query = query.query, .now = @intCast(count) }, 20, allocator);
    defer result.deinit(allocator);
    const query_ns = query_started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds;
    const report = try meml.evaluation.evaluate(&runtime, &[_]meml.evaluation.Case{query}, 20, allocator);
    try std.Io.Dir.cwd().createDirPath(io, "test-artifacts");
    const state_path = try std.fmt.allocPrint(allocator, "test-artifacts/bench-{d}.state", .{count});
    defer allocator.free(state_path);
    defer std.Io.Dir.cwd().deleteFile(io, state_path) catch {};
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.journal", .{state_path});
    defer allocator.free(journal_path);
    defer std.Io.Dir.cwd().deleteFile(io, journal_path) catch {};
    const index_path = try std.fmt.allocPrint(allocator, "{s}.index", .{state_path});
    defer allocator.free(index_path);
    defer std.Io.Dir.cwd().deleteFile(io, index_path) catch {};
    const index_journal_path = try std.fmt.allocPrint(allocator, "{s}.index.journal", .{state_path});
    defer allocator.free(index_journal_path);
    defer std.Io.Dir.cwd().deleteFile(io, index_journal_path) catch {};
    const persist_started = std.Io.Clock.now(.awake, io);
    try runtime.persistAtomic(io, state_path);
    const persist_ns = persist_started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds;
    const recover_started = std.Io.Clock.now(.awake, io);
    var recovered = try meml.Runtime.recover(allocator, io, state_path);
    defer recovered.deinit();
    const recover_ns = recover_started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds;
    std.debug.print("scale={d} write_ns={d} write_ops_per_sec={d:.2} query_ns={d} persist_ns={d} cold_recover_ns={d} candidates={d} scored={d} returned={d} recall_at_20={d:.3} mrr={d:.3} ndcg={d:.3} pending_experiences={d}\n", .{
        count, write_ns, rate(count, write_ns), query_ns, persist_ns, recover_ns, result.stats.candidates, result.stats.scored, result.stats.returned, report.recall(), report.mrr(), report.meanNdcg(), runtime.pending_experiences,
    });
}

fn lastMatchingId(count: usize) usize {
    if (count == 0) return 0;
    var i = count - 1;
    while (true) : (i -= 1) if (i % 10 == 0) return i + 1;
}

fn rate(operations: usize, nanoseconds: i96) f64 {
    return if (nanoseconds == 0) 0 else @as(f64, @floatFromInt(operations)) * 1_000_000_000 / @as(f64, @floatFromInt(nanoseconds));
}

const std = @import("std");
const meml = @import("meml.zig");

const default_demo_file = "examples/demo.meml";
const demo_state_path = "outputs/demo-memory.state";

/// 演示用的受信反馈校验器：仅接受 trusted-agent 且 receipt 以 "receipt-" 开头。
fn verifyTrustedFeedback(_: *anyopaque, input: meml.FeedbackInput) anyerror!void {
    if (!std.mem.eql(u8, input.actor, "trusted-agent") or !std.mem.startsWith(u8, input.receipt, "receipt-"))
        return error.UntrustedFeedback;
}

fn nodeText(runtime: *const meml.Runtime, id: u64) void {
    if (runtime.store.constNode(id)) |node| {
        std.debug.print("#{d} [{s}] {s} {s} {s}   (conf={d:.2} strength={d:.2})", .{
            id, @tagName(node.kind), node.subject, node.predicate, node.object, node.confidence, node.strength,
        });
    } else {
        std.debug.print("#{d} <missing>", .{id});
    }
}

fn printActivation(runtime: *const meml.Runtime, name: []const u8, activations: std.ArrayList(meml.Activation)) void {
    std.debug.print("\n  activate {s} -> {d} result(s)\n", .{ name, activations.items.len });
    for (activations.items, 0..) |act, i| {
        std.debug.print("    {d}. score={d:.4}  ", .{ i + 1, act.score });
        nodeText(runtime, act.id);
        const s = act.signals;
        std.debug.print(
            "\n        semantic={d:.2} lexical={d:.2} temporal={d:.2} causal={d:.2} procedural={d:.2} preference={d:.2} goal={d:.2} confidence={d:.2} contradiction={d:.2}\n",
            .{ s.semantic, s.lexical, s.temporal, s.causal, s.procedural, s.preference, s.goal, s.confidence, s.contradiction },
        );
    }
}

pub fn main(minimal: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    var args = std.process.Args.Iterator.init(minimal.args);
    _ = args.next(); // skip program name
    const file = args.next() orelse default_demo_file;

    const input = std.Io.Dir.cwd().readFileAlloc(threaded.io(), file, allocator, std.Io.Limit.limited(1 << 20)) catch |err| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ file, @errorName(err) });
        std.debug.print("usage: zig build demo [path-to.meml]\n", .{});
        return err;
    };
    defer allocator.free(input);

    var runtime = meml.Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setFeedbackVerifier(.{ .context = undefined, .verifyFn = verifyTrustedFeedback });

    var report = try meml.source.execute(&runtime, input, allocator);
    defer report.deinit(allocator);

    std.debug.print("== MEML demo: {s} ==\n", .{file});
    std.debug.print(
        "  observed={d} asserted={d} feedback={d} consolidated={d} neural_artifacts={d}\n",
        .{ report.observed, report.asserted, report.feedback, report.consolidated, report.neural_artifacts },
    );

    // 标签顺序与 examples/demo.meml 中的 activate 语句一一对应。
    const context_names = [_][]const u8{ "performance", "data", "privacy", "performance" };
    for (report.activations.items, 0..) |act, i| {
        const label = if (i < context_names.len) context_names[i] else "unknown";
        printActivation(&runtime, label, act);
    }

    // 持久化并恢复到全新 runtime，验证 durability。
    _ = std.Io.Dir.cwd().createDirPath(threaded.io(), "outputs") catch {};
    try runtime.persist(threaded.io(), demo_state_path);
    std.debug.print("\n== persisted to {s}, recovering into a fresh runtime ==\n", .{demo_state_path});

    var recovered = try meml.Runtime.recover(allocator, threaded.io(), demo_state_path);
    defer recovered.deinit();
    try recovered.addSignalProvider(meml.signals.Metadata.provider());
    try recovered.addSignalProvider(meml.neural.retrievalProvider());

    var again = try recovered.activate(.{ .query = "uses", .goal = "pick the right tool", .situation = "systems", .now = 100 }, 3, allocator);
    defer again.deinit(allocator);
    printActivation(&recovered, "performance (after recovery)", again);

    std.debug.print("\nnode count after recovery: {d}\n", .{recovered.store.nodes.items.len});
    std.debug.print("\nDone. Re-run with: zig build demo\n", .{});
}

const std = @import("std");

pub const model = @import("model.zig");
pub const backend = @import("backend.zig");
pub const Store = @import("store.zig").Store;
pub const Runtime = @import("runtime.zig").Runtime;
pub const source = @import("source.zig");
pub const storage = @import("storage.zig");
pub const retrieval = @import("retrieval.zig");
pub const persistence = @import("persistence.zig");
pub const index_journal = @import("index_journal.zig");
pub const signals = @import("signals.zig");
pub const neural = @import("neural.zig");
pub const science = @import("science.zig");
pub const quantum = @import("quantum.zig");
pub const evaluation = @import("evaluation.zig");

pub const Kind = model.Kind;
pub const RelationKind = model.RelationKind;
pub const Node = model.Node;
pub const BeliefState = model.BeliefState;
pub const Relation = model.Relation;
pub const Feedback = source.Feedback;
pub const FeedbackInput = model.FeedbackInput;
pub const FeedbackRecord = model.FeedbackRecord;
pub const FeedbackVerifier = model.FeedbackVerifier;
pub const FeedbackPolicy = model.FeedbackPolicy;
pub const AnnotatedCase = evaluation.AnnotatedCase;
pub const AnnotationReport = evaluation.AnnotationReport;
pub const StructuredCase = evaluation.StructuredCase;
pub const StructuredReport = evaluation.StructuredReport;
pub const StructuredQualityGate = evaluation.StructuredQualityGate;
pub const Outcome = model.Outcome;
pub const FailureClass = model.FailureClass;
pub const ConsolidationRecord = model.ConsolidationRecord;
pub const FingerprintGroup = model.FingerprintGroup;
pub const FingerprintMember = model.FingerprintMember;
pub const Scope = model.Scope;
pub const Metric = model.Metric;
pub const MetricDirection = model.MetricDirection;
pub const Artifact = model.Artifact;
pub const Structure = model.Structure;
pub const RecordInput = model.RecordInput;
pub const Weights = model.Weights;
pub const Context = model.Context;
pub const Signals = model.Signals;
pub const Activation = model.Activation;
pub const Backend = backend.Backend;
pub const SignalProvider = signals.Provider;
pub const SignalPipeline = signals.Pipeline;

test {
    _ = @import("runtime_test.zig");
    _ = @import("science_test.zig");
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var threaded: std.Io.Threaded = .init(gpa.allocator(), .{});
    defer threaded.deinit();
    var runtime = Runtime.init(gpa.allocator());
    defer runtime.deinit();
    _ = try runtime.observe("user", "uses", "typescript", "browser", "success", 10);
    _ = try runtime.observe("user", "uses", "python", "data", "success", 20);
    try runtime.addSignalProvider(signals.Metadata.provider());
    try runtime.addSignalProvider(neural.retrievalProvider());
    var activated = try runtime.activate(.{ .query = "uses", .goal = "browser", .situation = "browser", .now = 20 }, 3, gpa.allocator());
    defer activated.deinit(gpa.allocator());
    try runtime.persist(threaded.io(), "meml.state");
    std.debug.print("MEML: activated {d} context-ranked memories\n", .{activated.items.len});
}

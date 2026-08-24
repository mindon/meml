const std = @import("std");
const model = @import("model.zig");
const runtime_mod = @import("runtime.zig");
const signals = @import("signals.zig");
const neural = @import("neural.zig");

pub const Span = struct {
    line: usize,
    column: usize = 1,
};

pub const DiagnosticPhase = enum { parse, validation };

/// Structured, allocation-free diagnostic for editors and CLI front ends.
pub const Diagnostic = struct {
    phase: DiagnosticPhase,
    span: Span,
    code: []const u8,
    message: []const u8,
};

pub const Compilation = union(enum) {
    program: Program,
    diagnostic: Diagnostic,
};

pub const Observe = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    context: []const u8,
    result: []const u8,
    timestamp: i64,
    label: ?[]const u8 = null,
};

pub const Claim = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    context: []const u8,
    confidence: f64,
    label: ?[]const u8 = null,
};

pub const Link = struct {
    from: []const u8,
    kind: model.RelationKind,
    to: []const u8,
    weight: f64 = 1,
};

pub const Unlink = struct {
    from: []const u8,
    kind: model.RelationKind,
    to: []const u8,
};

pub const Feedback = struct {
    target: []const u8,
    outcome: model.Outcome,
    failure_class: model.FailureClass,
    actor: []const u8,
    receipt: []const u8,
    timestamp: i64,
};

pub const ContextDecl = struct {
    name: []const u8,
    value: model.Context,
};

pub const Activate = struct {
    context_name: []const u8,
    limit: usize,
};

pub const Signal = enum { embedding, metadata, reranker, neural, calibrated };

pub const Statement = union(enum) {
    observe: Observe,
    claim: Claim,
    context: ContextDecl,
    activate: Activate,
    signal: Signal,
    link: Link,
    unlink: Unlink,
    feedback: Feedback,
    consolidate,
    neural_consolidate,
};

pub const LocatedStatement = struct {
    statement: Statement,
    span: Span,
};

pub const Program = struct {
    statements: std.ArrayList(LocatedStatement),
    validation_span: Span = .{ .line = 1 },

    pub fn init() Program {
        return .{ .statements = .empty };
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        self.statements.deinit(allocator);
    }
};

/// Line-oriented parser for the deliberately small MEML source language.
/// String slices point into the supplied source and remain valid while it is kept alive.
pub const Parser = struct {
    input: []const u8,
    last_span: Span = .{ .line = 1 },

    pub fn init(input: []const u8) Parser {
        return .{ .input = input };
    }

    pub fn diagnostic(self: Parser, phase: DiagnosticPhase, err: anyerror) Diagnostic {
        return .{ .phase = phase, .span = self.last_span, .code = @errorName(err), .message = @errorName(err) };
    }

    fn append(program: *Program, allocator: std.mem.Allocator, statement: Statement, span: Span) !void {
        try program.statements.append(allocator, .{ .statement = statement, .span = span });
    }

    pub fn parse(self: *Parser, allocator: std.mem.Allocator) !Program {
        var program = Program.init();
        errdefer program.deinit(allocator);
        var lines = std.mem.splitScalar(u8, self.input, '\n');
        var line_number: usize = 0;
        while (lines.next()) |raw_line| {
            line_number += 1;
            self.last_span = .{ .line = line_number };
            const line = meaningful(raw_line);
            if (line.len == 0) continue;
            const statement_span = self.last_span;
            var words = std.mem.tokenizeAny(u8, line, " \t\r");
            const keyword = words.next() orelse continue;
            if (std.mem.eql(u8, keyword, "context")) {
                const name = words.next() orelse return error.MissingContextName;
                if (!std.mem.eql(u8, words.next() orelse return error.ExpectedOpenBrace, "{")) return error.ExpectedOpenBrace;
                if (words.next() != null) return error.UnexpectedToken;
                var context: model.Context = .{};
                var closed = false;
                while (lines.next()) |field_raw| {
                    line_number += 1;
                    self.last_span = .{ .line = line_number };
                    const field_line = meaningful(field_raw);
                    if (field_line.len == 0) continue;
                    if (std.mem.eql(u8, field_line, "}")) {
                        closed = true;
                        break;
                    }
                    try parseContextField(field_line, &context);
                }
                if (!closed) return error.UnclosedContext;
                try append(&program, allocator, .{ .context = .{ .name = name, .value = context } }, statement_span);
            } else if (std.mem.eql(u8, keyword, "observe")) {
                const subject = words.next() orelse return error.InvalidObserve;
                const predicate = words.next() orelse return error.InvalidObserve;
                const object = words.next() orelse return error.InvalidObserve;
                const context = words.next() orelse return error.InvalidObserve;
                const result = words.next() orelse return error.InvalidObserve;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidObserve, "at")) return error.InvalidObserve;
                const timestamp = try std.fmt.parseInt(i64, words.next() orelse return error.InvalidObserve, 10);
                const label = try optionalLabel(&words, error.InvalidObserve);
                try append(&program, allocator, .{ .observe = .{ .subject = subject, .predicate = predicate, .object = object, .context = context, .result = result, .timestamp = timestamp, .label = label } }, statement_span);
            } else if (std.mem.eql(u8, keyword, "assert")) {
                const subject = words.next() orelse return error.InvalidAssert;
                const predicate = words.next() orelse return error.InvalidAssert;
                const object = words.next() orelse return error.InvalidAssert;
                const context = words.next() orelse return error.InvalidAssert;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidAssert, "confidence")) return error.InvalidAssert;
                const confidence = try std.fmt.parseFloat(f64, words.next() orelse return error.InvalidAssert);
                const label = try optionalLabel(&words, error.InvalidAssert);
                try append(&program, allocator, .{ .claim = .{ .subject = subject, .predicate = predicate, .object = object, .context = context, .confidence = confidence, .label = label } }, statement_span);
            } else if (std.mem.eql(u8, keyword, "activate")) {
                const context_name = words.next() orelse return error.InvalidActivate;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidActivate, "top")) return error.InvalidActivate;
                const limit = try std.fmt.parseInt(usize, words.next() orelse return error.InvalidActivate, 10);
                if (words.next() != null) return error.UnexpectedToken;
                try append(&program, allocator, .{ .activate = .{ .context_name = context_name, .limit = limit } }, statement_span);
            } else if (std.mem.eql(u8, keyword, "link") or std.mem.eql(u8, keyword, "unlink")) {
                const from = words.next() orelse return error.InvalidLink;
                const kind = std.meta.stringToEnum(model.RelationKind, words.next() orelse return error.InvalidLink) orelse return error.InvalidLink;
                const to = words.next() orelse return error.InvalidLink;
                if (std.mem.eql(u8, keyword, "unlink")) {
                    if (words.next() != null) return error.UnexpectedToken;
                    try append(&program, allocator, .{ .unlink = .{ .from = from, .kind = kind, .to = to } }, statement_span);
                } else {
                    var weight: f64 = 1;
                    if (words.next()) |weight_keyword| {
                        if (!std.mem.eql(u8, weight_keyword, "weight")) return error.InvalidLink;
                        weight = try std.fmt.parseFloat(f64, words.next() orelse return error.InvalidLink);
                    }
                    if (words.next() != null) return error.UnexpectedToken;
                    try append(&program, allocator, .{ .link = .{ .from = from, .kind = kind, .to = to, .weight = weight } }, statement_span);
                }
            } else if (std.mem.eql(u8, keyword, "feedback")) {
                const target = words.next() orelse return error.InvalidFeedback;
                const outcome = std.meta.stringToEnum(model.Outcome, words.next() orelse return error.InvalidFeedback) orelse return error.InvalidFeedback;
                const failure_class = std.meta.stringToEnum(model.FailureClass, words.next() orelse return error.InvalidFeedback) orelse return error.InvalidFeedback;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidFeedback, "actor")) return error.InvalidFeedback;
                const actor = words.next() orelse return error.InvalidFeedback;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidFeedback, "receipt")) return error.InvalidFeedback;
                const receipt = words.next() orelse return error.InvalidFeedback;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidFeedback, "at")) return error.InvalidFeedback;
                const timestamp = try std.fmt.parseInt(i64, words.next() orelse return error.InvalidFeedback, 10);
                if (words.next() != null) return error.UnexpectedToken;
                try append(&program, allocator, .{ .feedback = .{ .target = target, .outcome = outcome, .failure_class = failure_class, .actor = actor, .receipt = receipt, .timestamp = timestamp } }, statement_span);
            } else if (std.mem.eql(u8, keyword, "signals")) {
                while (words.next()) |name| try append(&program, allocator, .{ .signal = try signalFor(name) }, statement_span);
            } else if (std.mem.eql(u8, keyword, "consolidate")) {
                if (words.next() != null) return error.UnexpectedToken;
                try append(&program, allocator, .consolidate, statement_span);
            } else if (std.mem.eql(u8, keyword, "neural")) {
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidNeuralCommand, "consolidate")) return error.InvalidNeuralCommand;
                if (!std.mem.eql(u8, words.next() orelse return error.InvalidNeuralCommand, "deterministic")) return error.InvalidNeuralCommand;
                if (words.next() != null) return error.UnexpectedToken;
                try append(&program, allocator, .neural_consolidate, statement_span);
            } else return error.UnknownCommand;
        }
        return program;
    }
};

pub const ExecutionReport = struct {
    observed: usize = 0,
    asserted: usize = 0,
    feedback: usize = 0,
    consolidated: usize = 0,
    neural_artifacts: usize = 0,
    activations: std.ArrayList(std.ArrayList(model.Activation)),

    pub fn init() ExecutionReport {
        return .{ .activations = .empty };
    }
    pub fn deinit(self: *ExecutionReport, allocator: std.mem.Allocator) void {
        for (self.activations.items) |*items| items.deinit(allocator);
        self.activations.deinit(allocator);
    }
};

pub fn compile(input: []const u8, allocator: std.mem.Allocator) Compilation {
    var parser = Parser.init(input);
    var program = parser.parse(allocator) catch |err| return .{ .diagnostic = parser.diagnostic(.parse, err) };
    check(&program, allocator) catch |err| {
        const span = program.validation_span;
        program.deinit(allocator);
        return .{ .diagnostic = .{ .phase = .validation, .span = span, .code = @errorName(err), .message = @errorName(err) } };
    };
    return .{ .program = program };
}

pub fn execute(runtime: *runtime_mod.Runtime, input: []const u8, allocator: std.mem.Allocator) !ExecutionReport {
    const compilation = compile(input, allocator);
    var program = switch (compilation) {
        .program => |program| program,
        .diagnostic => |diagnostic| return switch (diagnostic.phase) {
            .parse => error.ParseFailed,
            .validation => error.ValidationFailed,
        },
    };
    defer program.deinit(allocator);
    var transaction = try runtime.beginTransaction();
    defer transaction.deinit();
    errdefer transaction.rollback() catch {};
    var contexts = std.StringHashMap(model.Context).init(allocator);
    defer contexts.deinit();
    var labels = std.StringHashMap(u64).init(allocator);
    defer labels.deinit();
    var report = ExecutionReport.init();
    for (program.statements.items) |located| {
        const step: anyerror!void = switch (located.statement) {
            .context => |decl| try contexts.put(decl.name, decl.value),
            .observe => |entry| {
                const id = try runtime.observe(entry.subject, entry.predicate, entry.object, entry.context, entry.result, entry.timestamp);
                if (entry.label) |label| try labels.put(label, id);
                report.observed += 1;
            },
            .claim => |entry| {
                const id = try runtime.assert(entry.subject, entry.predicate, entry.object, entry.context, entry.confidence);
                if (entry.label) |label| try labels.put(label, id);
                report.asserted += 1;
            },
            .link => |link| try runtime.link(labels.get(link.from) orelse return error.UnknownLabel, link.kind, labels.get(link.to) orelse return error.UnknownLabel, link.weight),
            .unlink => |unlink| try runtime.unlink(labels.get(unlink.from) orelse return error.UnknownLabel, unlink.kind, labels.get(unlink.to) orelse return error.UnknownLabel),
            .feedback => |feedback| {
                _ = try runtime.recordFeedback(.{ .target = labels.get(feedback.target) orelse return error.UnknownLabel, .outcome = feedback.outcome, .failure_class = feedback.failure_class, .actor = feedback.actor, .receipt = feedback.receipt, .timestamp = feedback.timestamp });
                report.feedback += 1;
            },
            .signal => |signal| try runtime.addSignalProvider(providerFor(signal)),
            .consolidate => {
                const consolidation = try runtime.consolidateAllAtomic(.{});
                report.consolidated += consolidation.memories_created + consolidation.beliefs_created + consolidation.concepts_created + consolidation.procedures_created;
                report.neural_artifacts += consolidation.neural_artifacts_created;
            },
            .neural_consolidate => report.neural_artifacts += try runtime.consolidateNeural(neural.Deterministic.consolidator()),
            .activate => |command| {
                const context = contexts.get(command.context_name) orelse return error.UnknownContext;
                try report.activations.append(allocator, try runtime.activate(context, command.limit, allocator));
            },
        };
        step catch |err| {
            report.deinit(allocator);
            transaction.rollback() catch |rollback_err| return rollback_err;
            transaction.commit();
            return err;
        };
    }
    transaction.commit();
    return report;
}

/// Static validation prevents malformed source, unsafe bounds and lifecycle
/// operations referring to an unknown label from mutating a runtime.
pub fn check(program: *Program, allocator: std.mem.Allocator) !void {
    var contexts = std.StringHashMap(void).init(allocator);
    defer contexts.deinit();
    var labels = std.StringHashMap(void).init(allocator);
    defer labels.deinit();
    for (program.statements.items) |located| {
        program.validation_span = located.span;
        switch (located.statement) {
            .context => |decl| {
                if (decl.name.len == 0 or contexts.contains(decl.name)) return error.InvalidContext;
                try contexts.put(decl.name, {});
            },
            .observe => |entry| {
                if (entry.subject.len == 0 or entry.predicate.len == 0 or entry.object.len == 0) return error.InvalidObserve;
                if (entry.label) |label| try registerLabel(&labels, label);
            },
            .claim => |entry| {
                if (entry.subject.len == 0 or entry.predicate.len == 0 or entry.object.len == 0 or !std.math.isFinite(entry.confidence) or entry.confidence < 0 or entry.confidence > 1) return error.InvalidAssert;
                if (entry.label) |label| try registerLabel(&labels, label);
            },
            .link => |link| if (!labels.contains(link.from) or !labels.contains(link.to) or !std.math.isFinite(link.weight) or link.weight < 0 or link.weight > 1) return error.InvalidLink,
            .unlink => |unlink| if (!labels.contains(unlink.from) or !labels.contains(unlink.to)) return error.InvalidLink,
            .feedback => |feedback| if (!labels.contains(feedback.target) or feedback.actor.len == 0 or feedback.receipt.len == 0 or (feedback.outcome == .success and feedback.failure_class != .none) or (feedback.outcome == .failure and feedback.failure_class == .none)) return error.InvalidFeedback,
            .activate => |command| {
                if (!contexts.contains(command.context_name)) return error.UnknownContext;
                if (command.limit == 0 or command.limit > 1_000) return error.InvalidActivationLimit;
            },
            else => {},
        }
    }
}

fn optionalLabel(words: *std.mem.TokenIterator(u8, .any), invalid: anyerror) !?[]const u8 {
    const marker = words.next() orelse return null;
    if (!std.mem.eql(u8, marker, "as")) return invalid;
    const label = words.next() orelse return invalid;
    if (label.len == 0 or words.next() != null) return invalid;
    return label;
}

fn registerLabel(labels: *std.StringHashMap(void), label: []const u8) !void {
    if (label.len == 0 or labels.contains(label)) return error.DuplicateLabel;
    try labels.put(label, {});
}

fn meaningful(raw: []const u8) []const u8 {
    const without_comment = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
    return std.mem.trim(u8, without_comment, " \t\r");
}

fn parseContextField(line: []const u8, context: *model.Context) !void {
    const separator = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidContextField;
    const key = std.mem.trim(u8, line[0..separator], " \t\r");
    const value = unquote(std.mem.trim(u8, line[separator + 1 ..], " \t\r"));
    if (std.mem.eql(u8, key, "query")) context.query = value else if (std.mem.eql(u8, key, "goal")) context.goal = value else if (std.mem.eql(u8, key, "user")) context.user = value else if (std.mem.eql(u8, key, "situation")) context.situation = value else if (std.mem.eql(u8, key, "preferred")) context.preferred = value else if (std.mem.eql(u8, key, "now")) context.now = try std.fmt.parseInt(i64, value, 10) else if (std.mem.eql(u8, key, "resolve_conflicts")) context.resolve_conflicts = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidBoolean else return error.UnknownContextField;
}

fn unquote(value: []const u8) []const u8 {
    return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
}

fn signalFor(name: []const u8) !Signal {
    if (std.mem.eql(u8, name, "embedding")) return .embedding;
    if (std.mem.eql(u8, name, "metadata")) return .metadata;
    if (std.mem.eql(u8, name, "reranker")) return .reranker;
    if (std.mem.eql(u8, name, "neural")) return .neural;
    if (std.mem.eql(u8, name, "calibrated")) return .calibrated;
    return error.UnknownSignalProvider;
}

fn providerFor(signal: Signal) signals.Provider {
    return switch (signal) {
        .embedding => signals.Embedding.provider(),
        .metadata => signals.Metadata.provider(),
        .reranker => signals.Reranker.provider(),
        .neural => neural.retrievalProvider(),
        .calibrated => signals.Calibrated.provider(),
    };
}

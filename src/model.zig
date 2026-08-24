pub const Kind = enum { experience, evidence, claim, memory, belief, concept, procedure, context };
pub const RelationKind = enum { supports, contradicts, derived_from, generalizes, follows, causes };
pub const BeliefState = enum { active, contested, superseded, archived };

pub const Node = struct {
    id: u64,
    kind: Kind,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    context: []const u8,
    result: []const u8,
    timestamp: i64,
    confidence: f64,
    strength: f64,
    belief_state: BeliefState = .active,
    support_count: u32 = 0,
    contradiction_count: u32 = 0,
    last_confirmed_at: i64 = 0,
    last_contradicted_at: i64 = 0,
};

pub const Relation = struct { from: u64, to: u64, kind: RelationKind, weight: f64 };

/// Structured outcome supplied by an external tool or workflow boundary.
/// A runtime applies it only after a host-provided verifier accepts the actor
/// and receipt; unverified feedback never mutates semantic state.
pub const Outcome = enum { success, failure };
pub const FailureClass = enum { none, timeout, transport, tool_error, invalid_result, policy_denied, unauthorized, cancelled, unknown };
pub const FeedbackInput = struct {
    target: u64,
    outcome: Outcome,
    failure_class: FailureClass = .none,
    actor: []const u8,
    receipt: []const u8,
    timestamp: i64,
};
pub const FeedbackRecord = struct {
    evidence: u64,
    target: u64,
    outcome: Outcome,
    failure_class: FailureClass,
    actor: []const u8,
    receipt: []const u8,
};
pub const FeedbackVerifier = struct {
    context: *anyopaque,
    verifyFn: *const fn (*anyopaque, FeedbackInput) anyerror!void,
    pub fn verify(self: FeedbackVerifier, input: FeedbackInput) !void {
        return self.verifyFn(self.context, input);
    }
};

/// Per-domain feedback policy. Success reinforcement and failure multipliers
/// are explicit runtime configuration, not hidden hard-coded learning rules.
pub const FeedbackPolicy = struct {
    success_increment: f64 = 0.1,
    timeout_multiplier: f64 = 0.95,
    transport_multiplier: f64 = 0.9,
    tool_error_multiplier: f64 = 0.8,
    invalid_result_multiplier: f64 = 0.7,
    unknown_multiplier: f64 = 0.85,
    neutral_multiplier: f64 = 1,
};

pub const ConsolidationRecord = struct {
    artifact: u64,
    rule: []const u8,
    version: u32,
    source_a: u64,
    source_b: u64,
};

pub const FingerprintGroup = struct { fingerprint: u64, count: usize };
pub const FingerprintMember = struct { fingerprint: u64, experience: u64 };

/// Persisted state produced by a neural consolidator. This reference state is
/// deliberately small and deterministic; learned providers can extend the
/// contract with a versioned payload without changing kernel node semantics.
pub const NeuralState = struct {
    artifact: u64,
    activation_count: u64,
    strength: f64,
    version: u32,
};

/// Versioned calibration parameters for a signal provider. These values are
/// data-only checkpoints: providers still run through the kernel-owned score
/// and explanation pipeline.
pub const LearnedSignalState = struct {
    provider: []const u8,
    weight: f64,
    bias: f64,
    version: u32,
};

pub const Weights = struct {
    semantic: f64 = 0.22,
    lexical: f64 = 0.16,
    temporal: f64 = 0.12,
    causal: f64 = 0.12,
    procedural: f64 = 0.10,
    preference: f64 = 0.10,
    goal: f64 = 0.10,
    confidence: f64 = 0.08,
    contradiction: f64 = 0.12,
    external: f64 = 0.18,
};

pub const Context = struct {
    query: []const u8 = "",
    goal: []const u8 = "",
    user: []const u8 = "",
    situation: []const u8 = "",
    now: i64 = 0,
    preferred: []const u8 = "",
    resolve_conflicts: bool = true,
    weights: Weights = .{},
};

pub const Signals = struct {
    semantic: f64 = 0,
    lexical: f64 = 0,
    temporal: f64 = 0,
    causal: f64 = 0,
    procedural: f64 = 0,
    preference: f64 = 0,
    goal: f64 = 0,
    confidence: f64 = 0,
    contradiction: f64 = 0,
    external: f64 = 0,

    pub fn total(self: Signals, weights: Weights) f64 {
        const positive = self.semantic * weights.semantic + self.lexical * weights.lexical + self.temporal * weights.temporal + self.causal * weights.causal + self.procedural * weights.procedural + self.preference * weights.preference + self.goal * weights.goal + self.confidence * weights.confidence;
        return positive - self.contradiction * weights.contradiction + self.external * weights.external;
    }
};

pub const Activation = struct { id: u64, score: f64, signals: Signals };

pub const Kind = enum { experience, evidence, claim, memory, belief, concept, procedure, context };
pub const RelationKind = enum { supports, contradicts, derived_from, generalizes, follows, causes };
pub const BeliefState = enum { active, contested, superseded, archived };

/// Versioned execution or experiment boundary. Keys such as `model`, `dataset`,
/// `backend`, and `code` are conventions rather than kernel-owned domain types.
pub const Scope = struct {
    key: []const u8,
    value: []const u8,
};

pub const MetricDirection = enum { neutral, maximize, minimize };

/// A finite, unit-bearing observation. The direction is declarative metadata;
/// a domain provider decides whether and how it contributes to ranking.
pub const Metric = struct {
    name: []const u8,
    value: f64,
    unit: []const u8 = "",
    uncertainty: ?f64 = null,
    direction: MetricDirection = .neutral,
};

/// A content-addressed external input or output. MEML stores only its reference,
/// never dereferences it or initiates network access.
pub const Artifact = struct {
    kind: []const u8,
    digest: []const u8,
    locator: []const u8 = "",
};

/// Opaque structural identity for a record. Domain adapters define the
/// fingerprint algorithm; the kernel only validates and compares it exactly.
pub const Structure = struct {
    kind: []const u8,
    fingerprint: []const u8,
};

pub const RecordInput = struct {
    kind: Kind = .experience,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    context: []const u8 = "",
    result: []const u8 = "",
    timestamp: i64,
    confidence: f64 = 0.5,
    scopes: []const Scope = &.{},
    metrics: []const Metric = &.{},
    artifacts: []const Artifact = &.{},
    structure: ?Structure = null,
};

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

/// `derived_from` remains the universal lineage edge: the derived record is
/// `from`, and the evidence, artifact, or input record is `to`.
pub const Relation = struct { from: u64, to: u64, kind: RelationKind, weight: f64 };

pub const ScopedRecord = struct { node: u64, scope: Scope };
pub const MetricRecord = struct { node: u64, metric: Metric };
pub const ArtifactRecord = struct { node: u64, artifact: Artifact };
pub const StructureRecord = struct { node: u64, structure: Structure };

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
    scope: f64 = 0.16,
    metric: f64 = 0.10,
    structure: f64 = 0.12,
    lineage: f64 = 0.08,
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
    scopes: []const Scope = &.{},
    structure: ?Structure = null,
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
    scope: f64 = 0,
    metric: f64 = 0,
    structure: f64 = 0,
    lineage: f64 = 0,
    contradiction: f64 = 0,
    external: f64 = 0,

    pub fn total(self: Signals, weights: Weights) f64 {
        const positive = self.semantic * weights.semantic + self.lexical * weights.lexical + self.temporal * weights.temporal + self.causal * weights.causal + self.procedural * weights.procedural + self.preference * weights.preference + self.goal * weights.goal + self.confidence * weights.confidence + self.scope * weights.scope + self.metric * weights.metric + self.structure * weights.structure + self.lineage * weights.lineage;
        return positive - self.contradiction * weights.contradiction + self.external * weights.external;
    }
};

pub const Activation = struct { id: u64, score: f64, signals: Signals };

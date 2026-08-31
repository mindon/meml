pub const Kind = enum { experience, evidence, claim, memory, belief, concept, procedure, context };
pub const RelationKind = enum { supports, contradicts, derived_from, generalizes, follows, causes, verifies, supersedes };

/// IEL classifies the epistemic role of information without imposing domain
/// entities on the kernel. A conventional memory is simply retained information.
pub const InformationKind = enum { fact, claim, observation, hypothesis, policy, preference, decision, procedure };
pub const Trust = enum { unverified, asserted, corroborated, verified, revoked };
pub const Retention = enum { ephemeral, session, working, long_term, archived };

/// Bitemporal, provenance-bearing metadata for a semantic node. `observed_at`
/// is when MEML learned it; `valid_from`/`valid_until` describe when the claim
/// is applicable in the modeled world.
pub const InformationRecord = struct {
    node: u64,
    kind: InformationKind,
    trust: Trust,
    retention: Retention,
    source: []const u8,
    observed_at: i64,
    valid_from: i64,
    valid_until: ?i64 = null,
};

/// Immutable IEL ledger entries describe how the materialized information graph
/// changed. They never execute host actions or embed domain-specific semantics.
pub const EvolutionKind = enum { observe, assert, derive, corroborate, contradict, supersede, expire, revoke, archive, decision, feedback };
pub const EvolutionEvent = struct {
    id: u64,
    kind: EvolutionKind,
    target: u64,
    related: ?u64 = null,
    timestamp: i64,
    source: []const u8,
    reason: []const u8,
};

/// A decision records only which information was relied upon. The host owns
/// the action and authorization; IEL keeps an auditable dependency edge.
pub const DecisionDependency = struct { decision: u64, information: u64, timestamp: i64 };

/// A read-only verification candidate: IEL suggests what could reduce material
/// uncertainty but never performs verification or an external action itself.
pub const VerificationCandidate = struct { information: u64, priority: f64, reason: []const u8 };

/// Lifecycle state for every cognitive record. It is intentionally domain
/// neutral: the host owns actions while MEML controls only memory dynamics.
pub const CognitiveState = enum { active, contested, superseded, archived };

/// Bounded, auditable transformations of cognitive state. There is no generic
/// code execution: every transition is one of these kernel-owned operations.
pub const TransitionKind = enum { set_state, reinforce, penalize, stabilize, decay };

pub const TransitionInput = struct {
    target: u64,
    kind: TransitionKind,
    target_state: ?CognitiveState = null,
    amount: f64 = 0,
    cause: ?u64 = null,
    reason: []const u8,
    actor: []const u8,
    receipt: []const u8,
    timestamp: i64,
};

/// Immutable audit of a committed transition. Before/after values make state
/// evolution replayable and independently verifiable without trusting callers.
pub const TransitionRecord = struct {
    id: u64,
    target: u64,
    cause: ?u64,
    kind: TransitionKind,
    prior_state: CognitiveState,
    next_state: CognitiveState,
    prior_confidence: f64,
    next_confidence: f64,
    prior_strength: f64,
    next_strength: f64,
    timestamp: i64,
    reason: []const u8,
    actor: []const u8,
    receipt: []const u8,
};

pub const ActivationPolicy = enum { active_only, include_contested, include_historical };

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
    cognitive_state: CognitiveState = .active,
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
pub const FeedbackAttestation = struct {
    issuer: []const u8,
    key_id: []const u8,
    nonce: []const u8,
    issued_at: i64,
    expires_at: i64,
    signature: [64]u8,
};

/// A host-public-key trust entry. Secret keys never enter MEML state.
pub const FeedbackAttestationIssuer = struct {
    issuer: []const u8,
    key_id: []const u8,
    public_key: [32]u8,
};

/// Runtime-only signed-feedback policy. Its keys are deployment configuration,
/// while consumed attestation digests are persisted with semantic state.
pub const FeedbackAttestationPolicy = struct {
    issuers: []const FeedbackAttestationIssuer,
};

pub const AttestationReplayRecord = struct {
    digest: [32]u8,
    expires_at: i64,
};

pub const FeedbackInput = struct {
    target: u64,
    outcome: Outcome,
    failure_class: FailureClass = .none,
    actor: []const u8,
    receipt: []const u8,
    timestamp: i64,
    attestation: ?FeedbackAttestation = null,
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

/// Host-owned zero-trust boundary for state transitions. The kernel never
/// treats a caller-provided receipt as authoritative on its own.
pub const TransitionVerifier = struct {
    context: *anyopaque,
    verifyFn: *const fn (*anyopaque, TransitionInput) anyerror!void,
    pub fn verify(self: TransitionVerifier, input: TransitionInput) !void {
        return self.verifyFn(self.context, input);
    }
};

/// A bounded plasticity response selected only after verified feedback. The
/// kernel may change one lifecycle state and apply one numeric adjustment; it
/// never executes host actions or arbitrary code.
pub const PlasticityRule = struct {
    state: ?CognitiveState = null,
    adjustment: ?TransitionKind = null,
    amount: f64 = 0,
};

/// Host-owned configuration for how verified outcomes reshape future cognitive
/// dynamics. It is intentionally runtime configuration rather than persisted
/// memory state, so deployment policy and authorization stay outside MEML15.
pub const PlasticityPolicy = struct {
    success: PlasticityRule = .{ .adjustment = .reinforce, .amount = 0.1 },
    timeout: PlasticityRule = .{ .state = .contested, .adjustment = .penalize, .amount = 0.05 },
    transport: PlasticityRule = .{ .state = .contested, .adjustment = .penalize, .amount = 0.1 },
    tool_error: PlasticityRule = .{ .state = .contested, .adjustment = .penalize, .amount = 0.2 },
    invalid_result: PlasticityRule = .{ .state = .contested, .adjustment = .penalize, .amount = 0.3 },
    policy_denied: PlasticityRule = .{},
    unauthorized: PlasticityRule = .{},
    cancelled: PlasticityRule = .{},
    unknown: PlasticityRule = .{ .state = .contested, .adjustment = .penalize, .amount = 0.15 },
};

/// Derived, explainable stability class. It is computed from evidence,
/// transitions, conflicts, and current state; it is not a second mutable truth.
pub const AttractorState = enum { transient, emerging, stable, contested };
pub const Stability = struct {
    state: AttractorState,
    score: f64,
    support: usize,
    contradiction: usize,
    transitions: usize,
};

/// Bounded kernel-owned graph propagation. Providers still route initial
/// candidates; the kernel applies this budget, lifecycle filtering, and score.
pub const PropagationBudget = struct {
    seed_limit: usize = 64,
    max_hops: u8 = 0,
    edge_limit: usize = 256,
    candidate_limit: usize = 128,
};

/// Historical, scope-compatible estimate for a procedure. This is an empirical
/// outcome summary, not a world-model claim or an instruction to take action.
pub const ProcedurePrediction = struct {
    procedure: u64,
    compatible: bool,
    samples: usize,
    successes: usize,
    failures: usize,
    success_probability: f64,
    evidence_coverage: f64,
};

/// A conservative gate for deciding whether an explicitly supplied procedure
/// has enough compatible, stable, verified history to be recommended. This is
/// host runtime policy and is not persisted as memory state.
pub const ProcedureSelectionQualityGate = struct {
    min_stability: f64 = 0.75,
    min_samples: usize = 3,
    min_success_probability: f64 = 0.5,
    min_evidence_coverage: f64 = 0.5,
    require_active: bool = true,
    require_scope_compatibility: bool = true,
};

pub const ProcedureSelectionStatus = struct {
    active: bool,
    scope_compatible: bool,
    stability_sufficient: bool,
    samples_sufficient: bool,
    success_probability_sufficient: bool,
    evidence_coverage_sufficient: bool,

    pub fn eligible(self: ProcedureSelectionStatus) bool {
        return self.active and self.scope_compatible and self.stability_sufficient and self.samples_sufficient and self.success_probability_sufficient and self.evidence_coverage_sufficient;
    }
};

/// Read-only comparison for a caller-provided candidate set. Null score/rank
/// means the candidate was rejected by the gate and never entered comparison.
pub const ProcedureSelection = struct {
    procedure: u64,
    stability: Stability,
    history: ProcedurePrediction,
    status: ProcedureSelectionStatus,
    counterfactual_score: ?f64 = null,
    rank: ?usize = null,
};

pub const max_procedure_objectives = 8;

/// The caller must declare every comparison dimension. Metric selectors use an
/// exact name/unit pair, so the kernel never assumes what “cost”, “error”, or
/// “fidelity” means and never performs implicit unit conversion.
pub const ProcedureMetricTarget = struct { name: []const u8, unit: []const u8 };

pub const ProcedureObjectiveTarget = union(enum) {
    stability,
    success_probability,
    evidence_coverage,
    metric: ProcedureMetricTarget,
};

pub const ProcedureObjective = struct {
    target: ProcedureObjectiveTarget,
    direction: MetricDirection,
    weight: f64,
    /// maximize: conservative_value >= hard_limit; minimize: <= hard_limit.
    hard_limit: ?f64 = null,
};

/// Caller-owned, non-persistent policy for a read-only comparison over an
/// explicit candidate list. It cannot trigger retrieval, propagation, tools,
/// or an action.
pub const ProcedureComparisonPolicy = struct {
    require_active: bool = true,
    require_scope_compatibility: bool = true,
    min_samples: usize = 3,
    objectives: []const ProcedureObjective,
};

pub const ProcedureComparisonRejection = enum {
    none,
    inactive,
    scope_incompatible,
    insufficient_samples,
    missing_metric,
    metric_direction_mismatch,
    hard_limit_failed,
};

pub const ProcedureObjectiveAssessment = struct {
    observed_value: ?f64 = null,
    uncertainty: ?f64 = null,
    conservative_value: ?f64 = null,
    normalized_value: ?f64 = null,
    hard_limit_satisfied: bool = false,
    rejection: ProcedureComparisonRejection = .none,
};

pub const ProcedureComparisonStatus = struct {
    active: bool,
    scope_compatible: bool,
    samples_sufficient: bool,
    objectives_sufficient: bool,

    pub fn eligible(self: ProcedureComparisonStatus) bool {
        return self.active and self.scope_compatible and self.samples_sufficient and self.objectives_sufficient;
    }
};

/// A bounded empirical counterfactual: “among only these candidates, with only
/// the declared objectives, which past evidence is preferable?” Null score/rank
/// denotes a rejected candidate, not an unknown future outcome.
pub const ProcedureComparison = struct {
    procedure: u64,
    stability: Stability,
    history: ProcedurePrediction,
    status: ProcedureComparisonStatus,
    assessment_count: usize,
    assessments: [max_procedure_objectives]ProcedureObjectiveAssessment = undefined,
    counterfactual_score: ?f64 = null,
    rank: ?usize = null,
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
    stability: f64 = 0.12,
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
    activation_policy: ActivationPolicy = .active_only,
    minimum_stability: f64 = 0,
    propagation: PropagationBudget = .{},
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
    stability: f64 = 0,
    contradiction: f64 = 0,
    external: f64 = 0,

    pub fn total(self: Signals, weights: Weights) f64 {
        const positive = self.semantic * weights.semantic + self.lexical * weights.lexical + self.temporal * weights.temporal + self.causal * weights.causal + self.procedural * weights.procedural + self.preference * weights.preference + self.goal * weights.goal + self.confidence * weights.confidence + self.scope * weights.scope + self.metric * weights.metric + self.structure * weights.structure + self.lineage * weights.lineage + self.stability * weights.stability;
        return positive - self.contradiction * weights.contradiction + self.external * weights.external;
    }
};

pub const ProviderContribution = struct {
    name: []const u8 = "",
    score: f64 = 0,
    weight: f64 = 0,
};

/// Fixed-capacity provider trace keeps activation explanations allocation-free.
/// Provider names are borrowed from registered providers and must outlive use.
pub const ProviderTrace = struct {
    count: u8 = 0,
    items: [8]ProviderContribution = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
};

pub const Activation = struct {
    id: u64,
    score: f64,
    signals: Signals,
    provider_trace: ProviderTrace = .{},
};

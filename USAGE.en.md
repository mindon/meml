# MEML Usage Guide

This is the operations manual for MEML, covering three integration paths: the **Zig library (`meml`)**, the **command-line bridge (`meml`)**, and **source-language scripts (`.meml`)**.

| Entry point | Artifact | Best for |
|---|---|---|
| Zig library | `src/meml.zig` | Hosts that are themselves Zig, linking directly with zero bridge cost |
| CLI | `zig-out/bin/meml` | Any language (Python / TypeScript / Go …) calling through a subprocess |
| Source language | `*.meml` files | Writing memory policy as editable, versionable, transactionally-executed scripts |

All three share the same `Runtime` kernel: semantics, scoring, ordering, conflict rules, and activation explanations are identical; only the calling shape differs.

---

## 1. Building

Requires Zig 0.17.

```sh
zig build          # installs meml-example and meml into zig-out/bin/
zig build test     # runs the tests
zig build example  # runs the minimal library example
zig build demo     # runs the examples/demo.meml end-to-end demo
zig build bench -Doptimize=ReleaseFast   # runs the deterministic retrieval benchmark
```

---

## 2. Using the Zig library (`meml`)

### 2.1 Core lifecycle

```text
observe/assert (write) → activate (retrieve) → recordFeedback (write back outcome)
→ consolidate (build long-term structure) → persist (save) → recover (restore)
```

### 2.2 Minimal runnable example

```zig
const std = @import("std");
const meml = @import("meml");

// Host trust boundary: validates the feedback actor and receipt.
fn verify(ctx: *anyopaque, input: meml.FeedbackInput) anyerror!void {
    _ = ctx;
    if (!std.mem.eql(u8, input.actor, "workbuddy")) return error.UntrustedActor;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Create the runtime
    var runtime = meml.Runtime.init(a);
    defer runtime.deinit();

    // 2. Write an experience (experience-level, with a timestamp)
    const exp = try runtime.observe("user", "uses", "typescript", "frontend", "success", 10);

    // 3. Assert a higher-level claim (with confidence)
    const claim = try runtime.assert("user", "uses", "typescript", "frontend", 0.8);

    // 4. Establish a relation: the claim is supported by exp
    try runtime.support(claim, exp, 0.9);

    // 5. Add signal providers (optional; affects scoring, not memory identity)
    try runtime.addSignalProvider(meml.signals.Metadata.provider());
    try runtime.addSignalProvider(meml.neural.retrievalProvider());

    // 6. Retrieve by context, returning an explainable activation list
    var acts = try runtime.activate(.{
        .query = "uses",
        .goal = "pick a tool",
        .situation = "frontend",
        .preferred = "typescript",
        .now = 20,
    }, 5, a);
    defer acts.deinit(a);
    for (acts.items) |act| {
        std.debug.print("id={d} score={d} semantic={d} confidence={d}\n", .{
            act.id, act.score, act.signals.semantic, act.signals.confidence,
        });
    }

    // 7. Configure the trust boundary, then write back the outcome (context can carry host verification state; a placeholder is used here)
    var trust_state: u8 = 0;
    runtime.setFeedbackVerifier(.{ .context = &trust_state, .verifyFn = verify });
    _ = try runtime.recordFeedback(.{
        .target = claim,
        .outcome = .success,
        .failure_class = .none,
        .actor = "workbuddy",
        .receipt = "receipt-1",
        .timestamp = 30,
    });

    // 8. Consolidate into long-term memory
    const report = try runtime.consolidateAllAtomic(.{});
    _ = report;

    // 9. Persist and recover
    try runtime.persist(io, "meml.state");
    var restored = try meml.Runtime.recover(a, io, "meml.state");
    defer restored.deinit();
}
```

### 2.3 General Structured Records

`record(RecordInput)` writes reproducible experiment or workflow evidence without adding domain entities to the kernel; `observe()` remains suitable for lightweight text-only experience. Supply scopes in `key` order, metrics in `name`/`unit` order, and artifacts in digest order for stable identity.

```zig
const scopes = [_]meml.Scope{ .{ .key = "code", .value = "v2" }, .{ .key = "environment", .value = "prod" } };
const metrics = [_]meml.Metric{.{ .name = "quality", .value = 0.99, .unit = "ratio", .uncertainty = 0.01, .direction = .maximize }};
const artifacts = [_]meml.Artifact{.{ .kind = "result", .digest = "0123456789abcdef" }};
const id = try runtime.record(.{
    .subject = "agent", .predicate = "selected", .object = "strategy",
    .timestamp = 100, .scopes = &scopes, .metrics = &metrics, .artifacts = &artifacts,
    .structure = .{ .kind = "workflow", .fingerprint = "fedcba9876543210" },
});
var acts = try runtime.activate(.{ .query = "strategy", .scopes = &scopes, .structure = .{ .kind = "workflow", .fingerprint = "fedcba9876543210" } }, 5, a);
defer acts.deinit(a);
_ = id;
```

`science.Generic.adapter()` provides the same general validation boundary; `quantum.adapter()` is only an optional quantum input-normalization example. Neither may mutate `Store` directly. See [`docs/domain-memory.md`](docs/domain-memory.md).

### 2.4 Dynamic Cognitive State

MEML changes only auditable memory state; it never chooses or executes a host Action. A host must install a `TransitionVerifier` before calling bounded `transition()`; every change is persisted as a `TransitionRecord` in `MEML15`.

```zig
runtime.setTransitionVerifier(host_transition_verifier);
_ = try runtime.transition(.{
    .target = procedure_id,
    .kind = .stabilize,
    .amount = 0.1,
    .reason = "verified-repeat-success",
    .actor = "trusted-runner",
    .receipt = "verified-receipt",
    .timestamp = now,
});

var current = try runtime.activate(.{ .query = "procedure" }, 5, a); // active only by default
var audit = try runtime.activate(.{ .query = "procedure", .activation_policy = .include_historical }, 5, a);
defer current.deinit(a);
defer audit.deinit(a);
```

The bounded DSL form is `transition <label> reinforce|penalize|decay|stabilize <0..1> actor <actor> receipt <receipt> at <timestamp> reason <reason>`; for `set_state`, replace the numeric value with `active|contested|superseded|archived`. See [`docs/dynamic-memory.md`](docs/dynamic-memory.md) and [`examples/dynamic-memory.jsonl`](examples/dynamic-memory.jsonl).

### 2.5 Signed feedback attestations

For executable feedback, prefer an Ed25519 attestation over the compatibility callback. Install only host public keys with `setFeedbackAttestationPolicy`; `FeedbackAttestation` signs a canonical payload that binds issuer/key ID, nonce, issuance and expiry, feedback fields, opaque receipt reference, and every semantic field of the target node. A valid attestation must name the same actor as its issuer and remain valid at the event and runtime clocks. MEML persists only the SHA-256 digest and expiry of an accepted payload in `MEML15`, so a consumed attestation remains rejected after recovery; it never persists its nonce, signature, or private key.

CLI hosts configure Base64-encoded public keys with `set_attestation_verifier` and pass a Base64-encoded 64-byte signature under `feedback.attestation`. Treat `receipt` as an opaque reference, not a credential. `clear_verifier` removes both the legacy and signed-feedback policies; public-key configuration must be reinstalled after `recover`.

### 2.6 Frozen retrieval evaluation

`zig build eval` loads `eval/datasets/retrieval-v1/seed.jsonl`, resolves the human labels in `annotations.jsonl` through stable `record_key` values, and compares multi-label Recall@K, MRR, and graded NDCG against `eval/baselines/retrieval-v1.json`. The emitted JSON report is deterministic; CI runs this gate on every push and pull request. Dataset updates must use a new version directory and a reviewed baseline rather than rewriting an existing benchmark.

### 2.7 Procedure Selection Quality Gate

`selectProcedures()` compares only procedure IDs explicitly supplied by the host. It never retrieves or expands candidates and never executes an Action. The gate requires active state, exact scope compatibility, stability, verified-outcome sample count, success probability, and evidence coverage; rejected candidates retain their reason dimensions but receive no rank.

```zig
var choices = try runtime.selectProcedures(
    &.{ procedure_a, procedure_b },
    .{ .scopes = &scopes },
    .{ .min_stability = 0.75, .min_samples = 3, .min_success_probability = 0.6, .min_evidence_coverage = 0.5 },
    a,
);
defer choices.deinit(a);
// rank == 1 is an empirical recommendation among explicit candidates only.
```

Use `predictProcedureAt()` for cutoff-based historical prediction evaluation. `selectProcedures()` uses current cognitive state only, preventing future state from leaking into historical selection replay. The JSONL example is [`examples/procedure-selection.jsonl`](examples/procedure-selection.jsonl).

### 2.8 Explicit Multi-Objective Comparison

`compareProcedures()` compares only caller-provided procedure IDs and requires callers to declare every target, direction, weight, and optional hard constraint. Targets may be `stability`, `success_probability`, `evidence_coverage`, or an exact metric `name + unit`; the kernel never infers domain semantics or converts units.

```zig
const objectives = [_]meml.ProcedureObjective{
    .{ .target = .{ .metric = .{ .name = "cost", .unit = "usd" } }, .direction = .minimize, .weight = 0.2 },
    .{ .target = .{ .metric = .{ .name = "latency", .unit = "ms" } }, .direction = .minimize, .weight = 0.8, .hard_limit = 40 },
};
var comparisons = try runtime.compareProcedures(
    &.{ fast_procedure, cheap_procedure },
    .{ .scopes = &scopes },
    .{ .min_samples = 3, .objectives = &objectives },
    a,
);
defer comparisons.deinit(a);
```

Metric uncertainty is incorporated conservatively: maximize uses `value - uncertainty`, while minimize uses `value + uncertainty`. Candidates with missing metrics, direction conflicts, or failed constraints have no score/rank but retain per-objective rejection reasons. This API never invokes retrieval, a backend, graph expansion, a tool, or an Action. See [`examples/procedure-comparison.jsonl`](examples/procedure-comparison.jsonl).

### 2.9 Core API

Public methods on `Runtime` (`src/runtime.zig`):

| Group | Method | Description |
|---|---|---|
| Lifecycle | `init(allocator)` / `deinit()` | Create / release |
| Write | `observe(subject, predicate, object, context, result, timestamp) !u64` | Record an experience, returns the node id |
| | `assert(subject, predicate, object, context, confidence) !u64` | Assert a claim, returns the node id |
| | `remember(id) !u64` | Promote a node to memory |
| | `infer(id) !u64` | Derive a new node from a node |
| Relations | `link(from, kind, to, weight)` / `unlink(from, kind, to)` | Create / delete an explicit relation |
| | `support(from, to, weight)` / `contradict(from, to)` | Support / contradict |
| Cognitive state | `supersedeBelief(old, replacement)` | Belief replacement; its state change is audited |
| Dynamic transitions | `setTransitionVerifier(verifier)` / `clearTransitionVerifier()` | Host trust boundary |
| | `transition(input) !u64` / `verifyTransitionHistory()` | Bounded state change / audit continuity |
| Abstraction | `generalize(ids, concept) !u64` / `inferProcedure(ids, name) !u64` | Generalize a concept / procedure |
| Retrieval | `activate(context, limit, allocator) !ArrayList(Activation)` | Contextual retrieval |
| | `activateWithStats(context, limit, allocator) !retrieval.Result` | Retrieve and return candidate/scoring statistics |
| Procedure decisions | `stability(id)` / `predictProcedureAt(id, context, cutoff)` | Derived stability / historical outcome estimate |
| | `selectProcedures(ids, context, gate, allocator)` | Quality gate and empirical comparison for explicit candidates only |
| Signals | `addSignalProvider(provider)` / `setSignalCalibration(weight, bias)` / `addCalibratedSignalProvider()` | Attach replaceable signals |
| Feedback | `setFeedbackVerifier(verifier)` / `clearFeedbackVerifier()` | Trust boundary |
| | `setPlasticityPolicy(policy)` / `recordFeedback(input) !u64` | Verified outcome-driven plasticity |
| Consolidation | `consolidate()` / `consolidateAll()` / `consolidatePending(policy)` | Explicit consolidation |
| | `consolidateWithPolicy(policy)` / `consolidateAllAtomic(policy)` / `consolidatePendingAtomic(policy)` | Policy-driven / atomic consolidation |
| | `consolidateNeural(consolidator) !usize` | Deterministic neural consolidation |
| | `enableAutoConsolidation(policy)` / `disableAutoConsolidation()` | Event-triggered consolidation |
| Backend | `useVectorBackend()` / `useGraphBackend()` | Switch candidate provider |
| Persistence | `persist(io, path)` / `persistAtomic(io, path)` | Save (atomic write optional) |
| | `persistTo(provider, io, path)` / `persistIfRevision(provider, expected_revision, io, path)` | Custom / CAS |
| | `recover(allocator, io, path) !Runtime` | Restore |

### 2.10 Key types and enums

```zig
pub const Kind = enum { experience, evidence, claim, memory, belief, concept, procedure, context };
pub const RelationKind = enum { supports, contradicts, derived_from, generalizes, follows, causes };
pub const CognitiveState = enum { active, contested, superseded, archived };
pub const TransitionKind = enum { set_state, reinforce, penalize, stabilize, decay };
pub const Outcome = enum { success, failure };
pub const FailureClass = enum { none, timeout, transport, tool_error, invalid_result, policy_denied, unauthorized, cancelled, unknown };
```

```zig
pub const Context = struct {
    query: []const u8 = "",
    goal: []const u8 = "",
    user: []const u8 = "",
    situation: []const u8 = "",
    now: i64 = 0,
    preferred: []const u8 = "",
    resolve_conflicts: bool = true,
};

pub const FeedbackInput = struct {
    target: u64,
    outcome: Outcome,
    failure_class: FailureClass = .none,
    actor: []const u8,
    receipt: []const u8,
    timestamp: i64,
};

pub const Signals = struct {
    semantic: f64 = 0,    lexical: f64 = 0,     temporal: f64 = 0,
    causal: f64 = 0,      procedural: f64 = 0,  preference: f64 = 0,
    goal: f64 = 0,        confidence: f64 = 0,  contradiction: f64 = 0,
    external: f64 = 0,
};
```

Signal providers are provided by `src/signals.zig` and `src/neural.zig`:

```zig
meml.signals.Metadata.provider()
meml.signals.Embedding.provider()
meml.signals.Reranker.provider()
meml.signals.Calibrated.provider()
meml.neural.retrievalProvider()
```

`LocalEmbedding` is a host-owned local vector-cache provider: the host precomputes query/node vectors and supplies callbacks; MEML only computes local cosine scores. `backend.LocalSemantic` exposes a host-local ANN candidate source under the same boundary; compose it with any lexical provider through `backend.Hybrid` for a deduplicated union. MEML neither loads models nor performs network I/O, and does not persist vectors, models, or credentials. The host should record `model_version` and `model_sha256` as auditable artifact metadata.

---

## 3. Command-line bridge (`meml`)

`meml` is a JSON-lines bridge: **one JSON request in per line, one JSON response out per line**, with state preserved across requests within the same process.

### 3.1 Three run modes

| Mode | Command | Description |
|---|---|---|
| Single request | `meml '<json>'` | Processes a single request and exits; **fresh state each time** |
| Long-running REPL | `meml` (stdin, line by line) | State persists across requests; ideal for an agent's long-running subprocess |
| File | `meml --file reqs.jsonl` | Batch processing, line by line |

Response format: `{"ok":true,...}` or `{"ok":false,"error":"..."}`.

### 3.2 Command table

| op | Request fields | Returns |
|---|---|---|
| `ping` | — | `{ok,pong}` |
| `observe` | `subject,predicate,object,context,result,timestamp` | `{ok,id}` |
| `assert` | `subject,predicate,object,context,confidence` | `{ok,id}` |
| `remember` | `id` | `{ok,id}` |
| `infer` | `id` | `{ok,id}` |
| `link` | `from,kind,to,weight` | `{ok}` |
| `unlink` | `from,kind,to` | `{ok}` |
| `support` | `from,to,weight` | `{ok}` |
| `contradict` | `from,to` | `{ok}` |
| `transition` | `target,kind,target_state|amount,cause?,reason,actor,receipt,timestamp` | `{ok,transition}` |
| `supersede` | `old,replacement` | `{ok}` |
| `generalize` | `ids,concept` | `{ok,id}` |
| `procedure` | `ids,name` | `{ok,id}` |
| `activate` | `query,goal,user,situation,now,preferred,scopes,structure,activation_policy,minimum_stability,propagation,resolve_conflicts,limit,stats,details` | `{ok,activations}` |
| `predict_procedure` | `procedure,scopes?,cutoff` | `{ok,success_probability,evidence_coverage,…}` |
| `select_procedures` | `ids,scopes?,gate?` | `{ok,selections}`; compares explicit candidates only |
| `compare_procedures` | `ids,scopes?,min_samples?,objectives` | `{ok,comparisons}`; conservative multi-objective comparison with explicit targets |
| `feedback` | `target,outcome,failure_class,actor,receipt,timestamp,attestation?` | `{ok,evidence}` |
| `set_attestation_verifier` | `issuers[{issuer,key_id,public_key}]` | `{ok}`; Base64 Ed25519 public keys |
| `consolidate` | `repeat_threshold,procedure_success_ratio,enable_memory,…` | `{ok,stats}` |
| `auto_consolidate` | `enable,…` | `{ok}` |
| `signals` | `providers` | `{ok,providers}`; each entry may be a name or `{name,weight}` |
| `backend` | `backend` | `{ok}`; `hybrid` is lexical ∪ local hash-vector candidates |
| `persist` | `path?,atomic` | `{ok}`; defaults to `~/.meml/state/memory.state` when `path` is omitted |
| `recover` | `path?` | `{ok}`; defaults to `~/.meml/state/memory.state` when `path` is omitted |
| `import_meml` | `files` | `{ok,documents,observed,asserted,links}`; atomically imports multiple restricted `.meml` files |
| `exec` | `program` | `{ok,stats}` |
| `set_verifier` | `trusted_actors,receipt_prefix` | `{ok}` |
| `clear_verifier` | — | `{ok}` |
| `set_plasticity_policy` | `success?,timeout?,transport?,tool_error?,…` (each with `state?`,`adjustment?`,`amount`) | `{ok}` |

Enum values:

- `kind`: `supports | contradicts | derived_from | generalizes | follows | causes`
- `state`: `active | contested | superseded | archived`
- `outcome`: `success | failure`
- `failure_class`: `none | timeout | transport | tool_error | invalid_result | policy_denied | unauthorized | cancelled | unknown`
- `backend`: `vector | graph | hybrid`
- `providers` entries may be strings or `{ "name":"embedding", "weight":2 }`; `activate` returns a `provider_trace` with each provider's raw `score` and configured `weight`.

Text matching uses the shared `tokenizer-ascii-v1`: ASCII case normalization with compatible delimiter tokenization. It deliberately does not infer Chinese/CJK segmentation.
- `providers` (array): `metadata | embedding | reranker | calibrated | neural`

### 3.3 Multi-source memory import and default storage

`import_meml` reads relative `.meml` files below the current working directory in `files` order and imports the entire batch as one in-memory transaction. It is not a `MEML15` snapshot merge: each document has an isolated label scope and may contain only `observe`, `assert`, and `link` statements that reference labels in the same document. `feedback`, `transition`, `unlink`, `signals`, `consolidate`, and retrieval statements are rejected. Paths must not be absolute or contain `.` / `..` components; the limits are 512 KiB per file, 4 MiB per batch, and 64 files. Importing does not persist automatically; call `persist` explicitly after success.

```jsonl
{"op":"import_meml","files":["examples/import-preferences.meml","examples/import-history.meml"]}
{"op":"persist","atomic":true}
```

When no `path` is supplied, both `persist` and `recover` use `~/.meml/state/memory.state`; `persist` creates the parent directory. Integrations should prefer `MEML_STATE_PATH` and use distinct Agent filenames (such as `codebuddy.state`) to avoid accidental cross-host state sharing.

### 3.4 Shell example

```sh
# Long-running mode: state persists across requests
printf '%s\n' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"typescript","context":"frontend","result":"success","timestamp":10}' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"python","context":"backend","result":"success","timestamp":20}' \
  '{"op":"activate","query":"uses","goal":"pick a tool","situation":"frontend","limit":5,"details":true}' \
  '{"op":"set_verifier","trusted_actors":["workbuddy"],"receipt_prefix":"receipt-"}' \
  '{"op":"feedback","target":1,"outcome":"success","failure_class":"none","actor":"workbuddy","receipt":"receipt-1","timestamp":80}' \
  '{"op":"persist","path":"meml.state","atomic":true}' \
| ./zig-out/bin/meml
```

### 3.5 Python long-running process example (agent integration)

```python
import subprocess, json

proc = subprocess.Popen(
    ["zig-out/bin/meml"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)

def meml(req):
    proc.stdin.write(json.dumps(req) + "\n"); proc.stdin.flush()
    return json.loads(proc.stdout.readline())

# 1. Recover existing memory
meml({"op": "recover", "path": "meml.state"})

# 2. Configure the trust boundary (prerequisite for feedback)
meml({"op": "set_verifier", "trusted_actors": ["workbuddy"], "receipt_prefix": "receipt-"})

# 3. Record an experience
r = meml({"op": "observe", "subject": "user", "predicate": "uses",
          "object": "typescript", "context": "frontend", "result": "success", "timestamp": 10})

# 4. Retrieve
acts = meml({"op": "activate", "query": "uses", "goal": "pick a tool",
             "situation": "frontend", "limit": 5, "details": True})
for a in acts["activations"]:
    print(a["id"], a["score"], a["signals"]["semantic"], a["signals"]["confidence"])

# 5. Write back the outcome after running the real task
meml({"op": "feedback", "target": r["id"], "outcome": "success",
      "failure_class": "none", "actor": "workbuddy", "receipt": "receipt-ts", "timestamp": 80})

# 6. Settle long-term memory + persist
meml({"op": "consolidate", "repeat_threshold": 2})
meml({"op": "persist", "path": "meml.state", "atomic": True})

proc.stdin.close()
```

> Note: `feedback` is writable by default. Calling `set_verifier` or `set_attestation_verifier` explicitly enables proof enforcement: an untrusted actor returns `UntrustedActor`, a receipt-prefix mismatch returns `UntrustedReceipt`, and missing or invalid attestations are rejected.

---

## 4. Source-language scripts (`.meml`)

`.meml` is a restricted domain command set; it is parsed and statically validated before execution, and the whole program runs as a runtime transaction. It is suited to writing memory policy as editable, versionable files.

### 4.1 Syntax

```meml
# observe records an experience (optionally tagged with as)
observe user uses typescript frontend success at 10

# assert declares a claim (confidence + as label)
assert user uses typescript frontend confidence 0.8 as ts_use

# context defines a retrieval context
context performance {
    goal: "pick the right tool"
    situation: systems
    query: uses
    preferred: zig
}

# enable signal providers
signals metadata neural

# activate retrieves by context
activate performance top 5

# feedback writes back the outcome
feedback ts_use success none actor workbuddy receipt receipt-1 at 80

# link / unlink explicit relations
link zig_use contradicts py_systems weight 1

# consolidate
consolidate
neural consolidate deterministic
```

### 4.2 Running

```sh
zig build demo                       # runs examples/demo.meml
```

```zig
// Execute a script from the library
var report = try meml.source.execute(&runtime, script_text, allocator);
// report.observed / asserted / feedback / consolidated / neural_artifacts
```

```sh
# Execute a script via the CLI
./zig-out/bin/meml '{"op":"exec","program":"observe user prefers typescript frontend success at 10"}'
```

> A script run through `exec` may contain `feedback` by default. Configure `set_verifier` or `set_attestation_verifier` in the same process only when feedback must require host proof.

Reference scripts: `examples/contextual_retrieval.meml`, `examples/demo.meml`.

---

## 5. Recommended agent integration lifecycle

```text
recover (restore) → activate (retrieve into context) → execute → feedback (write back outcome)
→ consolidate (periodic) → persist (save)
```

- After every conversation / tool call, `observe()` records the experience.
- Before deciding, `activate()` retrieves by the current `Context`, injecting explainable activations into the prompt or using them for tool / policy selection.
- Write back real outcomes with `recordFeedback()`: successes gain, failures are discounted by `FailureClass`.
- Periodically `consolidate()` settles repeated experience into memory / belief / concept / procedure, reducing retrieval noise.
- `persist()` at the end of a session, then `recover()` next time for seamless continuation.

For more behavior details, see [`docs/causal-memory-evolution.md`](docs/causal-memory-evolution.md).

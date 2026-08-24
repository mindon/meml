# MEML Usage Guide

This is the operations manual for MEML, covering three integration paths: the **Zig library (`meml`)**, the **command-line bridge (`meml-cli`)**, and **source-language scripts (`.meml`)**.

| Entry point | Artifact | Best for |
|---|---|---|
| Zig library | `src/meml.zig` | Hosts that are themselves Zig, linking directly with zero bridge cost |
| CLI | `zig-out/bin/meml-cli` | Any language (Python / TypeScript / Go …) calling through a subprocess |
| Source language | `*.meml` files | Writing memory policy as editable, versionable, transactionally-executed scripts |

All three share the same `Runtime` kernel: semantics, scoring, ordering, conflict rules, and activation explanations are identical; only the calling shape differs.

---

## 1. Building

Requires Zig 0.17.

```sh
zig build          # installs meml and meml-cli into zig-out/bin/
zig build test     # runs the tests
zig build run      # runs the minimal library example
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

### 2.3 Core API

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
| Beliefs | `setBeliefState(id, state)` / `supersedeBelief(old, replacement)` | Belief lifecycle |
| Abstraction | `generalize(ids, concept) !u64` / `inferProcedure(ids, name) !u64` | Generalize a concept / procedure |
| Retrieval | `activate(context, limit, allocator) !ArrayList(Activation)` | Contextual retrieval |
| | `activateWithStats(context, limit, allocator) !retrieval.Result` | Retrieve and return candidate/scoring statistics |
| Signals | `addSignalProvider(provider)` / `setSignalCalibration(weight, bias)` / `addCalibratedSignalProvider()` | Attach replaceable signals |
| Feedback | `setFeedbackVerifier(verifier)` / `clearFeedbackVerifier()` | Trust boundary |
| | `setFeedbackPolicy(policy)` / `recordFeedback(input) !u64` | Write back outcomes |
| Consolidation | `consolidate()` / `consolidateAll()` / `consolidatePending(policy)` | Explicit consolidation |
| | `consolidateWithPolicy(policy)` / `consolidateAllAtomic(policy)` / `consolidatePendingAtomic(policy)` | Policy-driven / atomic consolidation |
| | `consolidateNeural(consolidator) !usize` | Deterministic neural consolidation |
| | `enableAutoConsolidation(policy)` / `disableAutoConsolidation()` | Event-triggered consolidation |
| Backend | `useVectorBackend()` / `useGraphBackend()` | Switch candidate provider |
| Persistence | `persist(io, path)` / `persistAtomic(io, path)` | Save (atomic write optional) |
| | `persistTo(provider, io, path)` / `persistIfRevision(provider, expected_revision, io, path)` | Custom / CAS |
| | `recover(allocator, io, path) !Runtime` | Restore |

### 2.4 Key types and enums

```zig
pub const Kind = enum { experience, evidence, claim, memory, belief, concept, procedure, context };
pub const RelationKind = enum { supports, contradicts, derived_from, generalizes, follows, causes };
pub const BeliefState = enum { active, contested, superseded, archived };
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

---

## 3. Command-line bridge (`meml-cli`)

`meml-cli` is a JSON-lines bridge: **one JSON request in per line, one JSON response out per line**, with state preserved across requests within the same process.

### 3.1 Three run modes

| Mode | Command | Description |
|---|---|---|
| Single request | `meml-cli '<json>'` | Processes a single request and exits; **fresh state each time** |
| Long-running REPL | `meml-cli` (stdin, line by line) | State persists across requests; ideal for an agent's long-running subprocess |
| File | `meml-cli --file reqs.jsonl` | Batch processing, line by line |

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
| `set_belief_state` | `id,state` | `{ok}` |
| `supersede` | `old,replacement` | `{ok}` |
| `generalize` | `ids,concept` | `{ok,id}` |
| `procedure` | `ids,name` | `{ok,id}` |
| `activate` | `query,goal,user,situation,now,preferred,resolve_conflicts,limit,stats,details` | `{ok,activations}` |
| `feedback` | `target,outcome,failure_class,actor,receipt,timestamp` | `{ok,evidence}` |
| `consolidate` | `repeat_threshold,procedure_success_ratio,enable_memory,…` | `{ok,stats}` |
| `auto_consolidate` | `enable,…` | `{ok}` |
| `signals` | `providers` | `{ok,providers}` |
| `backend` | `backend` | `{ok}` |
| `persist` | `path,atomic` | `{ok}` |
| `recover` | `path` | `{ok}` |
| `exec` | `program` | `{ok,stats}` |
| `set_verifier` | `trusted_actors,receipt_prefix` | `{ok}` |
| `clear_verifier` | — | `{ok}` |
| `set_feedback_policy` | `success_increment,timeout_multiplier,…` | `{ok}` |

Enum values:

- `kind`: `supports | contradicts | derived_from | generalizes | follows | causes`
- `state`: `active | contested | superseded | archived`
- `outcome`: `success | failure`
- `failure_class`: `none | timeout | transport | tool_error | invalid_result | policy_denied | unauthorized | cancelled | unknown`
- `backend`: `vector | graph`
- `providers` (array): `metadata | embedding | reranker | calibrated | neural`

### 3.3 Shell example

```sh
# Long-running mode: state persists across requests
printf '%s\n' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"typescript","context":"frontend","result":"success","timestamp":10}' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"python","context":"backend","result":"success","timestamp":20}' \
  '{"op":"activate","query":"uses","goal":"pick a tool","situation":"frontend","limit":5,"details":true}' \
  '{"op":"set_verifier","trusted_actors":["workbuddy"],"receipt_prefix":"receipt-"}' \
  '{"op":"feedback","target":1,"outcome":"success","failure_class":"none","actor":"workbuddy","receipt":"receipt-1","timestamp":80}' \
  '{"op":"persist","path":"meml.state","atomic":true}' \
| ./zig-out/bin/meml-cli
```

### 3.4 Python long-running process example (agent integration)

```python
import subprocess, json

proc = subprocess.Popen(
    ["zig-out/bin/meml-cli"],
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

> Note: you must call `set_verifier` before `feedback`. Without a verifier it returns `FeedbackVerifierRequired`, an untrusted actor returns `UntrustedActor`, and a receipt-prefix mismatch returns `UntrustedReceipt`.

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
./zig-out/bin/meml-cli '{"op":"exec","program":"observe user prefers typescript frontend success at 10"}'
```

> A script run through `exec` that contains `feedback` requires `set_verifier` first within the same process.

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

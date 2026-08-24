# MEML — An Explainable Memory Runtime for Agents

[中文](README.md)

MEML is a programmable memory runtime for agents. It organizes experiences, evidence, claims, beliefs, concepts, and procedures into a semantic graph, and returns explainable activations given a query, goals, and context.

Semantics and ranking are controlled by a single kernel; indexes, external signals, and deterministic neural reference implementations plug in through replaceable providers. Replacing a candidate-routing strategy therefore never changes memory identity, conflict rules, ranking boundaries, or activation explanations.

## Use Cases

- Retain task experience, preferences, evidence, and their causal relationships for an agent.
- Retrieve history based on the current goal and context rather than keyword matching alone.
- Keep policy outcomes for tool selection, workflow planning, and failure recovery: execution success or failure is written back as evidence and biases later retrieval by source.
- Consolidate repeated experience into traceable long-term memory, beliefs, concepts, and procedures.
- Save, restore, and audit memory state and derivation provenance locally.
- Reproduce retrieval evaluations across different candidate-routing or signal providers.

## Key Benefits

- **Explainable retrieval**: every activation carries a decomposition of semantic, lexical, temporal, graph, procedural, preference, goal, confidence, and conflict signals.
- **Stable kernel boundary**: providers only produce candidate IDs; the kernel owns identity, scoring, ordering, limits, conflict handling, and explanations.
- **Semantic graph and lifecycle**: supports `experience`, `evidence`, `claim`, `memory`, `belief`, `concept`, and `procedure` nodes, plus support, contradiction, derivation, generalization, and step relations. Beliefs can be active, contested, superseded, or archived.
- **Controlled consolidation**: consolidate explicitly in full or incrementally, or enable event-triggered consolidation for later observations; policies control memory, belief, concept, procedure, and neural rules independently.
- **Recoverable state**: `MEML12` saves the graph, derivation provenance, fingerprint indexes, belief lifecycle, deterministic `NeuralState`, versioned signal calibration parameters, and verified feedback receipts. Semantic revisions are bound to index checkpoint journals; recovery only accepts a matching derived-index manifest and rebuilds the indexes.
- **Reproducible verification**: built-in end-to-end, conflict, persistence, rollback, recovery, provider-consistency, and scale-path tests; the benchmark program uses deterministic datasets and reports retrieval-quality metrics.

## Current Architecture

```text
Provider = name + reset + upsert + remove + candidates
                         │
                         ▼
Kernel owns identity, scoring, ordering, limits, conflicts, explanations

Runtime ────────> indexed symbolic backend (default)
                  ├─ exhaustive symbolic backend
                  ├─ vector / graph candidate providers
                  └─ deterministic neural consolidation / retrieval providers
                         │
                         ▼
                  candidate routing → kernel signals → conflict/context policy
                  → ranked, explainable activations
```

`src/backend.zig` defines the provider contract. Indexes and providers are responsible for candidate generation; `src/retrieval.zig`, `src/ranking.zig`, and the runtime together guarantee that activation semantics do not change when providers are swapped.

## Verified Capabilities

- Write experiences with `observe()` and activate relevant memory by query, goal, context, and preference.
- Use indexed, vector, and graph candidate providers; rebuild derived indexes from persisted semantic records after recovery.
- Add metadata, embedding, neural, and versioned calibration retrieval signal providers without changing the kernel scoring contract.
- Derive memory, belief, concept, procedure, and deterministic neural artifacts from repeated experience; derivation records carry rules and sources.
- Run scoped incremental consolidation via `consolidatePending()`, or enable event-triggered consolidation for subsequent `observe()` calls with `enableAutoConsolidation(policy)`. The default `observe()` stays write-only and does not implicitly change derived structure.
- Handle conflicting beliefs by context: mutually exclusive beliefs can be active simultaneously in different contexts; same-context conflicts become contested and affect later activations.
- Roll back complete runtime state on an in-memory failure through the atomic consolidation API: semantic graph, derivation records, neural state, IDs, consolidation cursor, pending groups, indexes, and runtime configuration.
- Record policy outcomes as evidence with `recordFeedback(FeedbackInput)` or the source-language `feedback` after a host `FeedbackVerifier` validates actor and receipt; failures carry a `FailureClass`, unverified outcomes do not change memory, and `FeedbackPolicy` can configure domain success gains and failure discounts.
- Source language provides per-statement structured diagnostics, supports `link` / `unlink` relationship lifecycle operations, and executes whole programs as a transaction.
- `evaluateAgentSuite()` covers multi-task and context drift; `evaluateAnnotated()` accepts human-annotated sets with task IDs and graded relevance, and can enforce Recall/MRR/NDCG quality gates.
- Recover interrupted local atomic writes using a journal and a monotonic revision, and reject stale writers through the local `VersionedProvider` CAS.
- Persist, recover, and retrieve the deterministic `NeuralState`, and versioned weights and biases for `calibrated` providers; these are transparent reference states, not trained model parameters.

See [`docs/causal-memory-evolution.md`](docs/causal-memory-evolution.md) for behavior notes on consolidation, persistence, and boundary conditions.

## Quick Start

Requires Zig 0.17.

```sh
zig fmt build.zig src/*.zig
zig build
zig build test
zig build run
zig build demo
zig build bench -Doptimize=ReleaseFast
```

`zig build run` runs a minimal example: writes two experiences, adds metadata and neural retrieval signals, activates memory for a browser context, and saves `meml.state`. That file is local runtime data, not a versioned repository artifact; deployments that need long-term retention should manage it and restore it via `Runtime.recover()`.

`zig build bench -Doptimize=ReleaseFast` reports write throughput, query latency, routed candidate count, scored count, returned count, Recall@20, MRR, and NDCG over 10K, 100K, and 1M deterministic experiences. The 10M scale must be enabled by the caller according to available machine resources; the repository ships no fixed performance conclusions.

### Embedding the Runtime

The public entry point is `src/meml.zig`; the core API lives on `Runtime`:

1. Create a runtime with `Runtime.init(allocator)` and write semantic records via `observe()` or the explicit construction APIs.
2. Retrieve by `Context` with `activate()` or `activateWithStats()`, and read the returned activation signals and statistics.
3. Configure a host verifier with `setFeedbackVerifier()` first; then call `setFeedbackPolicy()` if domain rules exist. After an agent acts on a retrieval result, call `recordFeedback(.{ .target = id, .outcome = .success, .failure_class = .none, .actor = ..., .receipt = ..., .timestamp = ... })`; in the source language, use `feedback <label> success|failure <failure_class> actor <actor> receipt <receipt> at <timestamp>`, and `unlink <from> <relation> <to>` to remove an explicit relation.
4. In CI, use `evaluateAnnotated()` to load human-annotated task–context–relevance cases and constrain Recall/MRR/NDCG with a `QualityGate`; when long-term structure is needed, call `consolidateAll()`, `consolidatePending(policy)`, or `enableAutoConsolidation(policy)` for later observations.
5. Save with `persist()`; it performs a semantic journal plus a revision-bound index checkpoint by default. Restore with `Runtime.recover()`.

[`examples/contextual_retrieval.meml`](examples/contextual_retrieval.meml) is an executable, restricted source-language example. `source.execute()` parses and statically validates contexts, parameter ranges, and provider names first, then executes the whole program as a runtime transaction; on failure it restores nodes, relations, derivation records, indexes, and the signal pipeline.

[`examples/demo.meml`](examples/demo.meml) is an end-to-end demo script covering the full lifecycle of "observe → declare → contextual retrieval → feedback write-back → relation conflict → consolidation → neural consolidation"; `zig build demo` reads it and prints the activation ranking and signal decomposition at each step, then persists and recovers into a fresh runtime to verify recoverability.

## Current Limitations

- The source language is a restricted domain command set with explicit relation creation and deletion; it has no loops, functions, user variables, or cross-program references, and is deliberately not a general-purpose scripting engine.
- `FeedbackVerifier` is a host boundary: MEML does not verify external identity, signatures, or tool receipts itself. Callers must supply a verifier that is authorized, authenticated, and result-checked; receipts should avoid sensitive data that must not be persisted.
- Built-in embedding and neural providers remain deterministic reference implementations. `calibrated` only persists transparent weights and biases; trained embeddings, model weights, and binary checkpoints are not yet persisted.
- The index checkpoint journal only saves the semantic revision and node manifest to reject stale derived caches; recovery still rebuilds token/vector indexes and does not yet persist the full index structure.
- `persist()` defaults to local journal atomic writes. Remote CAS is integrated through the host-provided `storage.Remote.Transport`; authentication, TLS, endpoint allowlists, directory-metadata fsync, and lock cooperation that bypasses the API are outside the current guarantees.
- Automatic consolidation is opt-in; the default observation path stays retrieval-only to avoid implicitly changing existing callers' memory structures.

## Roadmap

1. Per-statement line-level structured diagnostics, labels, `link` / `unlink`, and trusted `feedback` are provided and execute as a whole-program transaction; the next step is token-level column numbers and cross-program symbol resolution only if editor integration is needed.
2. `FeedbackVerifier`, failure classification, receipt auditing, and configurable `FeedbackPolicy` are implemented; the next step is for concrete tool hosts to add signature, claim, expiry, nonce, and target-binding checks, keeping keys only in the deployment environment.
3. "retrieval policy → trusted feedback → evidence provenance → persistence → restart recovery → re-retrieval" is covered, with multi-task, context-drift, and human-annotation evaluation interfaces; the next step is to settle real annotation sets and CI baselines rather than extending built-in examples.
4. The index checkpoint journal is bound to the semantic revision and node manifest; full token/vector index shard persistence and incremental replay performance are still missing and should be validated against benchmark data first.
5. Default candidate routing is unified with tokenization and case normalization, and index providers must be created from managed `Owned` instances; domain-calibrated learned embeddings, reranking, and neural providers are not yet implemented and should first be validated against human-annotation sets.
6. Versioned signal weights and biases are persisted, with Recall/MRR/NDCG quality gates; embedding and model checkpoint persistence is not yet implemented, and the next step is an artifact manifest with provider, model version, and checksum before introducing controlled blob storage.
7. Local CAS and the host `storage.Remote.Transport` adapter are implemented; production remote storage and cross-process failure-recovery drills are not yet implemented, and should be provided by the host with TLS, authentication, allowlists, idempotent CAS, and independent process failure-injection tests.

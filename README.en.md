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
- Import multiple restricted `.meml` semantic documents in one atomic transaction instead of merging state snapshots.
- Reproduce retrieval evaluations across different candidate-routing or signal providers.

## Key Benefits

- **Explainable retrieval**: every activation carries semantic, lexical, temporal, graph, procedural, preference, goal, confidence, scope, metric, structure, lineage, stability, and conflict contributions plus raw score and weight for each external provider; graph propagation is bounded by the kernel and cognitive state.
- **Information-evolution ledger (IEL)**: the Zig-library façade `meml.iel.Evolution` attaches information kind, trust, retention, source, observed time, and validity interval to semantic nodes; it appends immutable evolution events and preserves decision dependencies for audit.
- **Stable kernel boundary**: providers only produce candidate IDs; the kernel owns identity, scoring, ordering, limits, conflict handling, and explanations.
- **Dynamic cognitive state**: every cognitive record can be active, contested, superseded, or archived. Host-verified bounded transitions persist an immutable audit trail and change future activation conditions; configurable `PlasticityPolicy`, derived stability/attractor state, cutoff-based procedure forecasts, explicit-candidate quality gates, and conservative multi-objective comparisons remain explainable.
- **Controlled consolidation**: consolidate explicitly in full or incrementally, or enable event-triggered consolidation for later observations; policies control memory, belief, concept, procedure, and neural rules independently.
- **Recoverable state**: the only supported `MEML15` format saves the graph, structured scopes/metrics/artifacts/structure identity, general cognitive lifecycle, immutable transition audit, IEL information metadata/evolution events/decision dependencies, derivation provenance, deterministic `NeuralState`, versioned signal calibration parameters, verified feedback receipts, and consumed signed-attestation digests. Old formats are explicitly rejected; recovery rebuilds derived indexes from the semantic revision and can verify IEL materialized-view consistency.
- **Reproducible verification**: built-in end-to-end, conflict, persistence, rollback, recovery, provider-consistency, and scale-path tests; the benchmark program uses deterministic datasets and reports retrieval-quality metrics.

## Current Architecture

```text
Provider = name + reset + upsert + remove + candidates
                         │
                         ▼
Kernel owns identity, scoring, ordering, limits, conflicts, explanations

Runtime ────────> indexed symbolic backend (default)
                  ├─ exhaustive symbolic backend
                  ├─ vector / graph / hybrid candidate providers
                  └─ deterministic neural and local embedding reranking providers
                         │
                         ▼
                  candidate routing → kernel signals → conflict/context policy
                  → ranked, explainable activations
```

`src/backend.zig` defines the provider contract. Indexes and providers are responsible for candidate generation; `src/retrieval.zig`, `src/ranking.zig`, and the runtime together guarantee that activation semantics do not change when providers are swapped.

## Verified Capabilities

- Write lightweight experiences with `observe()`, or scopes, metrics, artifacts, and structure with `record(RecordInput)`; activate relevant memory by query, goal, context, structured scope, and fingerprint.
- Use a shared, versioned ASCII tokenizer for indexes, candidate routing, lexical ranking, and deterministic hash embeddings; rebuild derived indexes from persisted semantic records after recovery.
- Use indexed, vector, graph, and `hybrid` candidate providers; `backend.LocalSemantic` attaches a host-local ANN source and `backend.Hybrid` creates its deduplicated union with lexical candidates. Providers only return IDs and cannot bypass kernel filtering or ranking.
- Add metadata, embedding, neural, versioned calibration, and host-local cached embedding retrieval providers with explicit weights and activation traces, without changing the kernel scoring contract.
- Derive memory, belief, concept, procedure, and deterministic neural artifacts from repeated experience; derivation records carry rules and sources.
- Run scoped incremental consolidation via `consolidatePending()`, or enable event-triggered consolidation for subsequent `observe()` calls with `enableAutoConsolidation(policy)`. `observe()` is append-only: identical observations remain distinct provenance-bearing experiences unless the caller chooses a higher-level deduplication policy.
- Handle explicit contradictory evidence by context: consolidation carries it into derived beliefs, marks them contested, and penalizes confidence. Different values alone never fabricate a contradiction relation; alternatives can remain active in different contexts.
- Roll back complete runtime state on an in-memory failure through the atomic consolidation API: semantic graph, derivation records, neural state, IDs, consolidation cursor, pending groups, indexes, and runtime configuration.
- Record policy outcomes as evidence with `recordFeedback(FeedbackInput)` or source-language `feedback` by default. Installing a host `FeedbackVerifier` or Ed25519 `FeedbackAttestationPolicy` explicitly requires its proof before feedback writes; use a separate `TransitionVerifier` with bounded `transition()` or DSL `transition` for auditable state changes. Neither boundary directly executes a host Action.
- Source language provides per-statement structured diagnostics, supports `link` / `unlink` relationship lifecycle operations, and executes whole programs as a transaction.
- `evaluateAgentSuite()` covers multi-task and context drift; `evaluateAnnotated()` accepts human-annotated sets with task IDs and graded relevance, and can enforce Recall/MRR/NDCG quality gates.
- Recover interrupted local atomic writes using a journal and a monotonic revision, and reject stale writers through the local `VersionedProvider` CAS.
- Persist, recover, and retrieve the deterministic `NeuralState`, and versioned weights and biases for `calibrated` providers; these are transparent reference states, not trained model parameters.
- Use the Zig-library `meml.iel.Evolution` to record observations, declarations, derivations, corroboration, contradictions, supersession, archival/revocation, decision dependencies, and host-verified feedback. `verificationCandidates()` only ranks review work; it never verifies sources, calls tools, or executes Actions.

See [`docs/causal-memory-evolution.md`](docs/causal-memory-evolution.md) for behavior notes on consolidation, persistence, and boundary conditions. [`docs/information-evolution.md`](docs/information-evolution.md) documents the IEL model, ledger, decision loop, and non-event-sourcing boundary. [`docs/domain-memory.md`](docs/domain-memory.md) describes the shared structured model, adapter boundary, and JSON-lines examples for quantum, AI for Science, and ordinary agents. [`docs/dynamic-memory.md`](docs/dynamic-memory.md) describes cognitive state, bounded transitions, auditable replay, and state-aware activation.

## Quick Start

Requires Zig 0.17.

The full operations guide for the library (`meml`), the CLI (`meml`), and source-language scripts (`.meml`) is in [`USAGE.en.md`](USAGE.en.md).

```sh
zig fmt build.zig src/*.zig
zig build
zig build test
zig build example
zig build demo
zig build bench -Doptimize=ReleaseFast
```

`zig build example` runs a minimal example: writes two experiences, adds metadata and neural retrieval signals, activates memory for a browser context, and saves `meml.state`. That file is local runtime data, not a versioned repository artifact; deployments that need long-term retention should manage it and restore it via `Runtime.recover()`.

`zig build bench -Doptimize=ReleaseFast` reports write throughput, query latency, routed candidate count, scored count, returned count, Recall@20, MRR, and NDCG over 10K, 100K, and 1M deterministic experiences. The 10M scale must be enabled by the caller according to available machine resources; the repository ships no fixed performance conclusions.

### Embedding the Runtime

The public entry point is `src/meml.zig`; the core API lives on `Runtime`:

1. Create a runtime with `Runtime.init(allocator)` and write semantic records via `observe()` or the explicit construction APIs.
2. Retrieve by `Context` with `activate()` or `activateWithStats()`, and read the returned activation signals and statistics.
3. Configure `setFeedbackVerifier()` or `setFeedbackAttestationPolicy()` only when feedback must require host proof; otherwise feedback uses the default writable mode. Then call `setPlasticityPolicy()` if domain plasticity rules exist. After an agent acts on a retrieval result, call `recordFeedback(.{ .target = id, .outcome = .success, .failure_class = .none, .actor = ..., .receipt = ..., .timestamp = ... })`; in the source language, use `feedback <label> success|failure <failure_class> actor <actor> receipt <receipt> at <timestamp>`, and `unlink <from> <relation> <to>` to remove an explicit relation.
4. In CI, use `evaluateAnnotated()` to load human-annotated task–context–relevance cases and constrain Recall/MRR/NDCG with a `QualityGate`; when long-term structure is needed, call `consolidateAll()`, `consolidatePending(policy)`, or `enableAutoConsolidation(policy)` for later observations.
5. Save with `persist()`; it performs a semantic journal plus a revision-bound index checkpoint by default. Restore with `Runtime.recover()`.

[`examples/contextual_retrieval.meml`](examples/contextual_retrieval.meml) is an executable, restricted source-language example. `source.execute()` parses and statically validates contexts, parameter ranges, and provider names first, then executes the whole program as a runtime transaction; on failure it restores nodes, relations, derivation records, indexes, and the signal pipeline.

[`examples/demo.meml`](examples/demo.meml) is an end-to-end demo script covering the full lifecycle of "observe → declare → contextual retrieval → feedback write-back → relation conflict → consolidation → neural consolidation"; `zig build demo` reads it and prints the activation ranking and signal decomposition at each step, then persists and recovers into a fresh runtime to verify recoverability.

## Current Limitations

- The source language is a restricted domain command set with explicit relation creation and deletion; it has no loops, functions, user variables, or cross-program references, and is deliberately not a general-purpose scripting engine.
- `FeedbackVerifier` and `FeedbackAttestationPolicy` are optional hardening boundaries: feedback is writable when neither is installed, while an installed policy requires its proof. Hosts remain responsible for identity, authorization, private keys, and result checks; receipts should avoid sensitive data that must not be persisted.
- Built-in embedding and neural providers remain deterministic reference implementations. `ArtifactManifest` records provider, model version, SHA-256 checksum, byte length, and an opaque host-managed locator; it never loads blobs. Trained embeddings, model weights, and binary checkpoints are not persisted by MEML.
- The index checkpoint journal only saves the semantic revision and node manifest to reject stale derived caches; recovery still rebuilds token/vector indexes and does not yet persist the full index structure.
- `persist()` defaults to local journal atomic writes. Host-provided `storage.Remote.Transport` now supports revision CAS plus semantic snapshot recovery via `Runtime.recoverFrom()`; remote snapshots are revalidated and rebuild derived indexes locally. Authentication, TLS, endpoint allowlists, namespace authorization, idempotent retry, directory-metadata fsync, and lock cooperation that bypasses the API remain host responsibilities.
- Automatic consolidation is opt-in; the default observation path stays retrieval-only to avoid implicitly changing existing callers' memory structures.
- IEL is currently exposed only through the Zig-library `meml.iel.Evolution`; the `.meml` DSL and JSON-lines CLI have no IEL-specific statements or operations. It persists immutable evolution events beside a current materialized view, not a general event-sourcing runtime rebuilt from a complete event stream.

## Roadmap

1. Per-statement line-level structured diagnostics, labels, `link` / `unlink`, and trusted `feedback` are provided and execute as a whole-program transaction; the next step is token-level column numbers and cross-program symbol resolution only if editor integration is needed.
2. Feedback is writable by default; optional `FeedbackVerifier` or Ed25519 attestation policies enforce proof when configured. Failure classification, receipt auditing, configurable `PlasticityPolicy`, derived stability, bounded propagation, and Ed25519 claim/expiry/nonce/target binding are implemented. Concrete tool hosts must keep private keys and authorization/result checks in the deployment environment.
3. "retrieval policy → trusted feedback → evidence provenance → persistence → restart recovery → re-retrieval" is covered with the frozen `retrieval-v1` seed, human labels, a machine-readable `zig build eval` report, and CI baseline gate. The next step is to expand the independently reviewed held-out annotation set rather than extending built-in examples.
4. The index checkpoint journal is bound to the semantic revision and node manifest. `zig build bench` now reports persist and cold-recovery latency alongside retrieval quality; full token/vector shard persistence remains deferred until those deployment measurements prove semantic-index rebuild is the bottleneck.
5. Default candidate routing is unified with tokenization and case normalization, and index providers must be created from managed `Owned` instances; domain-calibrated learned embeddings, reranking, and neural providers are not yet implemented and should first be validated against human-annotation sets.
6. Versioned signal weights and biases are persisted, with Recall/MRR/NDCG quality gates. `ArtifactManifest` now records provider, model version, checksum, byte length, and opaque locator without dereferencing blobs; controlled host blob storage and learned providers remain pending held-out evaluation.
7. Local CAS and host `storage.Remote.Transport` recovery are implemented. The runtime suite drills stale conflicts, a commit that succeeds before its response times out, and unavailable recovery; callers reconcile ambiguity by loading the authoritative revision rather than blind retry. Production remote storage and cross-process failure-recovery drills remain host work, requiring TLS, authentication, namespace authorization, allowlists, idempotent CAS, and independent process failure
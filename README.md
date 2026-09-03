# MEML — 可解释的 Agent 记忆运行时

[English](README.en.md)

MEML 是一个面向 Agent 的可编程记忆运行时。它将经验、证据、主张、信念、概念和过程组织为语义图，并在给定查询、目标和情境时返回可解释的激活结果。

语义与排序由内核统一控制；索引、外部信号和确定性神经参考实现通过可替换的 provider 接入。因此，替换候选路由策略不会改变记忆身份、冲突规则、排序边界或激活解释。

## 适用场景

- 为 Agent 保留任务经验、偏好、证据及其因果关系。
- 根据当前目标和情境检索历史，而不是只做关键词匹配。
- 为工具选择、工作流规划和故障恢复保留策略结果：执行成功或失败会回写为 evidence，并带来源调整后续检索。
- 将重复经验整理为可追溯的长期记忆、信念、概念和过程。
- 在本地保存、恢复和审计记忆状态与推导来源。
- 将多份受限 `.meml` 语义文档作为一次原子事务导入，而非合并状态快照。
- 对不同候选路由或信号 provider 做可复现的检索评估。

## 核心优势

- **可解释检索**：每项激活都携带语义、词法、时间、图关系、过程、偏好、目标、置信度、作用域、指标、结构、谱系和冲突等信号分解，并附带每个外部 provider 的原始分数与权重。
- **通用结构化证据**：记录可携带版本化范围、带单位和不确定性的指标、内容寻址制品与结构指纹；`derived_from` 统一表达可追溯谱系。
- **信息演化账本（IEL）**：Zig 库门面 `meml.iel.Evolution` 为语义节点附加信息类别、信任、保留、来源、观测时间与有效区间；它追加不可变演化事件，并保存决策依赖以供审计。
- **稳定的内核边界**：provider 仅产生候选 ID；领域 adapter 仅规范化输入与信号；内核负责身份、评分、顺序、数量限制、矛盾处理和解释。
- **动态认知状态**：所有认知记录可处于 active、contested、superseded 或 archived 状态；经宿主验证的有限 transition 会留下包含前后状态、来源和证明的不可变审计记录，并改变未来激活条件。可配置 `PlasticityPolicy`、派生稳定性/吸引子指标、截止时间过程预测、显式候选质量门和多目标保守比较均保持可解释。
- **可控整合**：可显式全量或增量整合，也可为后续观察开启事件触发整合；策略可分别控制 memory、belief、concept、procedure 和 neural 规则。
- **可恢复状态**：唯一支持的 `MEML15` 保存图、结构化范围/指标/制品/结构身份、通用认知生命周期、不可变状态转移审计、IEL 信息元数据/演化事件/决策依赖、推导来源、确定性 `NeuralState`、版本化 signal 校准参数和已验证反馈回执及已消费签名证明摘要。旧格式明确拒绝；语义 revision 与索引 checkpoint journal 绑定，恢复时重建派生索引并可验证 IEL 物化视图一致性。
- **可复现验证**：内置端到端、冲突、持久化、回滚、恢复、provider 一致性和规模路径测试；基准程序使用确定性数据集并输出检索质量指标。

## 当前架构

```text
Provider = name + reset + upsert + remove + candidates
                         │
                         ▼
Kernel owns identity, scoring, ordering, limits, conflicts, explanations

Runtime ────────> indexed symbolic backend (default)
                  ├─ exhaustive symbolic backend
                  ├─ vector / graph / hybrid candidate providers
                  └─ deterministic neural, local embedding reranking providers
                         │
                         ▼
                  candidate routing → kernel signals → conflict/context policy
                  → ranked, explainable activations
```

`src/backend.zig` 定义 provider 合约。索引和 provider 负责候选生成；`src/retrieval.zig`、`src/ranking.zig` 与运行时共同保证激活语义不随 provider 替换而改变。

## 已验证能力

- 使用 `observe()` 写入轻量经验，或以 `record(RecordInput)` 写入范围、指标、制品和结构；按查询、目标、情境、结构化范围与指纹激活相关记忆。
- 使用共享、版本化的 ASCII tokenizer 进行索引、候选路由、词法排序和确定性 hash embedding；恢复后从持久化语义记录重建派生索引。
- 使用索引、向量、图和 `hybrid` 候选 provider；`backend.LocalSemantic` 可接入宿主本地 ANN，并通过 `backend.Hybrid` 与 lexical 候选去重并集。provider 仅返回 ID，不能绕过内核过滤与排序。
- 添加元数据、嵌入、神经、版本化校准及宿主本地缓存 embedding 检索信号 provider；外部 provider 有显式权重并在 activation trace 中解释，而不改变内核评分合约。
- 从重复经验派生 memory、belief、concept、procedure 和确定性 neural artifact；推导记录携带规则与来源。
- 通过 `consolidatePending()` 执行作用域增量整合，或通过 `enableAutoConsolidation(policy)` 为后续 `observe()` 启用事件触发整合。`observe()` 是 append-only：相同观察仍作为携带独立来源的经验保留；如需去重，应由调用方选择更高层策略。
- 按情境处理显式反驳证据：整合会将其携带到派生 belief，使其进入 contested 并降低置信度。不同值本身不会虚构 contradiction 关系；备选项可在不同情境中同时 active。
- 以原子整合 API 在内存失败时回滚完整运行时状态：语义图、推导记录、神经状态、ID、整合游标、待处理组、索引和运行时配置。
- 通过兼容宿主 `FeedbackVerifier` 或 Ed25519 `FeedbackAttestationPolicy` 验证 actor 与 receipt 后，使用 `recordFeedback(FeedbackInput)` 将策略结果记录为 evidence；签名证明绑定目标语义、时效和 nonce，并在恢复后保持防重放。通过独立 `TransitionVerifier` 使用受限 `transition()` 或 DSL `transition` 提交可审计状态变化。两者均不直接执行宿主 Action。
- 源语言对每条语句提供行级结构化诊断，支持 `link` / `unlink` 关系生命周期操作，并在整份程序事务中执行。
- `evaluateAgentSuite()` 覆盖多任务与上下文漂移；`evaluateAnnotatedTasks()` 支持多标签分级相关性，`zig build eval` 执行冻结的 `retrieval-v1` 数据集与 Recall/MRR/NDCG CI 基线。
- 使用 journal 与单调 revision 恢复中断的本地原子写入，并通过本地 `VersionedProvider` CAS 拒绝陈旧写者竞争。
- 持久化、恢复并用于检索的确定性 `NeuralState`，以及 `calibrated` provider 的版本化权重与偏置；它们是透明参考状态，不是训练模型参数。
- 通过 Zig 库 `meml.iel.Evolution` 记录观察、声明、推导、佐证、矛盾、替代、归档/撤销、决策依赖与经宿主验证的反馈；`verificationCandidates()` 仅排序待复核项，不验证来源、调用工具或执行 Action。

有关整合、持久化和边界条件的行为说明见 [`docs/causal-memory-evolution.md`](docs/causal-memory-evolution.md)。IEL 的信息模型、账本、决策闭环与非纯事件溯源边界见 [`docs/information-evolution.md`](docs/information-evolution.md)。量子、AI for Science 和普通 Agent 共用的结构化模型、adapter 边界与 JSON-lines 示例见 [`docs/domain-memory.md`](docs/domain-memory.md)。动态认知状态、受限 transition、可审计回放和 state-aware activation 见 [`docs/dynamic-memory.md`](docs/dynamic-memory.md)。

## 快速使用

需要 Zig 0.17。

库（`meml`）、命令行（`meml`）与源语言脚本（`.meml`）的完整操作手册见 [`USAGE.md`](USAGE.md)。

### Agent 插件与 Skill

[`integrations/`](integrations/README.md) 提供 Pi Agent、DeepSeek Harness、WorkBuddy、CodeBuddy、Codex 与 Claude Code 的本地集成：每个集成注册只读 `meml_recall`，并提供 `meml-agent-memory` Skill。执行结果只能由宿主的已验证工具生命周期回写，模型不能自报反馈。

推送 `vMAJOR.MINOR.PATCH` 标签会触发 GitHub Actions，发布 Linux（x86_64 / aarch64）、macOS（x86_64 / aarch64）和 Windows（x86_64）的 `meml` 压缩包及 `SHA256SUMS`。也可通过 Actions 的 `workflow_dispatch` 手动指定版本标签。

```sh
zig fmt build.zig src/*.zig
zig build
zig build test
zig build example
zig build demo
zig build bench -Doptimize=ReleaseFast
```

`zig build example` 运行最小示例：写入两条经验，添加元数据和神经检索信号，按浏览器情境激活记忆，并保存 `meml.state`。该文件是本地运行数据，不是仓库中的版本演进工件；需要长期保存时应由部署环境管理，并通过 `Runtime.recover()` 恢复。

`zig build bench -Doptimize=ReleaseFast` 会在 10K、100K 和 1M 条确定性经验上报告写入吞吐、查询耗时、路由候选数、评分数、返回数、Recall@20、MRR 与 NDCG。10M 规模需由调用方根据机器资源自行启用；仓库不附带固定性能结论。

### 嵌入运行时

公共入口位于 `src/meml.zig`，核心 API 位于 `Runtime`：

1. 用 `Runtime.init(allocator)` 创建运行时，并通过 `observe()` 或显式构造 API 写入语义记录。
2. 使用 `activate()` 或 `activateWithStats()` 按 `Context` 检索，并读取返回的激活信号和统计信息。
3. 如需强制宿主证明，先通过 `setFeedbackVerifier()` 或 `setFeedbackAttestationPolicy()` 配置策略；否则反馈按缺省可写模式记录。如有领域可塑性规则，再调用 `setPlasticityPolicy()`。Agent 执行检索结果后，调用 `recordFeedback(.{ .target = id, .outcome = .success, .failure_class = .none, .actor = ..., .receipt = ..., .timestamp = ... })`；源语言使用 `feedback <label> success|failure <failure_class> actor <actor> receipt <receipt> at <timestamp>`，并可使用 `unlink <from> <relation> <to>` 解除显式关系。
4. 在 CI 中使用 `evaluateAnnotated()` 加载人工标注的任务—上下文—相关性案例，并以 `QualityGate` 约束 Recall/MRR/NDCG；需要形成长期结构时，调用 `consolidateAll()`、`consolidatePending(policy)`，或为后续观察调用 `enableAutoConsolidation(policy)`。
5. 使用 `persist()` 保存；它默认执行语义 journal 与 revision 绑定的索引 checkpoint。以 `Runtime.recover()` 恢复。

[`examples/contextual_retrieval.meml`](examples/contextual_retrieval.meml) 是可执行的受限源语言示例。`source.execute()` 会先解析并静态校验上下文、参数范围和 provider 名称，再将整份程序作为运行时事务执行；失败时恢复节点、关系、推导记录、索引和 signal pipeline。

[`examples/demo.meml`](examples/demo.meml) 是一份端到端演示脚本，覆盖「观察 → 声明 → 上下文检索 → 反馈回写 → 关系冲突 → 整合 → 神经整合」的完整生命周期；`zig build demo` 会读取它并打印每一步的激活排名与信号分解，随后持久化并恢复到全新运行时以验证可恢复性。

## 当前限制

- 源语言是受限的领域命令集，已支持显式关系创建与删除；尚无循环、函数、用户变量及跨程序引用语法，它刻意不是通用脚本引擎。
- `FeedbackVerifier` 与 `FeedbackAttestationPolicy` 都是可选的显式收紧策略：未安装时反馈可写，安装后 MEML 才强制相应证明。Ed25519 策略会绑定签名声明与目标语义、校验签发/过期时间，并仅持久化已消费载荷摘要以防重放。工具宿主仍负责身份、授权、私钥与结果校验；回执内容应避免放入不应持久化的敏感数据。
- 内置 embedding 与 neural provider 仍是确定性参考实现。`ArtifactManifest` 可记录 provider、模型版本、SHA-256、字节数和不透明的宿主 locator，但绝不加载 blob；训练 embedding、模型权重与二进制 checkpoint 不由 MEML 持久化。
- 索引 checkpoint journal 仅保存语义 revision 与节点清单，用于拒绝陈旧派生缓存；恢复仍重建 token/vector 索引，尚未持久化完整索引结构。
- `persist()` 默认使用本地 journal 原子写入。宿主 `storage.Remote.Transport` 现支持 revision CAS 与通过 `Runtime.recoverFrom()` 的语义快照恢复；远端快照会重新校验并在本地重建派生索引。认证、TLS、端点 allowlist、命名空间授权、幂等重试、目录元数据 fsync 以及绕过 API 的锁协作仍由宿主负责。
- 自动整合是 opt-in；默认观察路径保持 retrieval-only，以避免隐式改变既有调用方的记忆结构。
- IEL 当前只通过 Zig 库 `meml.iel.Evolution` 暴露，`.meml` DSL 与 JSON-lines CLI 尚无 IEL 专用语句或操作。它持久化不可变演化事件和当前物化视图，但不是从完整事件流重建运行时的通用事件溯源系统。

## 后续路线

1. 已提供逐语句行级结构化诊断、标签、`link` / `unlink` 和可信 `feedback`，并以整份程序事务执行；下一步仅在需要编辑器集成时提供 token 级列号与跨程序符号解析。
2. 反馈缺省可写；可选 `FeedbackVerifier` 或 Ed25519 策略会在配置后强制证明。已实现失败分类、回执审计、可配置 `PlasticityPolicy`、派生稳定性、受限传播，以及 Ed25519 的声明、时效、nonce 与目标绑定校验；工具宿主必须仍将私钥、授权与结果校验保留在部署环境。
3. 已覆盖“检索策略 → 可信反馈 → evidence 来源 → 持久化 → 重启恢复 → 再检索”，并提供多任务、上下文漂移、版本化人工标注和 `retrieval-v1` CI 基线；下一步扩充独立审阅的 held-out 标注集，而非继续扩展内置示例。
4. 索引 checkpoint journal 已绑定语义 revision 和节点清单；恢复会丢弃损坏、旧 revision 或节点清单不匹配的 sidecar，并从语义状态重建派生索引；若中断 journal 损坏，已原子提交且匹配的旧 checkpoint 仍可使用。`zig build bench` 现会输出持久化与冷恢复时延以及检索质量，完整 token/vector 索引分片仍须在这些部署测量证明语义索引重建是瓶颈后再引入。
5. 默认候选路由已统一 token 化与大小写规范化，且索引 provider 必须由托管 `Owned` 实例创建；领域校准的学习型 embedding、reranking 和 neural provider 尚未实现，应先以人工标注集验证候选/外部评分契约。
6. 已持久化版本化 signal 权重与偏置，并提供 Recall/MRR/NDCG 质量门槛；`ArtifactManifest` 已定义 provider、模型版本、checksum、字节数和不透明 locator，且不解引用 blob；受控宿主 blob storage 与学习型 provider 仍须先通过 held-out 评测。
7. 已实现本地 CAS 与宿主 `storage.Remote.Transport` 的远端恢复；生产远程存储和跨进程故障恢复演练仍须由宿主提供 TLS、认证、命名空间授权、allowlist、幂等 CAS 和独立进程故障注入测试。

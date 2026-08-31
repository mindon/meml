# 信息演化语言（IEL）

IEL（Information Evolution Language）是构建在 MEML 语义内核之上的 **Zig 库门面**：`meml.iel.Evolution`。它将重点从“保存和检索记忆”扩展为“信息如何被观察、声明、推导、佐证、矛盾、替代、归档、撤销，并影响宿主决策”。

IEL 不替代 `Runtime`、候选 provider、排序内核或宿主规划器；它复用这些边界并增加可审计的信息生命周期语义。

## 信息模型

每条 IEL 信息都关联一个既有语义节点，并持有以下通用元数据：

- `InformationKind`：`fact`、`claim`、`observation`、`hypothesis`、`policy`、`preference`、`decision` 或 `procedure`；
- `Trust`：`unverified`、`asserted`、`corroborated`、`verified` 或 `revoked`；
- `Retention`：`ephemeral`、`session`、`working`、`long_term` 或 `archived`；
- `source`：来源标识；
- `observed_at`：系统获得该信息的时间；
- `valid_from` / `valid_until`：该信息在被建模世界中的有效区间。

这是领域无关模型：内核不解释服务、实验、用户、量子比特或任何其他实体。适配器仍只负责将领域输入规范化为通用记录。

## 演化与谱系

`Evolution` 提供如下受约束操作：

- `observe()`、`declare()`：写入观察或声明，并同时登记信息元数据和事件；
- `derive()`：写入派生信息，并以 `derived_from` 记录来源；
- `corroborate()`、`contradict()`：保留支持或矛盾证据，不静默覆盖原信息；
- `supersede()`：以 `supersedes` 关系记录替代，并通过已有的 `TransitionVerifier` 将旧节点转为 `superseded`；
- `changeLifecycle()`：归档、撤销或到期相关的状态变化仍经受限 transition 边界；撤销会将信任物化视图设为 `revoked`，归档会将保留策略设为 `archived`。

每次操作都会追加单调 `EvolutionEvent`。事件包含操作类别、目标、可选关联节点、时间、来源与原因；当前 `Trust` / `Retention` 与语义图则是供检索和审计使用的物化视图。

## 决策与反馈闭环

`recordDecision()` 创建 `InformationKind.decision` 记录，并保存它依赖的每一条信息。这个 API 只回答“该决策依赖什么”，**不会选择、授权或执行**宿主 Action。

`recordFeedback()` 复用 `Runtime.recordFeedback()` 的验证边界：若部署配置了 `FeedbackVerifier` 或 `FeedbackAttestationPolicy`，宿主证明必须先通过；随后 IEL 才追加 evidence 和 `EvolutionKind.feedback` 事件。IEL 不接受模型自报的执行结果，也不保存私钥或凭据。

## 主动复核建议

`verificationCandidates(now, allocator)` 是只读排序接口。它从以下可解释信号生成待复核项：

1. 未验证或仅声明的来源；
2. 尚未解决的矛盾；
3. 已过期的有效区间；
4. 低置信度。

该接口不会验证来源、调用工具、发送网络请求或执行 Action。宿主决定是否、如何以及是否有权限开展验证。

## 持久化与恢复

`MEML15` 快照保存 IEL 信息元数据、演化事件和决策依赖，并继续使用既有原子 journal、revision 和索引 checkpoint 机制。恢复后可调用 `verifyMaterializedView()`，校验事件引用、信息元数据、替代关系和决策依赖是否与当前物化视图一致。

IEL 目前是“**不可变演化事件 + 持久化物化视图**”模型：

- 事件不可变，便于审计；
- 恢复加载的是经过严格校验的 `MEML15` 快照；
- 它**不是**通过完整事件流重建全部运行时状态的通用 Event Sourcing 系统；
- 它不证明未被记录的外部历史，也不替代宿主日志、认证或授权系统。

## 接入范围

IEL 当前只通过 Zig 库 `meml.iel.Evolution` 暴露。`.meml` DSL 与 JSON-lines CLI 没有 IEL 专用语句或操作；二者不能被描述为 IEL 脚本语言。

完整示例和 API 片段见 [`USAGE.md`](../USAGE.md) 与 [`USAGE.en.md`](../USAGE.en.md)。

# Dynamic Memory Kernel

MEML 的记忆不是单纯的已存储内容，而是可验证经验造成的、会影响未来激活条件的持久结构变化。

```text
Experience / verified Outcome
  → bounded Transition
  → CognitiveState
  → state-aware Activation
  → host planner and action
  → verified Outcome
```

MEML 不决定宿主的行动、不执行工具，也不建立通用脚本执行环境。宿主 Agent 仍拥有规划、授权与行动；MEML 只保存和解释为何未来激活条件已经变化。

## 受限状态转移

`Runtime.transition(TransitionInput)` 是唯一的动态写入入口。它要求宿主先设置 `TransitionVerifier`，验证 actor 与 receipt 后才在事务中提交。

允许的内核操作只有：

- `set_state`：设置 `active`、`contested`、`superseded` 或 `archived`；
- `reinforce`：增加 confidence 与 strength；
- `penalize` / `decay`：按有界比例降低 confidence 与 strength；
- `stabilize`：回到 `active` 并增强 strength。

每次提交生成不可变 `TransitionRecord`，包含前后状态、cause、reason、actor、receipt、时间和单调审计 ID。`verifyTransitionHistory()` 验证每个目标的转移链连续性；`MEML15` 会完整持久化这些记录。旧状态格式明确返回 `UnsupportedVersion`。

```zig
runtime.setTransitionVerifier(host_verifier);
_ = try runtime.transition(.{
    .target = strategy_id,
    .kind = .stabilize,
    .amount = 0.10,
    .cause = verified_evidence_id,
    .reason = "independent-successes",
    .actor = "trusted-runner",
    .receipt = "verified-receipt",
    .timestamp = now,
});
```

## Procedural Memory

`procedure` 是一等认知记录，不是仅按时间排列的工具调用日志。它可复用通用 `scopes` 表达适用范围，使用 `metrics` 表达效用、成本、成功率或领域质量，并通过经过验证的 `reinforce`、`penalize`、`decay` 与 `stabilize` transition 形成可塑性。MEML 输出这些过程倾向及其证据；宿主规划器仍决定是否执行实际 Action。

## 可配置可塑性

`PlasticityPolicy` 将已验证 feedback 映射为有限状态变化：每个 outcome 或 failure class 最多设置一个生命周期状态，并执行一次 `reinforce`、`penalize`、`decay` 或 `stabilize`。策略是宿主运行时配置，不会写入 `MEML15`，从而不把部署授权或环境规则混入记忆状态。每次实际变化仍生成 `TransitionRecord`。

## 离散稳定性与吸引子

`Runtime.stability(id)` 从支持/矛盾证据、transition 历史、谱系与当前 confidence/strength 推导 `transient`、`emerging`、`stable` 或 `contested`。这不是额外存储的 belief 字段：恢复后可确定性重算。`Context.minimum_stability` 可过滤低稳定度候选，激活结果会在 `signals.stability` 中解释该贡献。

## 预算受限的状态传播

Provider 只返回初始 candidate seeds。`Context.propagation` 由内核控制传播：`max_hops`、`seed_limit`、`edge_limit` 与 `candidate_limit` 都有上界；传播过程按 `activation_policy` 过滤生命周期状态。`activateWithStats()` 报告 seeds、propagated 与 edges_examined。默认 `max_hops=0`，不改变普通检索路径；需要图扩散时由调用方显式开启。

## 历史过程预测

`predictProcedureAt(procedure, context, cutoff)` 仅汇总 cutoff 时刻以前直接反馈到该 procedure 的 verified outcomes，返回 Laplace 平滑的 success probability、样本数、证据覆盖度和 scope 兼容性。它是经验估计，不是世界模型，也不决定宿主 Action。`evaluateProcedurePredictions()` 可对 hold-out outcome 检验 accuracy 与 Brier score。可运行 [`examples/dynamics-forecast.jsonl`](../examples/dynamics-forecast.jsonl) 观察截止时间如何防止未来结果泄漏。

## Procedure 选择质量门与受限反事实比较

`selectProcedures(candidates, context, gate, allocator)` 只读取调用方**显式传入**的 procedure ID 集合。它不会调用 retrieval、backend、图传播或任何宿主工具，因此不会擅自发现候选、执行 Action 或把相关性声称为因果性。

每个候选先经过 `ProcedureSelectionQualityGate`：

- 默认要求 `active` 状态；
- 默认要求 procedure scopes 与请求 scopes 完全一致；
- 最低稳定度、最小 verified outcome 样本数、最低成功概率和最低 evidence coverage 均需达标；
- 被拒绝的候选保留完整失败维度，但 `counterfactual_score` 和 `rank` 为 `null`，不会参与相对排序。

合格候选以固定、可解释的经验分数比较：

\[
score = 0.4 \cdot stability + 0.4 \cdot P(success) + 0.2 \cdot coverage
\]

这只是“若当前只能在这些候选中考虑”的历史经验排序，不预测真实未来，也不替宿主选择 Action。`evaluateProcedureSelection()` 可验证预期候选是否被选为第一名。运行 [`examples/procedure-selection.jsonl`](../examples/procedure-selection.jsonl) 可看到稳定的 reliable procedure 排在第一，争议/失败候选被拒绝。

该能力只通过库 API 与 JSON-lines `select_procedures` 暴露；受限 `.meml` DSL 故意不提供 `select` 语句。DSL 仅提交可审计状态变化，不能把建议包装成可执行决策或 Action。

## 显式多目标比较

`compareProcedures(candidates, context, policy, allocator)` 是更严格的受限反事实比较。调用方必须声明每个目标：`stability`、`success_probability`、`evidence_coverage`，或精确的 `metric(name, unit)`。每个目标包含 `maximize|minimize`、非负权重与可选硬约束；空目标、重复目标、`neutral` 方向、无穷数值、隐式单位或总权重为零都会被拒绝。

对 metric，内核不会猜测语义或转换单位，并使用保守值：maximize 使用 \(value - uncertainty\)，minimize 使用 \(value + uncertainty\)。硬约束先于排序；缺失 metric、方向不匹配或未达硬约束的候选保留逐目标拒绝原因，但不会拥有 `counterfactual_score` 或 `rank`。

仅在合格候选之间，内核按候选集合中的 min-max 归一化计算：

\[
score = \frac{\sum_i weight_i \cdot normalized_i}{\sum_i weight_i}
\]

同分以 procedure ID 打破，保证确定性。该 score 仅表示“在当前显式候选和显式目标下的保守经验排序”，不是未来事实、因果结论或执行指令。JSON-lines `compare_procedures` 和 [`examples/procedure-comparison.jsonl`](../examples/procedure-comparison.jsonl) 提供可审计输出；DSL 仍不暴露比较命令。

## State-aware Activation

`Context.activation_policy` 控制哪些状态能参与激活：

- `active_only`：默认，只返回当前有效认知记录；
- `include_contested`：调试、复核或冲突处理时也返回争议记录；
- `include_historical`：审计时包含 superseded 与 archived 历史。

这保证“经历不同世界后，未来状态不同”是可测、可解释、可回放的：同一查询在 transition 前后能得到不同的激活集合，同时保留产生该差异的审计证据。

## Memory Dynamics Language

受限 `.meml` 语言支持声明式转移：

```meml
assert agent selects compact-reply user-preference confidence 0.7 as style
transition style reinforce 0.2 actor trusted-agent receipt receipt-42 at 100 reason verified-preference
transition style set_state contested actor trusted-agent receipt receipt-43 at 101 reason contradictory-feedback
```

DSL 没有循环、函数、网络或工具调用；它只可提交上述有限转移原语，且仍经过宿主 `TransitionVerifier`。

## 评估原则

动态记忆不能仅以“存入了多少记录”或 Recall 衡量。最小验收应包括：

1. 无 verifier 的转移不得改变状态；
2. 经验证 transition 后，激活集合或排序必须按状态策略发生可解释变化；
3. 每项变化可追溯到 transition、cause 和 receipt；
4. `MEML15` 恢复后审计序列、节点状态和激活结果保持一致；
5. 过程预测只能使用 cutoff 之前的 feedback，并以 hold-out accuracy 与 Brier score 报告校准质量；
6. selection 仅比较显式候选集合，拒绝项不得拥有排名；
7. 多目标比较必须由调用方显式传入 candidate 与目标；未传入候选、目标方向不匹配、metric 缺失或硬约束不满足时不得产生 rank；
8. 宿主在 hold-out 任务上的成功率、成本、延迟或领域指标确有改善。

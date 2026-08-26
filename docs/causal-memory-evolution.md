# 因果记忆整合与持久化

本文说明 MEML 当前如何把经验转为可检索的长期结构，以及这一过程的验证边界。行为由 `src/runtime_test.zig` 的端到端回归测试覆盖，运行环境为 Zig 0.17。

## 两种整合模式

### 默认：观察与派生分离

`observe()` 只创建 `experience`、更新待处理指纹组，并使原始经验可参与检索。它不会自动创建 `memory`、`belief`、`concept` 或 `procedure`。这种默认行为保证既有调用方可以控制何时改变持久化语义结构。

对三条相同经验的受控测试确认：观察后有 3 个 experience，尚无 memory、belief、concept、procedure 或关系；检索结果会因原始经验存在而变化。

### 显式或事件触发整合

可通过以下方式形成派生结构：

- `consolidateAll()`：对全部经验执行默认整合策略。
- `consolidatePending(policy)`：只处理受影响的待处理指纹组，并刷新相关 concept 与 procedure 依赖。
- `consolidateAllAtomic(policy)` / `consolidatePendingAtomic(policy)`：在发生失败时回滚本轮内存变更。
- `enableAutoConsolidation(policy)`：为后续 `observe()` 启用事件触发整合；`disableAutoConsolidation()` 恢复默认行为。

默认策略会把经验派生为 memory；达到重复阈值的同类经验派生为 belief；belief 可泛化为 concept；按时间排序且成功率满足阈值的经验可形成 procedure；确定性 neural consolidator 可以产生带 `derived_from` 来源关系的 artifact。重复执行是幂等的，推导记录保存规则、版本与源节点 ID。

策略可独立启用或关闭 memory、belief、concept、procedure 和 neural 规则，并配置重复阈值、过程成功率和故障注入边界。

## Agent 反馈闭环

Agent 可先按 `Context` 检索候选策略、工具偏好或过程，再通过 `setFeedbackVerifier()` 配置宿主结果验证器，最后调用 `recordFeedback(FeedbackInput)` 记录真实执行结果。源语言提供等价的 `feedback <label> success|failure <failure_class> actor <actor> receipt <receipt> at <timestamp>` 语句。

- `FeedbackVerifier` 在任何状态写入之前校验 actor、receipt 和业务结果；未配置、校验拒绝或结构不合法的反馈不会创建 evidence，也不会改变目标评分。
- 每次已验证反馈都会创建带时间戳的 `evidence` 节点，并以 `supports` 或 `contradicts` 关系保留对目标的来源，同时持久化 outcome、failure class、actor 与 receipt。
- 默认 `PlasticityPolicy` 会在 success 时将目标 confidence 与 strength 各增加 `0.1`；失败可按类别进入 `contested` 并执行有界降权：timeout `0.05`、transport `0.1`、tool_error `0.2`、invalid_result `0.3`、unknown `0.15`；policy_denied、unauthorized 与 cancelled 默认不改变状态。宿主可通过范围校验的 `setPlasticityPolicy()` 配置每类反馈的生命周期与数值 adjustment；每次实际改变都会写入 transition 审计。
- 该状态随 `MEML14` 持久化并参与后续激活的 confidence 信号；它不是模型训练或自动参数学习。
- 反馈写入本身是完整运行时事务。MEML 不内置身份、授权、签名或网络验证；调用方须在宿主边界提供认证、授权、回执验证和敏感数据脱敏。

## 信念与冲突

信念记录 `active`、`contested`、`superseded` 或 `archived` 生命周期状态，并保存支持次数、矛盾次数和确认时间。

- 重复支持会提高信念强度并更新确认信息。
- 同一情境下的互斥信念形成矛盾关系，降低置信度并标记为 contested。
- 不同情境下的互斥信念可以同时保持 active；激活时由情境感知的冲突评分优先选择相关信念，同时保留另一信念用于历史解释。
- superseded 与 archived 信念会从后续常规检索中过滤。

## 原子整合与恢复

原子整合会保存完整运行时快照：语义存储、ID 与时钟、派生索引、待处理组、整合游标、signal pipeline 以及自动整合配置。注入失败时恢复完整快照并重建后端索引；成功时才提交该批变更，待处理组可在回滚后重试。

`persist()` 与 `persistAtomic()` 都将完整 `MEML14` 状态写入 `<path>.journal`，同步、校验后原子替换目标文件，并写入 `<path>.index.journal`：它保存语义 revision 与有序节点 ID 清单。恢复只接受 revision 和节点集合均匹配的索引 checkpoint；不匹配的 checkpoint 会被删除，派生索引仍由语义状态重建。`recover()` 会检测遗留语义 journal：有效且更新的 journal 被重放，陈旧或无效 journal 被删除。持久化采用非阻塞单写者锁；锁文件保留稳定 inode，并发写入者收到 `WouldBlock`。

本地保证范围是使用 MEML API 的文件系统调用。远程 CAS 由 `storage.Remote.Transport` 交给宿主实现；MEML 不自行发起网络请求。认证、TLS、端点 allowlist、目录元数据 fsync、生产远程存储一致性以及绕过 API 的锁协作不在当前保证范围内。

## 保存与恢复的状态

`MEML14` 保存语义节点、通用结构化范围/指标/制品/结构身份、关系、推导记录、指纹组及成员、信念生命周期字段、确定性 `NeuralState`、学习型 signal 的版本化权重与偏置、经过验证的反馈审计记录，以及单调递增的提交 revision。加载器只接受完整、严格且规范排序的 `MEML14` 记录；旧格式返回 `UnsupportedVersion`，不提供迁移、双写或兼容读取。节点 ID、图引用、指标范围、制品摘要、指纹计数、神经 artifact、反馈 evidence/target/receipt 和 provider 状态均需通过校验；恢复时会以 revision 选择比目标更新的有效 journal，并从语义记录重建 provider 索引。

确定性 neural artifact 会创建包含 artifact ID、activation count、strength 和版本的 `NeuralState`。该状态在恢复后仍被参考神经检索 provider 使用，测试会比较有无该状态时的检索信号。`calibrated` provider 则消费持久化的透明参数，仍由内核控制最终排序与解释。这证明 artifact 和校准状态会影响后续检索，不代表模型训练，也不代表学习 embedding、模型权重或二进制检查点已经被保存。

## 已验证范围

回归测试覆盖：

- 默认观察路径与显式/自动整合路径的结构差异。
- 全量与增量整合、依赖失效刷新、幂等性与来源记录。
- 信念支持、矛盾、生命周期和情境感知冲突。
- 整合失败回滚与重试。
- journal 恢复、revision 绑定索引 checkpoint、单写者拒绝、严格状态加载和状态往返。
- 行级源诊断、显式关系创建/删除以及无效生命周期操作的原子拒绝。
- provider 生命周期、索引重建、确定性 neural state 对检索的影响。
- 经验、信念、概念与过程四阶段的长程检索路径，以及多任务、上下文漂移和人工标注的 Agent 评估接口。

## 当前边界

- 默认 `observe()` 不执行自动整合；需显式调用整合 API 或启用事件触发模式。
- 重复检测与冲突更新策略是参考实现，复杂领域的置信度、冲突消解和规则设计应由调用方校准。
- neural consolidation 是确定性、提案式实现；已持久化透明 signal 校准参数，但学习 embedding、模型权重和二进制检查点仍没有持久化。
- 长程评估是固定的 API/检索回归场景，不是生产数据集或模型效果声明。

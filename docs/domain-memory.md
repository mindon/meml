# 领域结构化记忆

MEML 的内核保存通用、可解释的记录；量子计算、AI for Science 与普通 Agent 通过适配器把本领域输入规范化为同一组原语。内核不包含 qubit、分子、仪器或任何固定领域规则。

```text
通用可解释记忆内核
  + 通用结构化证据 / 指标 / 范围 / 制品 / 谱系
  + 可插拔领域适配器与信号
  = 量子、AI for Science、普通 Agent 都可复用
```

## 通用记录模型

`RecordInput` 保留 `subject`、`predicate`、`object`、`context`、`result` 的可读叙述，并可附加：

- `scopes`：版本化、可兼容性匹配的键值范围，例如 `dataset`、`model`、`code`、`backend`、`environment`。这些只是约定键，内核不解释它们的领域含义。
- `metrics`：名称、有限数值、可选单位、不确定性和优化方向。方向仅是声明，如何比较由适配器或调用方策略决定。
- `artifacts`：`kind`、十六进制内容摘要和可选 locator。MEML 仅保存引用，永不读取 locator 或主动访问网络。
- `structure`：领域 adapter 生成的 `kind` 和十六进制 fingerprint；内核只做精确匹配。图相似、分子相似或电路 DAG 相似应由外部 signal provider 计算后作为候选或信号贡献输入。
- `derived_from`：通用谱系边，派生结果指向输入证据、制品或上游结果。不要将 `follows` 的时间链误当成数据或电路依赖。

写入会限制 scopes、metrics、artifacts 的数量以及字段长度，拒绝非有限数字、负不确定性、非十六进制摘要和重复的同记录范围/指标键。

## 适配器边界

`science.Adapter` 是标准边界：它可以校验和规范化 `RecordInput`，随后调用 `Runtime.record`。adapter 不持有 `Store`，不能自行写节点、关系、反馈或索引。

`quantum.zig` 是一个可选示例：它把后端、校准和编译器写入 scopes；把深度、双比特门数和保真度写入 metrics；把电路和拓扑写入 artifact 与 structure。量子失败码、噪声模型解释和拓扑相似度仍在量子 adapter/provider 中，而非内核中。

普通 Agent 可以直接调用 `Runtime.record`，或者使用 `science.Generic.adapter()` 做同样的通用输入校验。

## 检索与解释

`Context` 可携带 `scopes` 和精确 `structure`。内核输出的 `Signals` 新增：

- `scope`：请求范围中兼容项的覆盖比例；同键不同值会降为零。
- `metric`：指标是否存在以及不确定性的基础质量信号；它不替代领域目标函数。
- `structure`：请求和记录的结构种类、指纹均相同则为 `1`。
- `lineage`：`derived_from` 谱系的完整度信号。

这些是具名解释项，由 `Weights` 独立加权；原始语义、冲突、最终排序和安全上限仍由内核唯一控制。

## JSON-lines 协议

`meml` 的 `observe` 支持传统字段与下列可选结构化字段：

```json
{
  "op": "observe",
  "subject": "simulation",
  "predicate": "evaluated_candidate",
  "object": "fedcba9876543210",
  "timestamp": 200,
  "scopes": [{"key": "dataset", "value": "screen-v3"}],
  "metrics": [{"name": "error", "value": 0.021, "unit": "eV", "uncertainty": 0.004, "direction": "minimize"}],
  "artifacts": [{"kind": "result", "digest": "fedcba9876543210"}],
  "structure": {"kind": "workflow", "fingerprint": "0011223344556677"}
}
```

`activate` 也可携带 `scopes` 与 `structure`。标准输入和 `--file` 均逐行读取；单行超过 64 KiB 会被拒绝而不会积压整个输入。

运行示例：

```sh
zig build run -- --file examples/quantum-feedback.jsonl
zig build run -- --file examples/science-workflow.jsonl
```

## 持久化与安全

状态格式为唯一支持的 `MEML15`。旧格式一律返回 `UnsupportedVersion`，没有迁移、双写或兼容读取路径。结构化记录与语义图一起持久化，派生索引仍在恢复后重建。

外部硬件、实验系统、文件存储和模型服务由宿主负责认证、授权、端点控制与内容完整性。反馈缺省可写；显式安装 `FeedbackVerifier` 或 Ed25519 策略后，才必须通过 actor、receipt、目标、结果与时效校验。部署若需要拒绝未经验证的外部结果，应明确安装该策略。

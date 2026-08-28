# MEML 使用指南

本文是 MEML 的操作手册，覆盖三种接入方式：**Zig 库（`meml`）**、**命令行桥接（`meml`）** 和 **源语言脚本（`.meml`）**。

| 入口 | 产物 | 适用场景 |
|---|---|---|
| Zig 库 | `src/meml.zig` | 宿主本身是 Zig，直接链接，零桥接成本 |
| CLI | `zig-out/bin/meml` | 任意语言（Python / TypeScript / Go …）通过子进程调用 |
| 源语言 | `*.meml` 文件 | 把「记忆策略」写成可编辑、可版本化、可事务执行的脚本 |

三者共享同一个 `Runtime` 内核：语义、评分、排序、冲突规则与激活解释完全一致，只是调用形态不同。

---

## 1. 构建

需要 Zig 0.17。

```sh
zig build          # 安装 meml-example 与 meml 到 zig-out/bin/
zig build test     # 运行测试
zig build example  # 运行最小库示例
zig build demo     # 运行 examples/demo.meml 端到端演示
zig build bench -Doptimize=ReleaseFast   # 运行确定性检索基准
```

---

## 2. 作为 Zig 库使用（`meml`）

### 2.1 核心生命周期

```text
observe/assert（写入） → activate（检索） → recordFeedback（回写结果）
→ consolidate（整合为长期结构） → persist（持久化） → recover（恢复）
```

### 2.2 最小可运行示例

```zig
const std = @import("std");
const meml = @import("meml");

// 宿主信任边界：验证 feedback 的 actor 与 receipt。
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

    // 1. 创建运行时
    var runtime = meml.Runtime.init(a);
    defer runtime.deinit();

    // 2. 写入经验（经验级，带时间戳）
    const exp = try runtime.observe("user", "uses", "typescript", "frontend", "success", 10);

    // 3. 声明更高层的结论（带置信度）
    const claim = try runtime.assert("user", "uses", "typescript", "frontend", 0.8);

    // 4. 建立关系：claim 由 exp 支撑
    try runtime.support(claim, exp, 0.9);

    // 5. 添加信号 provider（可选，影响评分、不改记忆身份）
    try runtime.addSignalProvider(meml.signals.Metadata.provider());
    try runtime.addSignalProvider(meml.neural.retrievalProvider());

    // 6. 按上下文检索，返回可解释的激活列表
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

    // 7. 配置信任边界后回写执行结果（context 可携带宿主校验状态，这里用占位符）
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

    // 8. 整合为长期记忆
    const report = try runtime.consolidateAllAtomic(.{});
    _ = report;

    // 9. 持久化与恢复
    try runtime.persist(io, "meml.state");
    var restored = try meml.Runtime.recover(a, io, "meml.state");
    defer restored.deinit();
}
```

### 2.3 通用结构化记录

`record(RecordInput)` 在不引入领域实体的前提下写入可复现实验或工作流证据；`observe()` 仍适合仅含文本字段的轻量经验。范围按 `key` 字典序、指标按 `name`/`unit` 字典序、制品按摘要字典序提供，以获得稳定身份。

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

`science.Generic.adapter()` 提供同一通用校验边界；`quantum.adapter()` 仅是可选的量子输入规范化示例。二者均不能直接写 `Store`。详见 [`docs/domain-memory.md`](docs/domain-memory.md)。

### 2.4 动态认知状态

MEML 只改变可审计的记忆状态，不直接选择或执行宿主 Action。宿主必须先安装 `TransitionVerifier`，再调用受限的 `transition()`；每次变更都会以 `TransitionRecord` 持久化在 `MEML15` 中。

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

var current = try runtime.activate(.{ .query = "procedure" }, 5, a); // 默认只激活 active
var audit = try runtime.activate(.{ .query = "procedure", .activation_policy = .include_historical }, 5, a);
defer current.deinit(a);
defer audit.deinit(a);
```

受限 DSL：`transition <label> reinforce|penalize|decay|stabilize <0..1> actor <actor> receipt <receipt> at <timestamp> reason <reason>`；`set_state` 则将数值替换为 `active|contested|superseded|archived`。详见 [`docs/dynamic-memory.md`](docs/dynamic-memory.md) 和 [`examples/dynamic-memory.jsonl`](examples/dynamic-memory.jsonl)。

### 2.5 签名反馈证明

对于会影响长期记忆的执行反馈，应优先使用 Ed25519 证明而非兼容回调。仅通过 `setFeedbackAttestationPolicy` 安装宿主公钥；`FeedbackAttestation` 签名的规范化载荷会绑定 issuer/key ID、nonce、签发与过期时间、反馈字段、不透明 receipt 引用，以及目标节点的所有语义字段。有效证明的 issuer 必须与 actor 一致，且必须同时满足事件时间与运行时逻辑时钟的有效期。MEML 仅把已接受载荷的 SHA-256 摘要和过期时间持久化到 `MEML15`，因此恢复后仍会拒绝重放；不会保存 nonce、签名或私钥。

CLI 宿主通过 `set_attestation_verifier` 配置 Base64 编码的公钥，并在 `feedback.attestation` 提供 Base64 编码的 64 字节签名。`receipt` 必须是不透明引用而不是凭据。`clear_verifier` 会同时清除旧回调与签名证明策略；`recover` 后必须重新安装公钥配置。

### 2.6 冻结检索评测

`zig build eval` 会加载 `eval/datasets/retrieval-v1/seed.jsonl`，通过稳定的 `record_key` 解析 `annotations.jsonl` 中的人工标签，并与 `eval/baselines/retrieval-v1.json` 比较多标签 Recall@K、MRR 和分级 NDCG。输出 JSON 报告是确定性的；CI 会在每次 push 和 PR 上执行该质量门。数据集更新必须新建版本目录并经人工审阅基线，不得改写既有 benchmark。

### 2.7 Procedure 选择质量门

`selectProcedures()` 只对宿主显式给定的 procedure ID 做只读比较，不会检索、扩张候选或执行 Action。gate 要求 active 状态、严格 scope 匹配、稳定性、verified outcome 样本数、成功概率和证据覆盖度均达标；不达标项保留拒绝原因，但没有排名。

```zig
var choices = try runtime.selectProcedures(
    &.{ procedure_a, procedure_b },
    .{ .scopes = &scopes },
    .{ .min_stability = 0.75, .min_samples = 3, .min_success_probability = 0.6, .min_evidence_coverage = 0.5 },
    a,
);
defer choices.deinit(a);
// rank == 1 只是当前显式候选中的经验建议，宿主仍决定是否执行。
```

`predictProcedureAt()` 适合带 cutoff 的历史预测评估；`selectProcedures()` 则只使用当前认知状态，避免把未来状态混入历史选择回放。JSONL 示例见 [`examples/procedure-selection.jsonl`](examples/procedure-selection.jsonl)。

### 2.8 显式多目标比较

`compareProcedures()` 仅比较调用方提供的 procedure ID，并要求调用方显式声明目标、方向、权重和可选硬约束。目标可为 `stability`、`success_probability`、`evidence_coverage`，或精确的 metric `name + unit`；内核不会推断领域语义或进行单位换算。

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

metric 的 uncertainty 会以保守方向纳入：maximize 取 `value - uncertainty`，minimize 取 `value + uncertainty`。缺 metric、方向冲突或硬约束失败的候选没有 score/rank，但保留逐目标拒绝原因。该 API 不调用检索、backend、图扩张、工具或 Action。示例见 [`examples/procedure-comparison.jsonl`](examples/procedure-comparison.jsonl)。

### 2.9 核心 API

`Runtime` 的公开方法（`src/runtime.zig`）：

| 分组 | 方法 | 说明 |
|---|---|---|
| 生命周期 | `init(allocator)` / `deinit()` | 创建 / 释放 |
| 写入 | `observe(subject, predicate, object, context, result, timestamp) !u64` | 记录经验，返回节点 id |
| | `assert(subject, predicate, object, context, confidence) !u64` | 声明结论，返回节点 id |
| | `remember(id) !u64` | 将节点提升为 memory |
| | `infer(id) !u64` | 由节点推导新节点 |
| 关系 | `link(from, kind, to, weight)` / `unlink(from, kind, to)` | 建 / 删显式关系 |
| | `support(from, to, weight)` / `contradict(from, to)` | 支撑 / 矛盾 |
| 认知状态 | `supersedeBelief(old, replacement)` | 信念替代；其状态变化写入审计 |
| 动态转移 | `setTransitionVerifier(verifier)` / `clearTransitionVerifier()` | 宿主信任边界 |
| | `transition(input) !u64` / `verifyTransitionHistory()` | 有界状态改变 / 审计连续性 |
| 抽象 | `generalize(ids, concept) !u64` / `inferProcedure(ids, name) !u64` | 归纳概念 / 过程 |
| 检索 | `activate(context, limit, allocator) !ArrayList(Activation)` | 上下文检索 |
| | `activateWithStats(context, limit, allocator) !retrieval.Result` | 检索并返回候选/评分统计 |
| 过程决策 | `stability(id)` / `predictProcedureAt(id, context, cutoff)` | 派生稳定性 / 历史 outcome 估计 |
| | `selectProcedures(ids, context, gate, allocator)` | 仅显式候选的质量门与经验比较 |
| 信号 | `addSignalProvider(provider)` / `setSignalCalibration(weight, bias)` / `addCalibratedSignalProvider()` | 接入可替换信号 |
| 反馈 | `setFeedbackVerifier(verifier)` / `clearFeedbackVerifier()` | 信任边界 |
| | `setPlasticityPolicy(policy)` / `recordFeedback(input) !u64` | 已验证结果驱动的可塑性 |
| 整合 | `consolidate()` / `consolidateAll()` / `consolidatePending(policy)` | 显式整合 |
| | `consolidateWithPolicy(policy)` / `consolidateAllAtomic(policy)` / `consolidatePendingAtomic(policy)` | 策略化 / 原子整合 |
| | `consolidateNeural(consolidator) !usize` | 确定性 neural 整合 |
| | `enableAutoConsolidation(policy)` / `disableAutoConsolidation()` | 事件触发整合 |
| 后端 | `useVectorBackend()` / `useGraphBackend()` | 切换候选 provider |
| 持久化 | `persist(io, path)` / `persistAtomic(io, path)` | 保存（原子写入可选） |
| | `persistTo(provider, io, path)` / `persistIfRevision(provider, expected_revision, io, path)` | 自定义 / CAS |
| | `recover(allocator, io, path) !Runtime` | 恢复 |

### 2.10 关键类型与枚举

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

信号 provider 由 `src/signals.zig` 与 `src/neural.zig` 提供：

```zig
meml.signals.Metadata.provider()
meml.signals.Embedding.provider()
meml.signals.Reranker.provider()
meml.signals.Calibrated.provider()
meml.neural.retrievalProvider()
```

`LocalEmbedding` 是宿主拥有的本地向量缓存 provider：宿主预计算 query/node 向量并提供回调，MEML 仅本地计算余弦分数，不加载模型、不访问网络，也不持久化向量、模型或凭据。`backend.LocalSemantic` 用同一边界暴露宿主本地 ANN 候选源；可通过 `backend.Hybrid` 与任一 lexical provider 去重并集。`model_version` 与 `model_sha256` 应由宿主记录为可审计的制品元数据。

---

## 3. 命令行桥接（`meml`）

`meml` 是一个 JSON-lines 桥接：**每行一个 JSON 请求进，每行一个 JSON 响应出**，状态在同一进程内跨请求保留。

### 3.1 运行模式与维护命令

| 模式 | 命令 | 说明 |
|---|---|---|
| 单请求 | `meml '<json>'` | 处理单个请求后退出，**每次都是全新状态** |
| 常驻 REPL | `meml`（stdin 逐行） | 状态跨请求保留，适合 agent 常驻子进程 |
| 文件 | `meml --file reqs.jsonl` | 按行批量处理 |
| 版本 | `meml version`（也支持 `--version`、`-V`） | 输出当前 CLI 版本 |
| 升级 | `meml upgrade [vMAJOR.MINOR.PATCH]` | 下载并安装最新版本；可指定 Release 标签 |

`upgrade` 复用官方安装器，默认更新到最新 Release；仅支持已发布的语义化版本标签。响应格式：`{"ok":true,...}` 或 `{"ok":false,"error":"..."}`。

### 3.2 命令表

| op | 请求字段 | 返回 |
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
| `select_procedures` | `ids,scopes?,gate?` | `{ok,selections}`；仅比较显式候选 |
| `compare_procedures` | `ids,scopes?,min_samples?,objectives` | `{ok,comparisons}`；显式目标的保守多目标比较 |
| `feedback` | `target,outcome,failure_class,actor,receipt,timestamp,attestation?` | `{ok,evidence}` |
| `set_attestation_verifier` | `issuers[{issuer,key_id,public_key}]` | `{ok}`；Base64 Ed25519 公钥 |
| `consolidate` | `repeat_threshold,procedure_success_ratio,enable_memory,…` | `{ok,统计}` |
| `auto_consolidate` | `enable,…` | `{ok}` |
| `signals` | `providers` | `{ok,providers}`；元素可为名称或 `{name,weight}` |
| `backend` | `backend` | `{ok}`；`hybrid` 为 lexical ∪ local hash-vector 候选 |
| `persist` | `path?,atomic` | `{ok}`；未给 `path` 时使用 `~/.meml/state/memory.state` |
| `recover` | `path?` | `{ok}`；未给 `path` 时使用 `~/.meml/state/memory.state` |
| `import_meml` | `files` | `{ok,documents,observed,asserted,links}`；原子导入多个受限 `.meml` 文件 |
| `exec` | `program` | `{ok,统计}` |
| `set_verifier` | `trusted_actors,receipt_prefix` | `{ok}` |
| `clear_verifier` | — | `{ok}` |
| `set_plasticity_policy` | `success?,timeout?,transport?,tool_error?,…`（每项含 `state?`,`adjustment?`,`amount`） | `{ok}` |

枚举取值：

- `kind`：`supports | contradicts | derived_from | generalizes | follows | causes`
- `state`：`active | contested | superseded | archived`
- `outcome`：`success | failure`
- `failure_class`：`none | timeout | transport | tool_error | invalid_result | policy_denied | unauthorized | cancelled | unknown`
- `backend`：`vector | graph | hybrid`
- `providers`（数组）：`metadata | embedding | reranker | calibrated | neural`，每项可写为字符串或 `{ "name":"embedding", "weight":2 }`

`activate` 响应会额外返回 `provider_trace`，按 provider 列出未加权 `score` 与配置 `weight`。文本匹配由 `tokenizer-ascii-v1` 统一处理：ASCII 大小写归一、按兼容分隔符分词；该版本刻意不隐式做中文/CJK 分词。

### 3.3 多源记忆导入与默认存储

`import_meml` 会按 `files` 数组顺序读取当前工作目录下的相对 `.meml` 文件，并将整批语义记录作为一次内存事务导入。它不是 `MEML15` 快照合并：每份文件都有独立标签作用域，只允许 `observe`、`assert` 与引用本文件标签的 `link`；`feedback`、`transition`、`unlink`、`signals`、`consolidate` 与检索语句会被拒绝。路径不得为绝对路径或包含 `.` / `..` 段，单文件上限 512 KiB、整批上限 4 MiB、最多 64 个文件。导入不自动持久化，成功后应显式调用 `persist`。

```jsonl
{"op":"import_meml","files":["examples/import-preferences.meml","examples/import-history.meml"]}
{"op":"persist","atomic":true}
```

`persist` 和 `recover` 未提供 `path` 时都使用 `~/.meml/state/memory.state`；`persist` 会创建该父目录。集成应优先使用 `MEML_STATE_PATH`，并按 Agent 使用不同文件名（例如 `codebuddy.state`），避免不同宿主误共享状态。

### 3.4 Shell 示例

```sh
# 常驻模式：状态跨请求保留
printf '%s\n' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"typescript","context":"frontend","result":"success","timestamp":10}' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"python","context":"backend","result":"success","timestamp":20}' \
  '{"op":"activate","query":"uses","goal":"pick a tool","situation":"frontend","limit":5,"details":true}' \
  '{"op":"set_verifier","trusted_actors":["workbuddy"],"receipt_prefix":"receipt-"}' \
  '{"op":"feedback","target":1,"outcome":"success","failure_class":"none","actor":"workbuddy","receipt":"receipt-1","timestamp":80}' \
  '{"op":"persist","path":"meml.state","atomic":true}' \
| ./zig-out/bin/meml
```

### 3.5 Python 常驻进程示例（agent 集成）

```python
import subprocess, json

proc = subprocess.Popen(
    ["zig-out/bin/meml"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)

def meml(req):
    proc.stdin.write(json.dumps(req) + "\n"); proc.stdin.flush()
    return json.loads(proc.stdout.readline())

# 1. 恢复既有记忆
meml({"op": "recover", "path": "meml.state"})

# 2. 配置信任边界（feedback 的前置条件）
meml({"op": "set_verifier", "trusted_actors": ["workbuddy"], "receipt_prefix": "receipt-"})

# 3. 记录经验
r = meml({"op": "observe", "subject": "user", "predicate": "uses",
          "object": "typescript", "context": "frontend", "result": "success", "timestamp": 10})

# 4. 检索
acts = meml({"op": "activate", "query": "uses", "goal": "pick a tool",
             "situation": "frontend", "limit": 5, "details": True})
for a in acts["activations"]:
    print(a["id"], a["score"], a["signals"]["semantic"], a["signals"]["confidence"])

# 5. 执行真实任务后回写结果
meml({"op": "feedback", "target": r["id"], "outcome": "success",
      "failure_class": "none", "actor": "workbuddy", "receipt": "receipt-ts", "timestamp": 80})

# 6. 沉淀长期记忆 + 持久化
meml({"op": "consolidate", "repeat_threshold": 2})
meml({"op": "persist", "path": "meml.state", "atomic": True})

proc.stdin.close()
```

> 注意：`feedback` 缺省可写。调用 `set_verifier` 或 `set_attestation_verifier` 后才启用证明强制：未信任 actor 返回 `UntrustedActor`，receipt 前缀不匹配返回 `UntrustedReceipt`，缺失或无效 attestation 会被拒绝。

---

## 4. 源语言脚本（`.meml`）

`.meml` 是受限的领域命令集，执行前完成解析与静态校验，整份程序作为运行时事务执行。适合把记忆策略写成可编辑、可版本化的文件。

### 4.1 语法

```meml
# observe 记录经验（可 as 打标签）
observe user uses typescript frontend success at 10

# assert 声明结论（confidence + as 标签）
assert user uses typescript frontend confidence 0.8 as ts_use

# context 定义检索上下文
context performance {
    goal: "pick the right tool"
    situation: systems
    query: uses
    preferred: zig
}

# 开启信号 provider
signals metadata neural

# activate 按上下文检索
activate performance top 5

# feedback 回写执行结果
feedback ts_use success none actor workbuddy receipt receipt-1 at 80

# link / unlink 显式关系
link zig_use contradicts py_systems weight 1

# 整合
consolidate
neural consolidate deterministic
```

### 4.2 运行方式

```sh
zig build demo                       # 运行 examples/demo.meml
```

```zig
// 在库中执行脚本
var report = try meml.source.execute(&runtime, script_text, allocator);
// report.observed / asserted / feedback / consolidated / neural_artifacts
```

```sh
# 通过 CLI 执行脚本
./zig-out/bin/meml '{"op":"exec","program":"observe user prefers typescript frontend success at 10"}'
```

> `exec` 执行的脚本可缺省包含 `feedback`；仅当需要强制宿主证明时，才在同一进程内配置 `set_verifier` 或 `set_attestation_verifier`。

参考脚本：`examples/contextual_retrieval.meml`、`examples/demo.meml`。

---

## 5. 推荐的 agent 集成生命周期

```text
recover（恢复） → activate（检索注入上下文） → 执行 → feedback（回写结果）
→ consolidate（定期整合） → persist（持久化）
```

- 每次对话 / 工具调用后 `observe()` 记录经验。
- 决策前用 `activate()` 按当前 `Context` 检索，将可解释激活注入 prompt 或用于工具 / 策略选择。
- 执行真实结果用 `recordFeedback()` 回写，成功增益、失败按 `FailureClass` 降权。
- 定期 `consolidate()` 把重复经验沉淀为 memory / belief / concept / procedure，减少检索噪声。
- 会话结束 `persist()`，下次 `recover()` 无缝接续。

更多行为细节见 [`docs/causal-memory-evolution.md`](docs/causal-memory-evolution.md)。

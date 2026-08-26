# MEML 使用指南

本文是 MEML 的操作手册，覆盖三种接入方式：**Zig 库（`meml`）**、**命令行桥接（`meml-cli`）** 和 **源语言脚本（`.meml`）**。

| 入口 | 产物 | 适用场景 |
|---|---|---|
| Zig 库 | `src/meml.zig` | 宿主本身是 Zig，直接链接，零桥接成本 |
| CLI | `zig-out/bin/meml-cli` | 任意语言（Python / TypeScript / Go …）通过子进程调用 |
| 源语言 | `*.meml` 文件 | 把「记忆策略」写成可编辑、可版本化、可事务执行的脚本 |

三者共享同一个 `Runtime` 内核：语义、评分、排序、冲突规则与激活解释完全一致，只是调用形态不同。

---

## 1. 构建

需要 Zig 0.17。

```sh
zig build          # 安装 meml 与 meml-cli 到 zig-out/bin/
zig build test     # 运行测试
zig build run      # 运行最小库示例
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

### 2.4 核心 API

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
| 信念 | `setBeliefState(id, state)` / `supersedeBelief(old, replacement)` | 信念生命周期 |
| 抽象 | `generalize(ids, concept) !u64` / `inferProcedure(ids, name) !u64` | 归纳概念 / 过程 |
| 检索 | `activate(context, limit, allocator) !ArrayList(Activation)` | 上下文检索 |
| | `activateWithStats(context, limit, allocator) !retrieval.Result` | 检索并返回候选/评分统计 |
| 信号 | `addSignalProvider(provider)` / `setSignalCalibration(weight, bias)` / `addCalibratedSignalProvider()` | 接入可替换信号 |
| 反馈 | `setFeedbackVerifier(verifier)` / `clearFeedbackVerifier()` | 信任边界 |
| | `setFeedbackPolicy(policy)` / `recordFeedback(input) !u64` | 回写结果 |
| 整合 | `consolidate()` / `consolidateAll()` / `consolidatePending(policy)` | 显式整合 |
| | `consolidateWithPolicy(policy)` / `consolidateAllAtomic(policy)` / `consolidatePendingAtomic(policy)` | 策略化 / 原子整合 |
| | `consolidateNeural(consolidator) !usize` | 确定性 neural 整合 |
| | `enableAutoConsolidation(policy)` / `disableAutoConsolidation()` | 事件触发整合 |
| 后端 | `useVectorBackend()` / `useGraphBackend()` | 切换候选 provider |
| 持久化 | `persist(io, path)` / `persistAtomic(io, path)` | 保存（原子写入可选） |
| | `persistTo(provider, io, path)` / `persistIfRevision(provider, expected_revision, io, path)` | 自定义 / CAS |
| | `recover(allocator, io, path) !Runtime` | 恢复 |

### 2.4 关键类型与枚举

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

信号 provider 由 `src/signals.zig` 与 `src/neural.zig` 提供：

```zig
meml.signals.Metadata.provider()
meml.signals.Embedding.provider()
meml.signals.Reranker.provider()
meml.signals.Calibrated.provider()
meml.neural.retrievalProvider()
```

---

## 3. 命令行桥接（`meml-cli`）

`meml-cli` 是一个 JSON-lines 桥接：**每行一个 JSON 请求进，每行一个 JSON 响应出**，状态在同一进程内跨请求保留。

### 3.1 三种运行模式

| 模式 | 命令 | 说明 |
|---|---|---|
| 单请求 | `meml-cli '<json>'` | 处理单个请求后退出，**每次都是全新状态** |
| 常驻 REPL | `meml-cli`（stdin 逐行） | 状态跨请求保留，适合 agent 常驻子进程 |
| 文件 | `meml-cli --file reqs.jsonl` | 按行批量处理 |

响应格式：`{"ok":true,...}` 或 `{"ok":false,"error":"..."}`。

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
| `set_belief_state` | `id,state` | `{ok}` |
| `supersede` | `old,replacement` | `{ok}` |
| `generalize` | `ids,concept` | `{ok,id}` |
| `procedure` | `ids,name` | `{ok,id}` |
| `activate` | `query,goal,user,situation,now,preferred,resolve_conflicts,limit,stats,details` | `{ok,activations}` |
| `feedback` | `target,outcome,failure_class,actor,receipt,timestamp` | `{ok,evidence}` |
| `consolidate` | `repeat_threshold,procedure_success_ratio,enable_memory,…` | `{ok,统计}` |
| `auto_consolidate` | `enable,…` | `{ok}` |
| `signals` | `providers` | `{ok,providers}` |
| `backend` | `backend` | `{ok}` |
| `persist` | `path,atomic` | `{ok}` |
| `recover` | `path` | `{ok}` |
| `exec` | `program` | `{ok,统计}` |
| `set_verifier` | `trusted_actors,receipt_prefix` | `{ok}` |
| `clear_verifier` | — | `{ok}` |
| `set_feedback_policy` | `success_increment,timeout_multiplier,…` | `{ok}` |

枚举取值：

- `kind`：`supports | contradicts | derived_from | generalizes | follows | causes`
- `state`：`active | contested | superseded | archived`
- `outcome`：`success | failure`
- `failure_class`：`none | timeout | transport | tool_error | invalid_result | policy_denied | unauthorized | cancelled | unknown`
- `backend`：`vector | graph`
- `providers`（数组）：`metadata | embedding | reranker | calibrated | neural`

### 3.3 Shell 示例

```sh
# 常驻模式：状态跨请求保留
printf '%s\n' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"typescript","context":"frontend","result":"success","timestamp":10}' \
  '{"op":"observe","subject":"user","predicate":"uses","object":"python","context":"backend","result":"success","timestamp":20}' \
  '{"op":"activate","query":"uses","goal":"pick a tool","situation":"frontend","limit":5,"details":true}' \
  '{"op":"set_verifier","trusted_actors":["workbuddy"],"receipt_prefix":"receipt-"}' \
  '{"op":"feedback","target":1,"outcome":"success","failure_class":"none","actor":"workbuddy","receipt":"receipt-1","timestamp":80}' \
  '{"op":"persist","path":"meml.state","atomic":true}' \
| ./zig-out/bin/meml-cli
```

### 3.4 Python 常驻进程示例（agent 集成）

```python
import subprocess, json

proc = subprocess.Popen(
    ["zig-out/bin/meml-cli"],
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

> 注意：`feedback` 前必须先 `set_verifier`。未设置 verifier 时返回 `FeedbackVerifierRequired`，未信任 actor 返回 `UntrustedActor`，receipt 前缀不匹配返回 `UntrustedReceipt`。

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
./zig-out/bin/meml-cli '{"op":"exec","program":"observe user prefers typescript frontend success at 10"}'
```

> `exec` 执行的脚本若包含 `feedback`，需先在同一进程内 `set_verifier`。

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

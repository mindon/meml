# MEML：给 AI Agent 一个真正会「记住」的引擎

> 上下文感知记忆引擎 · 纯 Zig 实现 · 零运行时依赖 · 确定性可解释 · 可持久化可审计

很多 Agent 框架今天都在谈「记忆」，但大多只做了一件事：把对话塞进向量库，检索时算个相似度。结果就是——**它能想起来，却不知道什么该信、什么该改、什么该忘**。

MEML 想解决的是更根本的问题：**让 Agent 像人一样，把经历沉淀成记忆，把记忆提炼成信念，把信念固化成可复用的过程。**

---

## 一、核心理念：因果记忆演进（Causal Memory Evolution）

MEML 把「记忆」不是一个扁平的表，而是一条不断向上演进的阶梯：

```
experience 体验 ──► memory 记忆 ──► belief 信念 ──► concept 概念 ──► procedure 过程 ──► neural 神经状态
```

- **experience**：Agent 观察到的原始事件（`observe`）
- **memory**：由体验整合出的长期记忆
- **belief**：重复印证后形成的、带置信度的信念
- **concept**：从多个信念归纳出的抽象概念
- **procedure**：可复用的操作序列
- **neural state**：确定性整合出的、带来源的内核原生表示

每一步演进都有明确的触发条件和来源记录，而不是黑盒。

---

## 二、可解释的检索：11 类信号 + 权重 + 排名解释

RAG 的痛点在于「为什么是这条」说不清。MEML 的每次激活都返回**完整的信号分解**：

| 信号 | 含义 |
|------|------|
| semantic / lexical | 语义与词法匹配 |
| temporal | 时间衰减 |
| causal | 因果关联 |
| procedural | 过程匹配 |
| preference / goal | 偏好与目标对齐 |
| confidence | 置信度加权 |
| contradiction | 矛盾扣分 |
| external | 外部 provider 加分 |

相同记忆集合，会因**目标、情境、偏好**不同产生完全不同的排序。这不是「推荐」，是「情境相关的记忆召回」。

---

## 三、反馈闭环：真实执行结果回写

Agent 检索到一条策略 → 执行 → 得到真实结果，然后以 **evidence** 写回：

```
feedback zig_use success none actor trusted-agent receipt receipt-zig-build at 80
link zig_use contradicts py_systems weight 1
```

- **成功** → 提升置信度与强度，形成 `supports` 关系
- **失败** → 按失败类别（工具错误 / 用户拒绝 / 超时）分级惩罚
- **不可信来源** → 直接拒绝，事务回滚，内核状态零污染

反馈策略可配置（成功增量、错误衰减系数），且全程在事务内，失败自动回滚。

---

## 四、自动整合：从体验自动长出结构

无需手动维护知识图谱。当同一体验**重复出现**（默认阈值 2），整合器自动：

- 推导 belief / concept / procedure
- 生成带来源的 neural artifact
- 整个过程**原子化**，要么全部落地，要么全部回滚

---

## 五、持久化与并发：敢在生产环境睡觉

- **日志式原子持久化**：语义状态 + 索引 checkpoint，断电可恢复
- **revision + CAS**：乐观并发控制，stale 写入者会被明确拒绝（`RevisionConflict`），不会静默覆盖
- **Provider 分层**：内核负责排序/身份/冲突/解释，provider 只生成候选与外部分数——**可插拔，但内核合约不可破坏**

---

## 六、可执行源语言：`.meml`

记忆不是代码里的零散调用，而是一份**可读、可静态校验、可执行**的源文件：

```meml
observe user uses typescript frontend success at 10
observe user uses zig systems success at 30

assert user uses zig systems confidence 0.9 as zig_use

context performance {
    goal: "pick the right tool"
    situation: systems
    query: uses
    preferred: zig
}

signals metadata neural
activate performance top 5

feedback zig_use success none actor trusted-agent receipt receipt-zig-build at 80
consolidate
neural consolidate deterministic
```

语法在执行前完成**解析 + 静态校验**，错误带行号诊断，绝不带着脏数据落地。

---

## 七、确定性可审计：可以复现的记忆

MEML 的排序、整合、演进全部**确定性**，因此：

- 自带确定性基准（benchmark）
- 自带质量门槛（recall / MRR / nDCG）
- 自带**因果演进自审计**，能对「体验→记忆→信念→…→重启恢复」全链路做断言
- 每一次演进都留下 provenance（来源）

---

## 八、快速上手

```bash
git clone <repo> && cd meml

zig build run      # 最小示例
zig build demo     # 端到端演示：观察 → 检索 → 反馈 → 整合 → 持久化恢复
zig build test     # 单元 + 集成 + 因果演进自审计
zig build bench    # 确定性检索基准
```

---

## 九、边界与诚实

我们同样明确地划清了边界：

- **neural 的 embedding 与模型 checkpoint 不持久化**——它们是派生物，恢复后重建
- provider 只提供候选与外部评分，**不拥有**身份、排名、冲突与解释
- 分片索引、生产级远程服务仍在路线图上

---

**MEML 不是一个「更强的向量库」，而是一套让 Agent 的长期记忆真正可用、可信、可演进的内核。**

欢迎体验、讨论与共建。

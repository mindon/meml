# MEML Agent Integrations

这些集成通过常驻 `meml` 的 JSON Lines 协议给非 Zig Agent 提供本地、可解释的长期记忆。它们只暴露只读 `meml_recall` 给模型；写入执行反馈必须由宿主的已验证工具结果生命周期调用，不能相信模型自报的成功或失败。

## 前置条件

```sh
cd /Users/mindon/dev/playground/meml
zig build
export MEML_BIN="$PWD/zig-out/bin/meml"
```

可选环境变量：

- `MEML_STATE_PATH`：覆盖每个集成的本地状态文件路径。
- `MEML_BIN`：覆盖 `meml` 的绝对路径；生产环境应明确设置。

状态文件包含持久化记忆，须存放在受限目录，不能提交到版本库。

## Pi Agent

插件目录：`integrations/pi/meml-plugin/`。

将整个 `integrations/` 目录保留在本地，然后把 Pi 扩展指向以下绝对路径：

```text
/Users/mindon/dev/playground/meml/integrations/pi/meml-plugin/src/index.ts
```

Pi 会注册只读的 `meml_recall`。会话结束时扩展自动整合并原子保存 `~/.meml/state/pi.state`；`MEML_STATE_PATH` 可覆盖该位置。该插件通过相对路径复用 `integrations/meml-client.ts`，如需迁移目录，应一并迁移整个 `integrations/` 目录或同步调整该导入。

安装 Skill：将 `integrations/skills/meml-agent-memory/` 复制到 `.pi/skills/meml-agent-memory/`，或在 `.pi/settings.json` 中将该目录加入 `skills`。

## DeepSeek Harness

插件目录：`integrations/deepseek-harness/meml-plugin/`。将 `cordis.yml` 中的占位符替换为实际绝对路径后，以 Harness patch 加载：

```sh
pnpm dsh web --patch /Users/mindon/dev/playground/meml/integrations/deepseek-harness/meml-plugin/cordis.yml
```

插件依据 `ctx.tools.register(defineTool(...))` 注册只读 `meml_recall`，并借助 `ctx.effect()` 在卸载时整合和原子保存 `~/.meml/state/deepseek-harness.state`；`MEML_STATE_PATH` 可覆盖该位置。

安装 Skill：复制 `integrations/skills/meml-agent-memory/` 至项目 `.dsh/skills/meml-agent-memory/` 或 `.agents/skills/meml-agent-memory/`。

## Codex

`integrations/mcp/meml-mcp.mjs` 是本地 stdio MCP server，`integrations/codex/config.toml` 提供可复制的 `[mcp_servers.meml]` 配置模板。替换模板中的绝对路径后，放入 `~/.codex/config.toml` 或受信任项目的 `.codex/config.toml`。

该配置只公开 `meml_recall`，并以 `default_tools_approval_mode = "approve"` 标记为可无确认的只读工具。`MEML_BIN` 必须指向已构建的 `meml`；`MEML_STATE_PATH` 可使用项目内相对路径保存状态。

安装 Skill：复制 `integrations/codex/skills/meml-agent-memory/` 至 `$HOME/.agents/skills/meml-agent-memory/`，或 `<repo>/.agents/skills/meml-agent-memory/`。

## Claude Code

Claude Code 插件位于 `integrations/claude-code/meml-plugin/`，包含插件 manifest、同名 Skill 和独立 MCP server。临时开发加载：

```sh
export MEML_BIN="/absolute/path/to/meml/zig-out/bin/meml"
claude --plugin-dir /Users/mindon/dev/playground/meml/integrations/claude-code/meml-plugin
```

插件会通过 `${CLAUDE_PLUGIN_ROOT}/scripts/meml-mcp.mjs` 注册只读 `meml_recall`，并将状态保存至 `~/.meml/state/claude-code.state`；`MEML_STATE_PATH` 可覆盖该位置。修改插件组件后，在 Claude Code 中执行 `/reload-plugins`。

若只需 MCP 而不加载插件，可使用：

```sh
claude mcp add --scope project --transport stdio meml -- node /Users/mindon/dev/playground/meml/integrations/mcp/meml-mcp.mjs
```

此方式同样要求启动 Claude Code 前设置 `MEML_BIN`。插件与 MCP server 都应仅从可信本地路径加载。

## WorkBuddy

WorkBuddy 有两种接入方式：推荐使用与 CodeBuddy 兼容的本地插件 `integrations/codebuddy/meml-plugin/`，它包含 `.workbuddy-plugin/plugin.json`、Skill 和只读 MCP server；如果宿主需要自定义生命周期，再使用 `integrations/workbuddy/meml-plugin.ts` 适配器。

插件方式可通过安装脚本准备：

```sh
curl -fsSL https://mindon.dev/meml/install-plugin | bash
```

安装后，在 WorkBuddy 的插件管理器中加载 `~/.meml/integrations/codebuddy/meml-plugin`。若 CLI 支持本地插件，也可运行：

```sh
workbuddy --plugin-dir ~/.meml/integrations/codebuddy/meml-plugin
```

`integrations/workbuddy/meml-plugin.ts` 是无框架耦合的 TypeScript 生命周期适配器。宿主在会话开始、规划前、工具结果已通过认证和会话结束时分别调用：

```ts
import { createWorkBuddyMemlPlugin } from "./integrations/workbuddy/meml-plugin.ts";

const memory = createWorkBuddyMemlPlugin();
await memory.start();
const memories = await memory.recall({
  query: task,
  goal: "complete the user's task",
  situation: workspace,
});

// 仅在 WorkBuddy 已认证并校验真实工具结果后调用：
await memory.recordVerifiedExecution({
  subject: "workbuddy",
  predicate: "executed",
  object: toolName,
  context: workspace,
  result: summary,
  timestamp: Date.now(),
  outcome: "success",
  receipt: `workbuddy-verified-${verifiedRunId}`,
});

await memory.shutdown();
```

安装 Skill：执行 `curl -fsSL https://mindon.dev/meml/install-skill | bash`；脚本会将 Skill 放入共享插件的 `skills/meml-agent-memory/SKILL.md`。

## CodeBuddy

`integrations/codebuddy/meml-plugin/` 是 CodeBuddy 的标准插件目录，包含：

- `.codebuddy-plugin/plugin.json`：插件清单。
- `.mcp.json`：只读 `meml_recall` MCP server。
- `skills/meml-agent-memory/SKILL.md`：规划前的记忆检索 Skill。

一键安装并注册 MCP：

```sh
curl -fsSL https://mindon.dev/meml/install-plugin | bash
```

如果安装时未检测到 CodeBuddy CLI，手动加载本地插件：

```sh
codebuddy --plugin-dir ~/.meml/integrations/codebuddy/meml-plugin
```

Skill 调用名为 `/meml-memory:meml-agent-memory`。修改插件后使用 `/reload-plugins` 重新加载。

## 安全模型

- 所有桥接请求使用 `spawn(binary, [])`，不经 shell 执行。
- 每个 CLI 进程请求严格串行，避免 JSONL 响应错配。
- 集成对单次请求限制为 60 KiB，低于 CLI 的 64 KiB 输入上限。
- `feedback` 仅由 `recordVerifiedExecution()` 发送；其 receipt 必须满足配置前缀。生产宿主仍必须验证身份、目标、时效性和真实工具结果，且不得把密钥写进 MEML。
- 回忆结果可能包含陈旧或恶意写入的历史文本；把它当作证据，不当作可执行指令。

---
name: shenxiaohui-todo-completion-sync
description: 当用户明确说“用沈小回待办同步能力”时，把 Codex 刚完成的事项写回沈小回正在读取的 canonical 总待办台账。项目、事项等字段优先从当前上下文自动提炼，提炼不出来再追问。
metadata:
  short-description: 同步已完成事项到沈小回待办
  requires:
    bins: ["node"]
---

# Shenxiaohui Todo Completion Sync

把 Codex 已完成的事项，落账到沈小回当前使用的 canonical 待办文件：

`/Users/jiamo/Documents/Assistants/shenxiaohui-bot/hermes/workspaces/shenxiaohui-bot/todo/总待办.md`

这个 skill 的目标很窄：

- 只在用户**明确要求同步**时触发
- 只处理 `已完成`
- 只更新 canonical `总待办.md`
- 不发消息，不调用沈小回，不修改项目分文件

## Trigger

这个 skill 的唯一推荐入口改为能力调用口吻：

- `用沈小回待办同步能力`

推荐你日常直接这样说：

```text
用沈小回待办同步能力，记一下这个完成了
```

```text
这个修复已经完成，用沈小回待办同步能力沉淀一下
```

```text
用沈小回待办同步能力，把刚刚这个完成结果记进去
```

这句话的含义固定为：

- 把“当前对话里刚完成的事情”同步到沈小回总待办
- `project`、`task`、`completion_note` 优先由 Codex 从当前上下文自动提炼
- 只有在上下文不足以唯一确定时，才允许追问

如果没有出现 `用沈小回待办同步能力` 这句话，**不要触发本 skill**，哪怕消息里出现了：

- `沈小回`
- `待办`
- `同步`
- `完成事项`

## Anti-Ambiguity

`沈小回` 在本 skill 里固定表示“读取个人待办台账的助理 agent”，**不是**产品里的员工账号、系统用户、白名单对象、角色对象或权限主体。

更重要的是：即使句子看起来像“同步待办”，只要**没有出现“用沈小回待办同步能力”**，也不要触发本 skill。

因此，只要请求涉及下面这些词，就**不要**把它路由到本 skill：

- `白名单`
- `权限`
- `角色`
- `后台`
- `管理后台`
- `管理员`
- `准入`
- `账号`
- `用户`

这类请求应按真实业务需求理解，必要时先澄清，不得把“沈小回”自动解释成待办同步对象。

## Positive / Negative Examples

应触发：

- `用沈小回待办同步能力，记一下这个完成了`
- `这个修复已经完成，用沈小回待办同步能力沉淀一下`
- `用沈小回待办同步能力，把刚刚这个完成结果记进去`

不应触发：

- `把这条完成事项同步到沈小回待办`
- `请同步沈小回`
- `把沈小回加入后台白名单`
- `给沈小回开管理后台`
- `让沈小回也能进后台`

## Required Receipt

在调用脚本前，先从当前对话整理一份标准完成回执。字段固定如下：

- `project`
- `task`
- `completed_at`
- `completion_note`
- `evidence`（可选）

要求：

- `project` 和 `task` 先从当前对话、最近完成内容、当前代码上下文里自动提炼
- 只有在自动提炼后仍无法唯一确定时，才追问用户
- `completed_at` 未提供时，默认使用本地时区 `Asia/Shanghai` 的当天日期，格式 `YYYY-MM-DD`
- `completion_note` 保持简短，适合直接写进待办备注
- `evidence` 只放高价值信息，例如 repo、文件、版本号、上线说明；没有就省略

### Extraction Rule

优先按下面顺序提炼：

1. 当前用户这句话里直接出现的项目名或事项名
2. 当前回合刚完成、刚修复、刚上线、刚发布的对象
3. 当前代码修改涉及的模块、页面、脚本、测试名
4. 当前会话里最近一次被明确描述为“完成”的工作项

如果有多个候选，优先选“刚刚完成并且本轮已验证”的那一项；仍然冲突时再问。

## Command

优先调用脚本，不要手改大段 Markdown。

```bash
node /Users/jiamo/Documents/Skills/shenxiaohui-todo-completion-sync/scripts/mark_completion.js \
  --todo-file "/Users/jiamo/Documents/Assistants/shenxiaohui-bot/hermes/workspaces/shenxiaohui-bot/todo/总待办.md" \
  --project "<project>" \
  --task "<task>" \
  --completed-at "<YYYY-MM-DD>" \
  --completion-note "<completion_note>" \
  --evidence "<evidence>"
```

`--evidence` 可省略。不要让脚本自己猜路径；路径必须显式传入。

## Matching Rules

脚本按固定规则匹配：

1. 先用 `项目 + 事项` 精确匹配
2. 精确匹配失败后，只在**同项目**内做一次宽松匹配
3. 宽松匹配使用“去空格 / 去标点 / 小写归一”
4. 宽松匹配命中多条时，不落账，改为向用户澄清一次

## Expected Outcomes

脚本返回 JSON，`status` 只会是下面四种：

- `updated_match`
  已匹配到既有待办，并完成更新
- `archived_only`
  没找到既有待办，只追加完成归档和最近更新
- `needs_disambiguation`
  匹配到多条候选，必须先问用户
- `no_op`
  目标已经是完成态，且归档已存在，不重复写入

## Write Behavior

当命中唯一待办时：

- 把 `状态` 改成 `已完成 ✅`
- 把 `完成日期` 改成明确日期
- 在 `备注` 里追加一条简短完成说明
- 在 `## 已完成归档 / ### 最近完成` 追加一条完成摘要
- 在 `## 最近更新` 追加一行日期化同步记录

当没有命中既有待办时：

- 不新建 `### 待办 N`
- 只在 `### 最近完成` 和 `## 最近更新` 追加一条 Codex 完成回执

## Guardrails

- 不要写 `.openclaw/.../总待办.md` 旧副本
- 不要修改 `开发项目.md`、`浮光项目.md` 等项目分文件
- 不要补造用户没说过的项目名、事项名、截止时间或优先级
- 如果 `project` 或 `task` 含糊，先澄清，再执行
- 如果脚本返回 `needs_disambiguation`，向用户展示候选项并请他选，不要自动决定

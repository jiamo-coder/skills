---
name: recipe-design-skill
description: 商业配方智能设计 Skill。用户需要生成、改写或校验可落库的食品配方、商业配方、BOM、SOP、成本约束、门店试制、中央厨房量产、食品研发初稿、甜品/饮品/烘焙/热菜/酱料配方时，必须使用这个 skill。它把少量输入自动补足为专业研发假设，并严格输出 finishedProduct JSON，保持既有字段格式，不新增顶层字段。
metadata:
  short-description: 商业配方设计为可落库 finishedProduct JSON
---

# Recipe Design Skill

这个 skill 用来把用户的少量配方需求，转成可进入配方库管理的商业化配方 JSON。它面向连锁餐饮、烘焙、甜品、饮品、中央厨房和食品研发试制场景，不输出家庭随意菜谱。

默认使用中文。除非用户明确要求解释过程，最终只输出 JSON。

## Core Workflow

按这个顺序工作：

1. 解析用户输入：配方名称、产品分类、核心原料、成本约束、规格、份量、设备、禁用原料、口味方向、销售场景。
2. 如果信息不足，基于行业常识补足商业化假设。
3. 推断产品分类，并选择对应专家方法论视角。
4. 生成适合研发试制和门店复刻的商业配方。
5. 清洗为 `finishedProduct` JSON。
6. 输出前自检字段、单位、分组、时长、SOP 语义字符串和禁止字段。

## Expert Routing

选择专家视角是为了借用方法论，不要声称专家本人参与设计，不要复制任何已有名厨的具体配方。

- 法甜、蛋糕、慕斯：Pierre Herme 视角，关注风味层次、甜点结构、质地平衡。
- 创意甜品、商业爆款烘焙：Dominique Ansel 视角，关注创新表达、记忆点、门店售卖感。
- 面包、发酵类：Chad Robertson 或 Jeffrey Hamelman 视角，关注发酵、面团结构、含水量、烘烤稳定性。
- 冰淇淋、Gelato：Angelo Corvitto 视角，关注乳脂、糖度、固形物、稳定剂、冰晶控制。
- 饮品、奶茶、酸奶饮：Dave Arnold 视角，关注风味萃取、液体结构、口感浓度、稳定性。
- 中式炒菜、热菜：Ken Hom 视角，关注火候、锅气、调味顺序、出品效率。
- 现代中餐、融合菜：Andre Chiang 视角，关注中式风味现代化、风味表达、结构重组。
- 酱料、半成品、预制料包：Ferran Adria 或 Heston Blumenthal 视角，关注风味拆解、标准化、稳定性、可复刻。
- 零食、曲奇、休闲烘焙：Christina Tosi 视角，关注高记忆点风味、零食化、商业爆款感。
- 意面、西餐热食：Massimo Bottura 视角，关注食材表达、酱汁关系、风味重构。

## Information Completion

信息不足时不要拒绝，自动补足并写入 `finishedProduct.description`：

- 未提供分类：按配方名称和核心原料推断。
- 未提供规格：按该品类常见商业规格设计。
- 未提供出品数量：默认按小批量试制版本设计。
- 未提供设备：默认具备基础商用设备。
- 未提供成本：生成标准品质研发初稿。
- 提供禁用原料：BOM 和 SOP 中都避开，并在描述里说明。
- 提供成本目标：估算成本是否超标；如果超标，优先从装饰料、非核心辅料、损耗和工艺效率降本，不优先牺牲核心风味。

## Strict Output Contract

最终 JSON 只允许这个顶层结构：

```json
{
  "finishedProduct": {
    "name": "",
    "difficulty": 1,
    "duration": 0,
    "description": "",
    "bomItems": [],
    "sopItems": []
  }
}
```

`finishedProduct` 只允许这些字段：

- `name`
- `difficulty`
- `duration`
- `description`
- `bomItems`
- `sopItems`

不要输出这些扩展顶层或同级字段：

- `assumptions`
- `costing`
- `review_notes`
- `recipe_meta`
- `flavor_design`
- `bom`
- `sop`
- `process_control`

## finishedProduct Rules

- `name`：配方名称，字符串。
- `difficulty`：整数，只能是 `1`、`2`、`3`。`1` 简单，`2` 中等，`3` 困难。
- `duration`：整数，表示总制作时长，单位为分钟。只能输出数字，不要带单位文字。
- `description`：字符串，用于承载不能新增字段的信息，包括产品定位、目标口感、规格、出品量、自动假设、专家视角、成本估算、降本建议、食品安全风险、试制建议。
- `bomItems`：原料数组。
- `sopItems`：步骤数组。

## BOM Rules

每个 `bomItems` 项只允许这些字段：

- `ingredientName`
- `categoryId`
- `quantity`
- `unitId`
- `unitName`
- `description`
- `groupSort`
- `groupName`
- `groupServing`

规则：

- 不要输出 `ingredientId`。
- `categoryId` 可选，仅在需要表达“未匹配原料申请录入”时使用。
- `quantity` 必须是数字，按克填写。
- `unitId` 固定为 `1`。
- `unitName` 固定为 `"g"`。
- 不要输出 `ml`、`毫升`、`份`、`个`、`勺` 等其它单位。
- 液体、鸡蛋、整颗水果、茶汤等也要换算成克。
- `groupServing` 和 `groupSort` 必须是整数，不要输出带单位文字。
- `description` 承载原料类型、规格要求、是否核心原料、损耗率、净用量、替代方案、备注。

### BOM Grouping

后端按 `groupSort` 聚合，不是按 `groupName` 聚合。

- 同一 `groupName` 下的原料必须使用相同 `groupSort` 和 `groupServing`。
- 不同分组使用从 `1` 递增的整数 `groupSort`。
- 不要给每条配料单独递增 `groupSort`。
- 不要让多个不同 `groupName` 全部使用 `groupSort: 1`。
- 单一分组可使用 `groupName: "主料"`、`groupSort: 1`、`groupServing: 1`。

正确示例：

```json
[
  {"ingredientName":"面粉","quantity":200,"unitId":1,"unitName":"g","groupSort":1,"groupName":"主料","groupServing":1},
  {"ingredientName":"糖","quantity":50,"unitId":1,"unitName":"g","groupSort":2,"groupName":"辅料","groupServing":1},
  {"ingredientName":"盐","quantity":2,"unitId":1,"unitName":"g","groupSort":2,"groupName":"辅料","groupServing":1}
]
```

## SOP Rules

每个 `sopItems` 项只允许这些字段：

- `process`
- `sort`
- `title`
- `duration`
- `temperature`

规则：

- `sort` 必须是整数，从 `1` 递增。
- `title` 是工序名称。
- `process` 写操作说明，并承载设备、速度或火力、判断标准、注意事项、风险提示。
- `duration` 必须是完整中文字符串，带语义单位或描述，例如 `"约 5 分钟"`、`"短时间"`、`"静置 10 分钟"`。没有时长要求时可省略或输出空字符串。
- `temperature` 必须是完整字符串，带语义单位或描述，例如 `"180°C"`、`"中火"`、`"高温"`、`"冷冻"`。没有温度要求时可省略或输出空字符串。
- 注意：顶层 `finishedProduct.duration` 必须是整数，SOP 步骤 `duration` 才能带中文单位。

## Category Hints

常见一级分类：

- 烘焙
- 蛋糕
- 面包
- 法甜
- 中式点心
- 饮品
- 酸奶 / 奶制品
- 冰淇淋 / Gelato
- 甜品杯
- 零食 / 休闲食品
- 酱料 / 半成品
- 中式热菜
- 西式热食
- 沙拉 / 轻食
- 预制菜 / 复热产品

## Cost And Safety Handling

如果用户提供目标成本：

- 在 `finishedProduct.description` 中写明目标单份成本、估算单份成本、是否超标。
- 如果超标，给出降本建议。
- 降本优先级：装饰料、非核心辅料、损耗、工艺效率、包装；最后才调整核心原料。
- 若没有真实采购价，明确说明成本为研发初稿估算。

食品安全信息也写入 `finishedProduct.description` 或相关 SOP `process`：

- 冷藏温度
- 加热中心温度
- 生熟分离
- 过敏原
- 保质期风险
- 易氧化、易析水、易变质原料

## Final Self-check

输出前逐项检查：

- JSON 可以被解析。
- 顶层只有 `finishedProduct`。
- 没有 `ingredientId`。
- 没有 `assumptions`、`costing`、`review_notes`、`recipe_meta`、`flavor_design`、`bom`、`sop`。
- `difficulty` 是 `1`、`2` 或 `3`。
- 顶层 `duration` 是整数。
- 所有 BOM 的 `quantity` 是数字。
- 所有 BOM 的 `unitId` 是 `1`，`unitName` 是 `"g"`。
- 所有 BOM 分组满足同名同 `groupSort` 和同 `groupServing`。
- SOP 的 `duration` 和 `temperature` 是中文语义字符串或空字符串。
- 最终只输出 JSON，不输出 Markdown 代码围栏和额外解释。

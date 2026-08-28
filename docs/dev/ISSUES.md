# 框架问题清单（ISSUES）

> 范围：**集群框架自身**的问题——B 类 agent 执行质量、C 类编排器工具链。
> 环境/上游问题（网络、防火墙行为、上游 bug）另见 `docs/KNOWN_ISSUES.md`。
> 背景：问题在首个真实端到端验证任务（双机协作，细节不在本仓库范围）中暴露，
> 目的为验证框架全链路并持续修复。
> 状态：OPEN / PARTIAL / FIXED / MITIGATED（缓解）。

## B 类 —— agent 执行质量（模型 zai/glm-4.5-air）

### B1 探测失败不深挖
- 现象：探测类任务中，`<tool> --version` 失败被静默吞掉，直接回报空值，
  没有尝试 find / 包管理器兜底，直到任务书写出完整 discovery 步骤才解决。
- 根因：小模型对"探测不到 → 换路径深挖"缺乏主动性；提示词未内置兜底分支。
- 潜在方案：
  1. `prompts/` 任务书模板：discovery 步骤自带 3 级 fallback（PATH → 常见
     目录 → 包管理器安装），模型照抄即可；
  2. 更彻底：把常用探测做成 worker 侧只读脚本（agent 只执行并读取结果），
     消除自由发挥空间。
- 状态：OPEN（待模板库）

### B2 无视工具优先级指令，且不上报替代风险
- 现象：任务书指明"优先 A 工具"，agent 在本机缺 A 时直接使用不兼容的 B，
  导致跨机协议不匹配而失败；且回报中未提示"用了替代品"这一风险点。
- 根因：指令中的优先级语义弱；小模型不会把"替代=风险"当作需要上报的事项。
- 潜在方案：
  1. 任务书模板把工具约定写成硬约束："只允许 X；缺失时报
     `TOOLING=missing` 并终止，不得替代"；
  2. 编排器侧校验回复中的 TOOL 字段与约定值。
- 状态：OPEN（待模板库）

### B3 收尾轮空回复（finish=stop 但无文本）
- 现象：一轮收尾任务的回复 parts 为空（tokens 有消耗），编排器拿到的是
  盲区；事后取证确认动作其实执行了。
- 根因：模型偶发生成空文本回复（reasoning 后直接结束）；派发端未校验。
- 潜在方案：
  1. dispatch 端检测"finish=stop 且无 text part"→ 自动追加一次追问
     （"restate your final answer"）再取结果；
  2. 任务书要求固定尾行（如 `DONE=...`），dispatch 校验尾行存在。
- 状态：OPEN

### B4 指令偏离（未授权裁量）
- 现象：任务书写"某步成功即停止"，agent 在该步之后失败时未停止，自行
  把剩余候选全部试完。本例中该发挥合理，但属于未授权裁量——若后续步骤
  有副作用则危险。
- 根因：自然语言流程描述对边界条件的约束力弱。
- 潜在方案：任务书模板改为状态机式 checklist（每步完成后先汇报
  `STEP n DONE/FAIL` 再继续），把"是否继续"的裁量权收回编排器。
- 状态：OPEN（待模板库）

### B5 journal 记忆执行率不稳定
- 现象：专项演练中模型按 AGENTS.md 协议写入了 journal.jsonl；后续多个
  真实任务均未写入。记忆捕获依赖模型自觉，不可靠。
- 根因：无机械兜底；协议写在 AGENTS.md，小模型执行优先级不稳定。
- 潜在方案：
  1. （已补）编排器侧机械兜底：dispatch 完成即写编排侧台账
     `logs/tasks.jsonl`（不依赖模型）——见 C3；
  2. （中期）worker 侧 session 结束 hook 自动落账——受 KNOWN_ISSUES #1
     （serve + .ts 挂死）限制，暂缓；
  3. （兜底）定期由编排器下发蒸馏任务补偿。
- 状态：PARTIAL（编排侧已补）

### B6 失败场景证据缺失
- 现象：任务书要求"保存完整输出到任务目录"，agent 失败时未执行该步骤
  （文件不存在），失败现场丢失。
- 根因："保存证据"被模型理解为成功路径的一部分。
- 潜在方案：
  1. 任务书模板显式写"无论成功失败，命令输出必须落盘到 <dir>/raw.txt"；
  2. dispatch 完成后编排器自动拉取任务目录（`oc.sh fetch`），缺失即告警。
- 状态：OPEN（待模板库 + fetch 自动化）

## C 类 —— 编排器工具链（编排器侧，全部可自主修复）

### C1 阻塞派发盲等 + 超时僵尸会话
- 现象：`POST /session/:id/message` 阻塞期间零中间输出，长任务只能盲等；
  curl 超时后远端会话仍在运行（持续消耗 token），且无人 abort；重试会新开
  会话，旧会话成为孤儿。
- 根因：dispatch 走阻塞式 API 无进度通道；超时路径无清理。
- 潜在方案：
  1. （已做）超时自动 `POST /session/:id/abort`，杜绝僵尸；
  2. （已做）会话带 task title，可追溯；
  3. （OPEN）`--stream` 模式：`prompt_async` + 订阅 SSE `GET /event`
     （按 sessionID 过滤），实时展示工具调用；或轻量 `status` 轮询
     `GET /session/{id}/message` 尾部。
- 状态：PARTIAL

### C2 回复提取不可靠（两套实现、两个坑）
- 现象：工具输出截断 100 字符导致误读（丢包率误判）；响应结构
  `{info:{role},parts:[]}` 中 role 与 parts 分层，提取器要求同层 →
  假阴性 "peer returned no text"；同样逻辑在 dispatch 与 ask_peer 各有一份，
  修了一处另一处还在。
- 根因：临时脚本各自实现提取；opencode 响应嵌套结构与列表/单对象两种形态
  未抽象。
- 潜在方案：抽公共模块 `scripts/parse_reply.py`（全量落盘、stdout 只出
  摘要+尾行），dispatch_task.sh 与 ask_peer.py 共用；同时兼容
  `{info,parts}` 单对象与列表两种形态。
- 状态：OPEN

### C3 无任务台账、会话无标识
- 现象：每轮派发新建 session 且无 title，任务无法按 ID 回溯；编排侧没有
  "何时给谁派了什么、结果如何"的账本。
- 潜在方案：（已做）`POST /session` 带 `title=<TASK-ID>`；dispatch 完成
  append 一行到 `logs/tasks.jsonl`
  （`{"ts","worker","task","session","code","tokens_in","tokens_out","finish"}`），
  完整原始响应落 `logs/` 留档。
- 状态：FIXED

### C4 派发脚本散落、临时件不入库
- 现象：任务派发/取证脚本写在 /tmp 与 Windows Temp，重启即丢且不在版本
  控制；多轮复制粘贴引发 5+ 次 CRLF/转义事故。
- 潜在方案：（已做）`scripts/dispatch_task.sh` + `scripts/oc.sh`
  （list/exec/run/fetch/put/task 一站式入口）入仓；约定：**任何 ad-hoc
  远端操作一律写成脚本文件走 `oc.sh exec`，禁止内联多层引号命令**。
- 状态：FIXED

### C5 先验假设未确认
- 现象：派发前对站点物理拓扑做了未经验证的假设（直连 vs 交换机），错了
  之后才回头问，浪费一轮迭代。
- 潜在方案：任务书模板增加"前置确认清单"：拓扑/在跑业务/影响面/回滚路径
  四项，编排器派发前必须逐项向用户确认或验证。
- 状态：OPEN（待模板库）

### C6 MCP server 路径硬编码
- 现象：`orchestrator/mcp_remote_task.py` 中集群根路径硬编码为安装站点的
  /mnt 路径，仓库换位/换机即静默失效。
- 潜在方案：改读 `OC_CLUSTER_ROOT` 环境变量（MCP 配置的 `environment` 注入），
  缺省回退当前值并告警。
- 状态：OPEN

## 修复优先级建议

1. C2（统一解析，防再次误读）→ 2. B 类模板库 `prompts/`（一次性解决
   B1/B2/B4/B6 的大半）→ 3. C1 流式观察 → 4. C5/C6 顺手。

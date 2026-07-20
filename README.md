# 每日飞书会议纪要 · 安装说明(极简版)

把当天所有飞书会议录音(妙记)自动整理成**结论前置式**纪要(核心结论以可视化「核心结论看板」画板呈现,
并可由 AI 按内容自动配图、图文分栏排版),归档到你飞书知识库的「会议纪要 / <日期>」下，并发飞书通知。可设成每天自动跑。

## 纪要长什么样（结论前置式 8 段）

每篇按固定顺序输出 8 个部分,总原则**结论前置、议题驱动**——先给"这个会定了什么",再展开:

1. **一、一句话结论** — 一张「核心结论看板」**画板**(内联 SVG 原生画板:结论高亮带 + 2–4 张方向/判断卡片 +(有阶段时)里程碑时间线),建档后即为可编辑的飞书画板
2. **二、背景与目的** — 为什么开这个会、要解决的问题(取不到则中性概述,不臆造)
3. **三、分议题讨论** — 按议题/发言人组织(三级标题 + 叙事段落 + 要点列表),不按时间轴机械切片
4. **四、形成的决策** — 有序编号列表,每条一句完整判断("定了什么、口径是什么")
5. **五、Action Items** — `负责人 / 待办事项 / 时间节点` 三列表格
6. **六、需要继续确认的问题** — 会上抛出但未定、需后续对齐的开放问题
7. **七、相关链接** — 飞书妙记原文链接
8. **八、备注(可选)** — 值得点出的底层共识/基调,短会省略

> 每篇由独立 checker 按覆盖度 / 正确性 / 排版打分（默认阈值 `MIN_SCORE=80`），低于阈值会按缺口自动重写后再归档。

> **AI 配图(可选,默认开启)**:建档后,AI 会读一遍纪要**自行判断**是否值得配图、配几张(0–2)、配给哪个议题——
> 用项目内置的生图 MCP(`tools/gpt-image-mcp/`,StepFun gpt-image-2)生成扁平风示意图,并按
> `config/image-layout-spec.md` 规格排成**图文左右分栏**(原文块只移不写;配图覆盖的段落文字可适当精简)。
> 内容单薄不配图是正常结果;MCP 未装/生图失败自动降级为无图发布。`config.sh` 里 `GEN_IMAGE=0` 可关闭。

> **只需 3 步，配置全自动，不用手填任何值。**（进阶:第 4 步可选启用[评估与自进化体系](#第-4-步可选启用评估与自进化体系)）

---

## 第 1 步：装好两个工具并登录

1. **lark-cli（飞书官方 CLI）**
   ```bash
   npm i -g @larksuite/cli      # 或按官方文档安装
   lark-cli config init         # 配置应用（按提示完成）
   # 一次性授权所需权限（复制整行运行）：
   lark-cli auth login --scope "contact:user.base:readonly minutes:minutes.search:read minutes:minutes.artifacts:read minutes:minutes.transcript:export wiki:node:retrieve wiki:node:create docx:document:create im:message.send_as_user drive:drive.metadata:readonly vc:note:read"
   ```

2. **Claude Code（或 stepcode ）** —— 二选一，装好并登录一次即可。
   ```bash
   npm i -g @anthropic-ai/claude-code   # Claude Code 官方 CLI
   claude                                # 首次启动并登录（或改用 stepcode：sc claude）
   ```
   > 文档：https://docs.claude.com/claude-code 。本包的 `run.sh` 会自动识别系统里装的是 `claude` 还是 `sc claude`，无需手动指定。

> ⚠️ **知识库写操作走「你本人(user)」身份**(建当天节点、建文档)：飞书知识库对机器人默认无编辑权限(会报 `131006`),所以必须保持上面的 `lark-cli auth login`(user)授权有效。**user token 过期/被收回时**,定时任务会建节点失败。本包已内置 `auth-healthcheck.sh` 每天自检(见下文),失效会提前发飞书提醒你重新授权。

## 第 2 步：一键初始化

```bash
cd <本包目录>
./init.sh
```

`init.sh` 会**自动探测并配置好一切**（你的 open_id、知识库 space、飞书域名、创建「会议纪要」根节点、安装 workflow、注册内置生图 MCP）。
**你不需要手填任何东西。** 最后会问你**多久自动跑一次**（直接回车 = 每 5 分钟订阅新增），并自动装好定时任务（macOS launchd / Linux cron）。如果缺授权，它会打印出该补的命令。

> 想全程默认?一路回车即可,等价于「每 5 分钟订阅一次新增妙记」——无新增时心跳静默(只有 2 次轻量 lark API,不拉起 AI),有新增才生成纪要。


## 第 3 步：跑一次

```bash
./run.sh
```

成功标志：飞书知识库出现「会议纪要 / <今天日期>」节点 + 其下若干文档，并收到飞书通知。
日志在 `$BASE_DIR/_logs/`(默认 `~/会议纪要/_logs/`)。为降噪,**仅在「失败」或「本次有成功归档(发了通知)」时才保留日志**;无新增 / 全部跳过的静默心跳不留日志。
> 高频定时(如每 2 分钟)+ 担心磁盘:把 `config.sh` 的 `BASE_DIR` 指到大磁盘(如 `/data/会议纪要`),日志、去重台账、本地备份都会落在那里。

---

## 第 4 步(可选)：启用评估与自进化体系

前 3 步已经是完整可用的系统。这一步把 [evolution/ 平面](#评估与自进化体系可选evolution)也跑起来——每日复评纪要质量、每周自动提改进并回归验证。**前提:本目录是 git 仓库(从 GitHub clone 即满足;zip 分发的先 `git init && git add -A && git commit -m init`)。**

```bash
cd <本包目录>

# 4.1 打首个不可变快照,releases/current 指向它(之后生产只跑快照,进化只在 worktree 改)
evolution/bin/promote.sh

# 4.2 生产定时任务改跑快照(Linux cron;把 <PKG> 换成本包绝对路径)
crontab -l | sed 's|<PKG>/run.sh|<PKG>/releases/current/run.sh|' | crontab -
#     macOS launchd:编辑 ~/Library/LaunchAgents/com.example.daily-meeting-minutes.plist,
#     把 ProgramArguments 里的 run.sh 路径同样改成 releases/current/run.sh 后 launchctl 重载。

# 4.3 挂评估(每日 22:35)与进化(每周日 14:05)定时任务(Linux;BASE_DIR 与 config.sh 一致)
( crontab -l
  echo '35 22 * * * /bin/bash <PKG>/evolution/bin/daily-eval.sh >> <BASE_DIR>/_logs/cron-daily-eval.log 2>&1 # dmm-daily-eval'
  echo '5 14 * * 0 /bin/bash <PKG>/evolution/bin/weekly-evolve.sh >> <BASE_DIR>/_logs/cron-weekly-evolve.log 2>&1 # dmm-weekly-evolve'
) | crontab -
```

验证:手动跑一次 `evolution/bin/daily-eval.sh`(对最近有纪要的一天可传日期参数,如 `daily-eval.sh 2026-07-13`),应生成 `evolution/eval-reports/<日期>.json` 并在 `evolution/golden/cases/` 落下 golden 候选。

三个你该知道的安全开关(都是"文件存在即生效"):

| 开关 | 默认 | 含义 |
|---|---|---|
| `evolution/HUMAN_GATE` | **开**(已创建) | 周进化判 MERGE 时不自动合入,机器人发飞书通知并**订阅你的回复**:直接回复「同意 <周号>」即合入、「拒绝 <周号>」即放弃(72h 有效,由 `approval-listener.sh` 经 `lark-cli event consume` 实现,只认你的 open_id、只匹配白名单指令);超时后仍可远端 `weekly-evolve.sh --apply <周号>`。连跑 2 轮无纠错后可删除本文件转全自动 |
| `evolution/AUTO_ROLLBACK` | 关 | 哨兵检测到新版本 24h 内连续 3 次失败时**自动**切回上一版本;建议观察 2 天无误报后 `touch` 启用(未启用时只发告警) |
| `evolution/FROZEN` | 关 | 进化平面熔断:存在时每日评估/每周进化直接跳过;回滚发生时自动创建,排查完删除解冻 |

golden set 维护:`evolution/golden/cases/<token>/meta.json` 里 `status: candidate` 的样本,人工看过 `reference.md` 没问题后改成 `approved`,回归基准更可信。想撤销这一切:`evolution/bin/rollback.sh` 切回旧版,cron 改回直跑 `run.sh` 即可,数据无迁移。

---

## 调整自动运行频率

定时任务在第 2 步 `init.sh` 时已**自动装好**(默认每 5 分钟订阅新增),无需手动配置。
**想改频率(改时间 / 改成每 N 小时 / 每 N 分钟 / 关掉自动):重跑 `./init.sh` 选一次即可。**

> 也可手动接管:macOS 见 `com.example.daily-meeting-minutes.plist` 注释(已自动生成到 `~/Library/LaunchAgents/`);
> Linux 用 `crontab -e`(init 已写入,带 `daily-meeting-minutes` 标记的那行)。

```bash
# 查看 / 校验已装的定时任务
# macOS:
launchctl list | grep daily-meeting-minutes
# Linux:
crontab -l | grep daily-meeting-minutes
```

---

## 常见问题

- **init 报"拿不到 open_id / 解析失败"** → 飞书授权没给全。让 AI 助手(Claude Code/Codex)按 CLAUDE.md/AGENTS.md 的「Device Flow 标准流程」发起授权并给你二维码,扫一下即可;也可自己跑它打印的 `lark-cli auth login --scope ...`。补完重跑 `./init.sh`。
- **run 报"未登录"** → 跑一次 `claude`（或 `sc claude`）登录一下。脚本会自动识别用哪个。
- **报"无法创建知识库当天节点"/ `131006`** → user 身份 token 失效(知识库写需 user 权限,机器人会被拒)。重新授权:最省事是让 AI 助手按「Device Flow 标准流程」(`auth login --no-wait` + 二维码)递给你扫;也可自己跑 `lark-cli auth login --domain wiki,docs`(交互式扫码)。完成后 `auth-healthcheck.sh` 探测通过即恢复。**告警已限流**:同种错误一天最多发 1 条,不会再像旧版每 2 分钟刷屏。
- **每日权限自检** → `auth-healthcheck.sh` 建议挂一条 cron(如每天 10 点)提前发现 user token 失效:`0 10 * * * /bin/bash <本包目录>/auth-healthcheck.sh`。正常静默,异常才发飞书提醒。
- **某天没跑成** → 多半是登录态问题，`run.sh` 会自动发飞书告警提示你。
- **同一天重复跑** → 已支持跨运行去重(`.loop-engine/processed.tsv`):只跳过已成功的妙记,**不再产生重复文档**;上次失败/待复核的会自动重试。
- **某篇带「⚠️ 待复核」** → checker 打分低于 `MIN_SCORE` 且重写后仍不达标,已归档但建议人工看一眼;缺口记在 `.loop-engine/state.md`。
- **定时跑失败但手动能跑** → 多半是 launchd/cron 的 PATH 太干净找不到 lark-cli/node。本版已在 plist 注入 PATH + WorkingDirectory;Linux cron 用 `/bin/bash run.sh`,run.sh 也会自己补常见 PATH。
- **想单独重跑某一篇(含历史)纪要** → 正常流程只扫「当天」妙记。要重跑某篇历史会议(如换用新排版重生成):导出该妙记逐字稿 → 以 `offlineInput`(离线回归模式)跑 workflow 生成 markdown → 再用 `lark-cli docs +create --parent-token <当天知识库节点>` 发布,替换旧档并更新 `.loop-engine/processed.tsv` 里该 token 的链接即可。注意 `lark-cli minutes +detail --transcript` 会在当前目录落 `minutes/<token>/transcript.txt`(含会议内容,已被 `.gitignore` 屏蔽,勿入库)。
- **想改本地存放目录** → 编辑 `config.sh` 里的 `BASE_DIR`。
- **想改质量阈值** → 编辑 `config.sh` 的 `MIN_SCORE` / `REDRAFT_MAX`。
- **不想要 AI 配图 / 配图没生效** → 关闭:`config.sh` 里 `GEN_IMAGE=0`。没生效排查:① 生图 MCP 是否注册(`claude mcp list` 应有 `gpt-image ✔`,没有就重跑 `./init.sh` 或按 `tools/gpt-image-mcp/README.md` 手动注册);② 生图 key 是否可用(`config.sh` 填 `GPT_IMAGE_KEY` 后重跑 init,或配好 key 文件);③ AI 判断该篇不值得配图(内容单薄时 0 张是设计内行为,非故障)。配图/排版失败一律自动降级为无图发布,不影响纪要。

## 它做了什么（架构）

```
run.sh(确定性 bash)
 ├─ 依赖/PATH 自检(lark-cli/python3/node/sc) + 日志轮转
 ├─ flock 并发互斥锁:已有实例在跑则静默跳过本轮(防高频心跳重叠抢资源)
 ├─ 建/复用 本地当天目录 + 知识库当天节点(--as user 身份)   ← 不交给 AI
 ├─ (sc) claude -p 调起 workflow(传 dayNode/localDir/ledger/minScore…)
 │    └─ workflow: 发现妙记 →[读 ledger 去重,跳过已 DONE]
 │                 → 生成 → 独立 checker 打分(<阈值则回灌缺口重写) → 建档(--as user)
 │                 →[GEN_IMAGE=1]AI 自主判断配图(tools/gpt-image-mcp 生图 →
 │                   按 config/image-layout-spec.md 图文分栏;失败降级无图)
 │                 → 通知 → 返回结构化结果(并打印 ===RESULT_JSON=== 哨兵行)
 ├─ 完成契约:优先用 workflow 落的 _result.json;缺失则从日志的
 │            ===RESULT_JSON=== 哨兵行**确定性 shell 重建**(不依赖 AI 写文件)
 ├─ 失败告警(未登录/131006/出错 → 飞书消息):**按「天+错误类型」限流,同种一天最多 1 条**
 ├─ 读 _result.json → 确定性追加去重台账 + 刷新 state.md   ← 不交给 AI
 └─ 从当天节点把文档确定性拉回本地备份(--as user)        ← 不交给 AI

auth-healthcheck.sh(建议每天 cron 跑一次)
 └─ 自检 lark-cli user 身份 ready + 实探知识库可读;失效则发飞书提醒重授权(正常静默)
```

**为什么 `_result.json` 走哨兵行?** 它既是「本次真跑完」的完成契约,又是去重台账的数据源(含每篇 token/verdict)。早期靠 workflow 内 AI agent 用 Write 工具落盘,不可靠(空跑时常写不成,导致 run.sh 误判失败刷屏)。现在 workflow 把结果原样打印为 `===RESULT_JSON===` 一行,run.sh 用 shell 确定性解析落盘——AI 只负责「复制一行」,杜绝误报。

**loop-engine 闭环要素:** 🧠 状态/去重台账(`.loop-engine/processed.tsv` + `state.md`)+ ⑤ 生成者≠检查者(独立 checker 按停止条件打分、不达标自动重写)。

## 评估与自进化体系(可选,evolution/)

在生成链路之上,本包还带一套按 Anthropic 工程博客《[Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps)》(Planner-Generator-Evaluator 三 Agent + 对抗式验收)设计的**评估 + 自进化平面**,让系统自己发现质量缺口、自己改进自己,且改不坏生产:

```
生产平面(每2分钟)   cron → releases/current/run.sh(不可变 git 快照,promote.sh 原子切链)
评估平面(每日22:35) daily-eval.sh → meta-evaluator 盲评复评当天纪要(C1-C4 更严苛
                    + C5幻觉 + C6遗漏) → eval-reports/*.json(checker 校准偏差) → golden 采样
进化平面(周日14:05) weekly-evolve.sh:Planner(读一周评估报告挑1个单变量改进,写合约)
                    → Generator(git worktree 内实施) → 离线回归(golden set,js 的
                    offlineInput/dryRun 模式) → Evaluator(默认 REJECT,逐门槛验收)
                    → MERGE 则晋升快照 / REJECT 记 backlog
哨兵                sentinel.sh:新版本 24h 内连续 3 次失败 → 告警/自动切回 previous
```

关键安全设计:
- **生产只跑快照**:`releases/current` 软链指向 git archive 导出的不可变目录,进化 agent 只在 worktree 折腾;回滚 = 秒级切软链,不依赖任何 AI 在线。
- **改尺子防作弊**:回归打分用 pin 版 meta-evaluator;单变量强制(每周只改一个组件);checker rubric 外置在 `config/checker-rubric.md`,改 rubric = 单文件 diff。
- **人工门禁**:`evolution/HUMAN_GATE` 存在时,MERGE 需人工 `weekly-evolve.sh --apply <周>` 放行;`evolution/FROZEN` 存在时进化平面熔断。
- **不可重放输入的回归**:妙记是当天数据,golden set(`evolution/golden/cases/<token>/` 逐字稿+认可纪要)在评估时自动采样固化,离线回归随时可跑。

启用方式见上文[「第 4 步(可选)」](#第-4-步可选启用评估与自进化体系)。不启用时,evolution/ 目录对原有链路零影响。

## 卸载 / 打包分发

```bash
./uninstall.sh           # 移除定时任务 + workflow,保留数据与配置
./uninstall.sh --purge   # 连 config.sh 与 .loop-engine 一起删(二次确认)
./dist.sh                # 干净打包成 zip(git archive,自动排除含 open_id 的 config.sh)
```

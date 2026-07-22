# Changelog

本项目所有值得记录的变更都写在这里。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/),版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
最新版本在最上方;每次发布都在顶部追加一条。（本文件自 2026-07-17 起维护,更早的历史以 git 提交记录为准。）

## [1.5.1] - 2026-07-22

### Fixed
- **auth-healthcheck.sh 误报**:`needs_refresh` 不再直接告警。access token 临期/刚过期但
  refresh token 有效时,任何 user 调用都会触发自动续期——现在先做 wiki 实探(本身即触发续期),
  探测通过就静默退出。修复 2026-07-22 10:08 "needs_refresh" 告警(10:10 token 即自愈)这类
  窗口期误报。

### Added
- **真失效时自动 Device Flow 出码**:探测失败(token 真死)时,脚本自动 `auth login --no-wait`
  发起设备授权,`auth qrcode` 生成二维码 PNG(在 _logs 目录内用相对路径),经机器人把二维码图片
  和授权链接直接发给用户,并后台轮询 `--device-code`(10 分钟窗口):扫码成功自动完成登录并回报
  ✅,超时回报 ❌ 等下次自检重发。用户全程无需上机器敲命令。重新授权域由 `AUTH_DOMAINS` 控制,
  默认 `wiki,docs,drive,minutes,im,contact,vc`(覆盖会议纪要全链路)。Device Flow 起不来时
  退回旧文字告警兜底。

## [1.5.0] - 2026-07-20

### Added
- **run.sh 第 0 步「确定性预检门」**:每次心跳先用 `lark-cli minutes +search`(owner ∪ participant,
  单页 30)直接拉今日妙记列表,与去重台账比对;**无新增 → 不建知识库节点、不拉起 AI 运行器**,删本轮
  日志静默退出,心跳成本降为 2 次轻量 lark API 调用。有新增才走完整 workflow 链路。
  预检失败(user token 失效/网络异常)走限流告警(每天最多一条)后退出,不 fail-open——避免凭据失效
  期间每个心跳白烧一次 AI 调用(历史上高频心跳空烧曾撞爆月度算力额度,见 402 事件)。

### Changed
- **定位从「每日批处理」转为「订阅式增量」**:init.sh 默认频率从每天 18:47 改为**每 5 分钟订阅新增**
  (菜单改为 5 项,每 5 分钟为推荐默认;每天定点降为选项 4);plist 模板默认块同步改为
  `StartInterval 300`;生产 cron 由 `*/2` 调整为 `*/5`(预检门就绪后无需 2 分钟粒度抢跑)。
- SKIP_TOKENS 计算从第 3 步上移至第 0 步预检门,workflow 传参逻辑不变;README/CLAUDE.md 频率相关
  描述同步更新。

### Notes
- 空天(无会议日)不再产生空的「<日期> 会议纪要」知识库节点——节点仅在确有新增妙记时创建,属预期行为变化。
- 单日会议数 >30 且前 30 篇均已处理时预检可能漏检一轮,下一心跳即兜底,可忽略。

## [1.4.2] - 2026-07-20

### Changed
- 安全审计后的信息披露收敛:`harden.sh` 注释与 CHANGELOG 历史条目中的内部主机名改为通用表述
  (审计结论:全历史无凭据/个人标识/会议内容泄漏,详见本次审计;此为唯一整改项)。

## [1.4.1] - 2026-07-20

### Changed
- **README 大修**:「纪要长什么样」从 6 月旧版 8 维度(智能章节/金句时刻等,已于 2026-07-10 废弃)
  更新为现行**结论前置式 8 段结构**;新增 AI 配图能力说明(自主判断/图文分栏/降级策略/GEN_IMAGE 开关)、
  init.sh 注册生图 MCP 说明、常见问题配图排查条目、架构图配图环节。

## [1.4.0] - 2026-07-20

### Added
- **配图支持图文左右分栏排版**(观感对齐飞书妙记 AI 总结画板):新增规格文件
  `config/image-layout-spec.md`,五步流程已在真实文档端到端验证——media-insert 插图 →
  `+fetch --detail with-ids` 取 block id → `block_insert_after` 插空 grid 骨架(带占位块)→
  `block_move_after` 把原文段落逐块移进左栏、图片块移进右栏(图片 token 与 caption 自动保留)→
  `block_delete` 删占位。原有内容块只移动不重写;**唯一例外:配图覆盖的段落文字可适当精简**
  (图/caption 已表达的细节收敛,只留判断与结论,block_replace 完成)。
- `run.sh` 经 args.imageSpec 注入规格路径;workflow Publish prompt 引导 agent 读规格后自主执行,
  图不适合分栏或分栏失败时退化为简单 media-insert 插入。

### Notes
- 分栏与精简都发生在建档后的文档上,本地 markdown 与 checker 评分口径不受影响。
- width-ratio 服务端会归一化(实测 0.55/0.45 落地为 0.5/0.5);block id 在写操作后可能失效,规格已提示每步前重新 fetch。

## [1.3.0] - 2026-07-20

### Changed
- **配图从"固定编排"改为"能力暴露"**(用户反馈:不要死板):撤掉 1.2.0 的独立 Illustrate 阶段与
  固定插图位置;改为 Publish agent 建档后获得生图能力说明(`mcp__gpt-image__generate_image`),
  由 AI 读完纪要**自行判断**要不要配图、配几张(0–2 张)、插在哪(`media-insert --selection-with-ellipsis`
  位置自选)。内容单薄不配图是正常结果。失败降级逻辑不变。

### Added
- **生图 MCP 内置进项目**:`tools/gpt-image-mcp/`(index.js + package.json + README)随包分发;
  `init.sh` 新增 7.5 步——自动 `npm install` 依赖 + 注册 user scope MCP(已注册则跳过,
  支持从 config.sh 读 `GPT_IMAGE_KEY`/`GPT_IMAGE_BASE_URL` 注入 MCP 环境),新用户初始化即得配图能力。
- init.sh 生成的 config.sh 与 config.example.sh 增加 `GEN_IMAGE` 与凭据配置说明;
  `.gitignore` 屏蔽 `tools/gpt-image-mcp/node_modules/`。

## [1.2.0] - 2026-07-20

### Added
- **每篇纪要可选 AI 配图(gpt-image MCP)**:新增 Illustrate 阶段——checker 通过后、建档前,
  由 agent 读取纪要提炼核心结论,调用 `mcp__gpt-image__generate_image`(StepFun models-proxy 的
  gpt-image-2)生成一张 1536x1024 扁平风视觉摘要配图(画面无文字),落在当天本地目录;
  Publish 建档后用 `lark-cli docs +media-insert --selection-with-ellipsis "一、一句话结论" --before`
  把图插到核心结论看板之前。
  - `daily-meeting-minutes.js`:args 新增 `genImage`;新增 Illustrate 阶段与 Publish 插图步骤。
  - `run.sh`:新增 `GEN_IMAGE` 开关(默认 1),经 args.genImage 注入 workflow。
  - `config.example.sh`:新增第 7 节 GEN_IMAGE 说明。

### Notes
- **失败降级**:MCP 未注册、生图接口报错、media-insert 失败,均不阻塞纪要主流程(降级为无图发布,url 照常返回)。
- checker rubric 不变:配图在建档后插入,不进入本地 markdown,C1–C4 评分口径不受影响。
- 依赖:运行机需已注册 gpt-image MCP(user scope)且生图接口可达;远端生产节点已于 2026-07-20 部署验证。

## [1.1.1] - 2026-07-20

### Added
- `.gitignore` 屏蔽 `minutes/` —— `lark-cli minutes +detail --transcript` 会在 cwd 落 `minutes/<token>/transcript.txt`(含会议逐字稿),防止误入库。
- README 常见问题新增「单独重跑某一篇(含历史)纪要」的操作说明(导出逐字稿 → offlineInput 生成 → docs +create 发布替换 → 更新 ledger 链接)。

### Notes
- 本次为运维/文档整理,不改生成逻辑。触发点:用旧格式历史会议重跑为画板版时,发现逐字稿导出产物会落在仓库目录。

## [1.1.0] - 2026-07-17

### Changed
- **「一、一句话结论」从纯文字升级为「核心结论看板」画板**:参考飞书妙记「AI 总结画板」的能力,
  该段正文改为内联 `<whiteboard type="svg">` 原生画板——结论高亮带 + 2–4 张方向/判断卡片 +
  (有阶段时)里程碑时间线。经 `docs +create` 建档即实例化为可编辑原生画板,建档链路零改动。
  - `daily-meeting-minutes.js`:draft prompt 给出固定 SVG 骨架、accent 调色板、自适应规则与画板硬约束
    (禁用 `radialGradient`/`filter`/`clipPath`/`mask` 等画板不支持特性);同步 C4 排版自检清单与兜底 `CRITERIA` 常量。
  - `config/checker-rubric.md`:C1/C2/C4 改为按「看板画板非空 + 看板 `<text>` 结论忠实于源妙记」评分。
  - `evolution/prompts/meta-evaluator/prompt.md`(进化守则 DO-NOT-TOUCH pin 版,**人工签署改动**):
    C1 明确纯画板是预期设计、不按空壳 fail;C5 幻觉核查提示回溯 SVG `<text>` 内的结论文字。
  - `README.md`:纪要结构说明中「总结/一句话结论」改述为核心结论看板画板。

### Notes
- 实测验证:按上述 SVG 规范建档→导出画板 PNG,渲染为「结论带 + 彩色卡片 + 带标签时间线」,中文不溢出、无渲染异常。
- 完整回归(`evolution/bin/regression.sh`,需 golden cases)需同步到远端生产节点后在远端跑,以过 policy G2 门槛。

# Changelog

本项目所有值得记录的变更都写在这里。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/),版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
最新版本在最上方;每次发布都在顶部追加一条。（本文件自 2026-07-17 起维护,更早的历史以 git 提交记录为准。）

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
- 完整回归(`evolution/bin/regression.sh`,需 golden cases)需同步到远端 bingzhe-01 后在远端跑,以过 policy G2 门槛。

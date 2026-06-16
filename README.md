# 每日飞书会议纪要 · 安装说明(极简版)

把当天所有飞书会议录音(妙记)自动整理成 5 维度纪要(总结/智能章节/关键决策/金句/相关链接），
归档到你飞书知识库的「会议纪要 / <日期>」下，并发飞书通知。可设成每天自动跑。

> **只需 3 步，配置全自动，不用手填任何值。**

---

## 第 1 步：装好两个工具并登录

1. **lark-cli（飞书官方 CLI）**
   ```bash
   npm i -g @larksuite/cli      # 或按官方文档安装
   lark-cli config init         # 配置应用（按提示完成）
   # 一次性授权所需权限（复制整行运行）：
   lark-cli auth login --scope "contact:user.base:readonly minutes:minutes.search:read minutes:minutes.artifacts:read minutes:minutes.transcript:export wiki:node:retrieve wiki:node:create docx:document:create im:message.send_as_user drive:drive.metadata:readonly vc:note:read"
   ```

2. **Claude Code（或 stepcode `sc`）** —— 装好并登录一次即可（`claude` 或 `sc claude`）。

## 第 2 步：一键初始化

```bash
cd <本包目录>
./init.sh
```

`init.sh` 会**自动探测并配置好一切**（你的 open_id、知识库 space、飞书域名、创建「会议纪要」根节点、安装 workflow）。
**你不需要手填任何东西。** 最后会问你**多久自动跑一次**（直接回车 = 每天一次 18:47），并自动装好定时任务（macOS launchd / Linux cron）。如果缺授权，它会打印出该补的命令。

> 想全程默认?一路回车即可,等价于「每天 18:47 跑一次」。


## 第 3 步：跑一次

```bash
./run.sh
```

成功标志：飞书知识库出现「会议纪要 / <今天日期>」节点 + 其下若干文档，并收到飞书通知。
日志在 `~/会议纪要/_logs/`。

---

## 调整自动运行频率

定时任务在第 2 步 `init.sh` 时已**自动装好**(默认每天 18:47),无需手动配置。
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

- **init 报"拿不到 open_id / 解析失败"** → 飞书授权没给全，按它打印的 `lark-cli auth login --scope ...` 补一下再重跑 `./init.sh`。
- **run 报"未登录"** → 跑一次 `claude`（或 `sc claude`）登录一下。脚本会自动识别用哪个。
- **某天没跑成** → 多半是登录态问题，`run.sh` 会自动发飞书告警提示你。
- **同一天重复跑** → 已支持跨运行去重(`.loop-engine/processed.tsv`):只跳过已成功的妙记,**不再产生重复文档**;上次失败/待复核的会自动重试。
- **某篇带「⚠️ 待复核」** → checker 打分低于 `MIN_SCORE` 且重写后仍不达标,已归档但建议人工看一眼;缺口记在 `.loop-engine/state.md`。
- **定时跑失败但手动能跑** → 多半是 launchd/cron 的 PATH 太干净找不到 lark-cli/node。本版已在 plist 注入 PATH + WorkingDirectory;Linux cron 用 `/bin/bash run.sh`,run.sh 也会自己补常见 PATH。
- **想改本地存放目录** → 编辑 `config.sh` 里的 `BASE_DIR`。
- **想改质量阈值** → 编辑 `config.sh` 的 `MIN_SCORE` / `REDRAFT_MAX`。

## 它做了什么（架构）

```
run.sh(确定性 bash)
 ├─ 依赖/PATH 自检(lark-cli/python3/node/sc) + 日志轮转
 ├─ 建/复用 本地当天目录 + 知识库当天节点          ← 不交给 AI
 ├─ (sc) claude -p 调起 workflow(传 dayNode/localDir/ledger/minScore…)
 │    └─ workflow: 发现妙记 →[读 ledger 去重,跳过已 DONE]
 │                 → 生成 → 独立 checker 打分(<阈值则回灌缺口重写) → 建档
 │                 → 通知 → 写 _result.json
 ├─ 失败告警(未登录/出错 → 飞书消息;已修 set -e 死代码,告警真正可达)
 ├─ 读 _result.json → 确定性追加去重台账 + 刷新 state.md   ← 不交给 AI
 └─ 从当天节点把文档确定性拉回本地备份                ← 不交给 AI
```

**loop-engine 闭环要素:** 🧠 状态/去重台账(`.loop-engine/processed.tsv` + `state.md`)+ ⑤ 生成者≠检查者(独立 checker 按停止条件打分、不达标自动重写)。

## 卸载 / 打包分发

```bash
./uninstall.sh           # 移除定时任务 + workflow,保留数据与配置
./uninstall.sh --purge   # 连 config.sh 与 .loop-engine 一起删(二次确认)
./dist.sh                # 干净打包成 zip(git archive,自动排除含 open_id 的 config.sh)
```

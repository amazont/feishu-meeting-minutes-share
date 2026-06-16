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
- **同一天重复跑** → 当天节点会复用（不重复建），但文档会叠加（暂未对妙记去重）；想重跑先删旧的那套。
- **想改本地存放目录** → 编辑 `config.sh` 里的 `BASE_DIR`。

## 它做了什么（架构）

```
run.sh（确定性 bash）
 ├─ 建/复用 本地当天目录 + 知识库当天节点      ← 不交给 AI
 ├─ (sc) claude -p 调起 workflow(传 dayNode/localDir…)
 │    └─ workflow: 发现妙记 → pipeline[ 生成 → 建档 ] → 通知
 ├─ 失败告警(未登录/出错 → 飞书消息)
 └─ 从当天节点把文档确定性拉回本地备份          ← 不交给 AI
```

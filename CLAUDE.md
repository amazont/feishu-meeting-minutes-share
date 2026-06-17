# CLAUDE.md — 给 Claude Code 的执行手册

你的任务:帮用户把「每日飞书会议纪要」自动化跑起来。这是一个把当天飞书会议录音(妙记)
自动整理成 5 维度纪要、归档到飞书知识库并通知的服务。本目录已含全部脚本,**你主要是按序执行 + 验证 + 出错时引导用户授权**。

---

## 总体流程(照做即可)

1. 检查依赖与登录 → 2. 跑 `./init.sh` 自动配置 → 3. 跑 `./run.sh` 验证 → 4.(可选)设每天自动跑。

**重要原则:**
- 凡是脚本能做的(建目录/建知识库节点/拉回备份),交给脚本,不要你手动用 agent 去做。
- 涉及**交互式登录**(`lark-cli auth login`、`claude`/`sc claude` 登录)你无法替用户完成,要把命令给用户、让他自己跑。
- 不要把任何 token / open_id 打印到对外渠道。

---

## 步骤 1:检查依赖与登录

```bash
command -v lark-cli && (command -v sc || command -v claude)
```

- 缺 `lark-cli` → 让用户安装:`npm i -g @larksuite/cli` 然后 `lark-cli config init`。
- 缺 `sc` 和 `claude` → 让用户安装 Claude Code(或 stepcode `sc`)。

检查飞书是否已授权(能否拿到 open_id):
```bash
lark-cli contact +get-user --format json 2>/dev/null | grep -oE 'ou_[a-z0-9]+' | head -1
```
- 有输出 → 已授权,继续。
- 无输出 → 让用户运行这一行完成授权(整行复制),完成后继续:
```bash
lark-cli auth login --scope "contact:user.base:readonly minutes:minutes.search:read minutes:minutes.artifacts:read minutes:minutes.transcript:export wiki:node:retrieve wiki:node:create docx:document:create im:message.send_as_user drive:drive.metadata:readonly vc:note:read"
```
> `lark-cli auth login` 是交互式(弹浏览器),你不能替用户跑。把命令给他,让他自己运行,完成后回来。

---

## 步骤 2:一键初始化

```bash
./init.sh
```

`init.sh` 会**自动**:取 open_id、解析个人知识库 space_id、创建/复用「会议纪要」根节点、探测飞书域名、写 `config.sh`、安装 workflow 到 `~/.claude/workflows/`,并在最后**询问运行频率(默认每天一次 18:47)后自动装好定时任务**(macOS launchd / Linux cron)。

- 频率选择是交互式的(菜单 1-4):直接回车 = 每天一次。若你替用户跑 init 处于非交互环境,会自动用默认(每天 18:47)。
- 成功标志:打印一串 `✅`、显示「自动运行频率:…」并以 `🎉 初始化完成` 结尾,且生成了 `config.sh`。
- 若报「拿不到 open_id / 解析失败」→ 是授权没给全,把它打印的 `lark-cli auth login --scope ...` 给用户补授权,然后重跑 `./init.sh`。

---

## 步骤 3:跑一次验证

```bash
./run.sh
```

它会:建当天本地目录 + 知识库当天节点 → 调起 workflow 生成纪要 → 失败告警 → 把文档拉回本地。
日志在 `$BASE_DIR/_logs/`(`config.sh` 的 `BASE_DIR`,默认 `~/会议纪要/`)。
**注意降噪策略**:仅在「失败」或「本次有成功归档(count>0,发了通知)」时才保留日志;无新增 / 全部跳过的静默心跳**不留日志、不发通知**(去重台账与 `state.md` 仍会更新)。所以高频定时下 `_logs/` 多数时候是空的,属正常。

验证结果(看最近一条有意义的日志,或直接看完成契约):
```bash
LOG=$(ls -t "$BASE_DIR"/_logs/daily-minutes_*.log 2>/dev/null | head -1); [ -n "$LOG" ] && cat "$LOG" || echo "无近期日志(说明最近都是无新增的静默心跳)"
cat "$BASE_DIR/$(date +%F)/_result.json" 2>/dev/null   # 每次跑都会写的完成契约
```
- 看到「生成 N 篇」+「退出码 0」+ 知识库出现「会议纪要/<今天>」节点及文档 → 成功。
- **「0 篇」不是错误**:可能今天还没会议妙记(会议没开 / 妙记没生成完),晚点再跑即可。
- 日志含 `Not logged in` → 让用户跑一次 `claude`(或 `sc claude`)登录,再重试。

---

## 步骤 4(可选):调整自动运行频率

定时任务在步骤 2(`init.sh`)时已**自动装好**(默认每天 18:47)。一般无需再做什么。

- **想改频率/时间,或关掉自动跑** → 让用户重跑 `./init.sh`,在频率菜单选一次(1 每天 / 2 每 N 小时 / 3 每 N 分钟 / 4 不自动跑)。
- 校验是否装上:
  - macOS:`launchctl list | grep daily-meeting-minutes`
  - Linux:`crontab -l | grep daily-meeting-minutes`
- 想手动接管:macOS 的 plist 已生成到 `~/Library/LaunchAgents/com.example.daily-meeting-minutes.plist`(每天定点用 `StartCalendarInterval`、间隔用 `StartInterval` 秒);Linux 看 `crontab -e` 里带 `daily-meeting-minutes` 标记的那行。

---

## 常见问题处理速查

| 现象 | 处理 |
|---|---|
| init 报拿不到 open_id / 解析失败 | 授权不全 → 给用户那行 `lark-cli auth login --scope ...` 补授权后重跑 init |
| run 日志含 `Not logged in` | 让用户跑 `claude` / `sc claude` 登录一次 |
| 生成 0 篇 / 「无新增」 | 今天暂无妙记或都已处理(去重),正常,晚点重跑 |
| 定时跑失败但手动 OK | launchd/cron PATH 太干净 → 本版已在 plist 注入 PATH+WorkingDirectory;确认 `~/Library/LaunchAgents/*.plist` 含 `EnvironmentVariables/PATH` |
| 某篇带「⚠️ 待复核」 | checker 打分 < `MIN_SCORE` 且重写后仍不达标;已归档,缺口见 `$BASE_DIR/.loop-engine/state.md` |
| 想改质量阈值 | 改 `config.sh` 的 `MIN_SCORE` / `REDRAFT_MAX` |
| 想改本地存放目录 | 改 `config.sh` 的 `BASE_DIR` |
| 想卸载 / 打包分发 | `./uninstall.sh`(留数据)、`./uninstall.sh --purge`(删配置/状态)、`./dist.sh`(干净 zip) |

## 文件说明(供你理解,不用改)

- `init.sh` — 一键初始化(零输入,自动探测配置;建 `.loop-engine` 状态目录;plist 注入 PATH/WorkingDirectory)。
- `run.sh` — 入口脚本:依赖/PATH 自检 + 确定性建节点 + 调 workflow + 失败告警(已修 set -e 死代码)+ 读 `_result.json` 写台账/state + 拉回备份 + 日志轮转。自动识别 `sc claude` 或 `claude`。
- `daily-meeting-minutes.js` — workflow:发现(读 ledger 去重)→ 生成 → 独立 checker 打分(不达标按缺口重写)→ 建档 → 通知 → 写 `_result.json`。配置全由 `run.sh` 经 args 注入。
- `update_state.py` — 由 run.sh 调用:读 `_result.json` → 追加去重台账 `processed.tsv` + 重写 `state.md`(loop-engine schema)。
- `uninstall.sh` / `dist.sh` — 卸载;干净打包(git archive,排除 config.sh)。
- `config.sh` — 由 init.sh 生成的本地配置(含个人 open_id 与 MIN_SCORE/REDRAFT_MAX,**不要外传**)。
- `$BASE_DIR/.loop-engine/` — 运行状态:`processed.tsv`(去重台账)+ `state.md`(人读)。**不随包分发**。
- `README.md` — 给人看的版本。

---

**开始执行吧:从步骤 1 检查依赖开始,逐步带用户跑通。遇到需要交互式登录的环节,停下来把命令交给用户。**

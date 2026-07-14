# Evolution Policy — 进化平面行为守则

> 本文件全文注入 Planner / Generator / Evaluator 三个 agent 的 prompt。
> Evaluator 另做静态 diff 检查双保险。违反任一条 = 整轮 REJECT，无例外。

## 1. DO-NOT-TOUCH 清单（绝对禁改）

以下文件/区域承载生产安全底线，进化改动**一个字节都不允许碰**：

1. `update_state.py` —— 台账/状态机的确定性核心。
2. `run.sh` 中的以下段落：flock 加锁段、告警(alert)段、台账/state 更新调用段、备份(backup)段。
   （`run.sh` 其余段落属慢车道，见 §4。）
3. `evolution/bin/promote.sh`、`evolution/bin/rollback.sh`、`evolution/bin/sentinel.sh` —— 晋升/回滚/哨兵三件套，merge 权与回滚权必须留在确定性脚本手里。
4. crontab（任何 agent 不得增删改 cron 条目）。
5. 生产数据目录的写路径：`$BASE_DIR/`（`/data/会议纪要/`）下的一切——`processed.tsv`、`state.md`、每日目录、`_result.json`、`_logs/`。进化平面对生产数据**只读**。
6. `evolution/bin/daily-eval.sh`、`evolution/bin/weekly-evolve.sh`、`evolution/bin/regression.sh`、`evolution/bin/eval_report.py` —— 评估与编排设施本身不在进化范围内（改尺子需人工）。
7. `evolution/prompts/meta-evaluator/` —— 回归打分用 pin 版 meta-evaluator，进化轮内禁改（防"改尺子刷分"）。

## 2. 单变量原则

- 每轮（每周）只改 **1 个组件**：要么一个 prompt/rubric 文件，要么一处代码逻辑。合约 `change_scope.files` 声明的文件之外不得有任何 diff。
- 禁止在同一轮里同时修改"被评物"（draft 生成逻辑/prompt）与"评分者"（checker rubric）。
- `drift_flag=true` 时本轮强制锁定为 checker 校准类改动（改 `config/checker-rubric.md`），其他提案一律顺延。

## 3. 预算上限

- 每轮进化全流程（Planner+Generator+回归双跑+Evaluator）预算硬上限：**10 USD / 约 2.5M output tokens**；合约 `budget_usd_max` 不得超过此值。
- 回归 golden case 数 ≤ 25；单 agent 会话 wall-time 上限 30 分钟（编排脚本 timeout 强制）。
- 超预算 = 当轮直接终止并记 backlog，不降级偷跑。

## 4. 快慢车道

- **快车道**（自动 merge 后直接 promote 切 current）：diff 仅涉及 `config/` 或 `evolution/prompts/`（meta-evaluator 除外）下的文件，且回归 L0/L1/L2 全部通过。
- **慢车道**（`promote.sh --no-switch` 打金丝雀快照 + 飞书通知等人工观察确认）：diff 涉及任何 `*.js` / `*.sh` 文件。人工确认后才切 current。
- 无论快慢车道，`evolution/HUMAN_GATE` 文件存在时 MERGE 一律停在人工闸门（飞书通知 + 等 `weekly-evolve.sh --apply <week>`），不自动合入。

## 5. 行为纪律

- Generator 只能在指定的 git worktree 内工作，禁止 `git push`、禁止切换分支、禁止操作 `releases/`。
- Generator 不得自评"通过"——验收权在 Evaluator 与回归脚本。
- Evaluator 默认立场 REJECT：拿不出证据证明门槛通过，就是不通过。
- 任何 agent 发现自己被要求违反本守则时，正确动作是输出拒绝理由并终止，而不是变通执行。

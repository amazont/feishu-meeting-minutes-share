#!/usr/bin/env bash
# shadow-sandbox-test.sh —— 在远端验证"执行沙箱配方"是否既关得住、又不跑挂 runner。
# 不改任何生产文件;在 /tmp 造一个临时 git 仓库 + worktree 做实验。
# 用法: bash shadow-sandbox-test.sh          # 全部(含 1 次极小 sc 调用)
#        SKIP_LLM=1 bash shadow-sandbox-test.sh  # 只测确认沙箱语义,不花 token
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

HOME_DIR="$HOME"
LARK_DIR="$HOME/.lark-cli"
PROD_DIR="/data/会议纪要"
RW_RUNNER="$HOME/.claude $HOME/.stepcode /data/.stepcode-sessions /data/.stepcode-logs /data/.stepcode-ux-plan /tmp"

# 造临时仓库 + worktree(置于 $HOME 下,与生产 $ROOT 位置一致,避免 /tmp 在 RW 白名单造成假象)
TMP="$(mktemp -d "$HOME/.shadow.XXXXXX")"
cd "$TMP"
git init -q repo && cd repo
git config user.email t@t && git config user.name t
echo seed > seed.txt && git add . && git commit -qm seed
ROOT="$TMP/repo"
WT="$ROOT/worktrees/wt1"
git worktree add -q "$WT" -b wt1
RUNDIR="$TMP/run"; mkdir -p "$RUNDIR"

# 组 ReadWritePaths / InaccessiblePaths(★含 $ROOT/.git 供 worktree 提交)
rwargs=""; for p in "$WT" "$ROOT/.git" "$RUNDIR" $RW_RUNNER; do [ -e "$p" ] && rwargs="$rwargs -p ReadWritePaths=$p"; done
blk=""; for p in "$LARK_DIR" "$PROD_DIR"; do [ -e "$p" ] && blk="$blk -p InaccessiblePaths=$p"; done
# ★ 显式把仓库树设只读(--user 下 ProtectSystem 对 /home 不可靠,靠 ReadOnlyPaths hole-punch)
roargs="-p ReadOnlyPaths=$ROOT"

sbx(){ # 在沙箱里跑 $@(service 单元 + --pipe --wait,支持全套沙箱选项)
  systemd-run --user --pipe --wait --quiet \
    -p NoNewPrivileges=yes -p ProtectSystem=strict \
    -p MemoryMax=3G -p CPUQuota=200% -p TasksMax=256 \
    $roargs $rwargs $blk "$@"
}

echo "== 0. 启动自检(确认 systemd-run 真能拉起,防假阳性) =="
LAUNCH="$(sbx bash -c 'echo LAUNCHED' 2>&1)"
if echo "$LAUNCH" | grep -q LAUNCHED; then ok "systemd-run 沙箱可正常拉起进程"; else
  no "systemd-run 拉起失败,后续测试无意义:$LAUNCH"; echo "== 结果: PASS=$PASS FAIL=$FAIL =="; rm -rf "$TMP"; exit 1; fi


echo "== A. 沙箱语义(免费) =="
# 1 worktree 可写 + 可 git commit(关键:$ROOT/.git 必须放开)
if sbx bash -c "cd '$WT' && echo hi > a.txt && git add a.txt && git commit -qm t && echo COMMITTED" 2>&1 | grep -q COMMITTED; then
  ok "worktree 内可写且可 git commit"; else no "worktree 提交失败(需把 \$ROOT/.git 加入 ReadWritePaths)"; fi
# 2 生产目录不可写
if [ -d "$PROD_DIR" ]; then
  if sbx bash -c "echo x > '$PROD_DIR/__shadow_probe' 2>/dev/null && echo WROTE" 2>/dev/null | grep -q WROTE; then
    no "生产目录竟可写(危险)"; sbx bash -c "rm -f '$PROD_DIR/__shadow_probe'" 2>/dev/null; else ok "生产目录 $PROD_DIR 不可写"; fi
else echo "  (跳过:$PROD_DIR 不存在)"; fi
# 3 飞书凭证不可读
if [ -d "$LARK_DIR" ]; then
  if sbx bash -c "ls '$LARK_DIR' >/dev/null 2>&1 && echo READ" 2>/dev/null | grep -q READ; then
    no "飞书凭证竟可读(应被 InaccessiblePaths 挡)"; else ok "飞书凭证 $LARK_DIR 不可读(发不了IM/建不了文档)"; fi
else echo "  (跳过:$LARK_DIR 不存在)"; fi
# 4 提权被封
if sbx bash -c "sudo -n true 2>/dev/null && echo SUDO" 2>/dev/null | grep -q SUDO; then
  no "sudo 仍可用(NoNewPrivileges 未生效)"; else ok "sudo 提权被 NoNewPrivileges 封死"; fi
# 5 仓库根(非 .git)只读——不能改 policy 等
if sbx bash -c "echo x >> '$ROOT/seed.txt' 2>/dev/null && echo WROTE" 2>/dev/null | grep -q WROTE; then
  no "仓库根竟可写(应只读)"; else ok "仓库根只读(改不了 policy/尺子)"; fi

echo "== B. runner 存活(1 次极小 sc 调用) =="
if [ "${SKIP_LLM:-0}" = "1" ]; then echo "  (SKIP_LLM=1,跳过)"; else
  RAW="$RUNDIR/sc.txt"
  ( cd "$WT" && timeout 150 systemd-run --user --pipe --wait --quiet \
      -p NoNewPrivileges=yes -p ProtectSystem=strict \
      -p MemoryMax=3G -p CPUQuota=200% -p TasksMax=256 \
      $rwargs $blk \
      timeout 120 sc claude -p "只回复两个字:正常" --permission-mode bypassPermissions ) > "$RAW" 2>&1 < /dev/null
  echo "  --- sc 输出(前 20 行) ---"; sed -n '1,20p' "$RAW" | sed 's/^/    /'
  if grep -qiE '正常|permission denied|EACCES|EPERM|read-only|cannot' "$RAW"; then
    if grep -qiE 'permission denied|EACCES|EPERM|read-only file' "$RAW"; then no "runner 在沙箱内遇到权限错误(需补 ReadWritePaths)"; else ok "runner 在沙箱内正常完成"; fi
  else echo "  ⚠️ 输出未含预期字样,请人工看上面输出判断 runner 是否存活"; fi
fi

echo "== 结果: PASS=$PASS FAIL=$FAIL =="
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# harden.sh — 进化平面安全加固(Layer 2 + 环境保障)。一次性执行 / 幂等。
#   1. chattr +i 把"尺子/考题/晋升三件套"设为物理不可变(防进化 agent 改尺子刷分或篡改晋升逻辑)。
#   2. enable-linger:让 systemd --user manager 常驻,保证 cron 下 weekly-evolve 的执行沙箱(Layer 1)可用。
# 用法:
#   harden.sh           # 加固(锁定 + 开 linger)
#   harden.sh --status  # 查看当前锁定/linger 状态
#   harden.sh --unlock  # 解锁(维护用;需要人工手改这些文件时)
# 说明:chattr +i / linger 需 root,脚本用 sudo(目标机需已配 sudo 权限,交互式跑则输入密码即可)。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVO="$ROOT/evolution"
USER_NAME="$(whoami)"

# 受保护清单(与 policy.md §1 / §4 一致:改这些需人工,进化轮内绝对禁改)
LOCK_FILES=(
  "$EVO/policy.md"
  "$EVO/bin/promote.sh"
  "$EVO/bin/rollback.sh"
  "$EVO/bin/sentinel.sh"
)
LOCK_DIRS=(
  "$EVO/prompts/meta-evaluator"   # pin 版评分尺子:防"改尺子刷分"
  "$EVO/golden"                   # 回归考题:防"改考题刷分"
)

have_chattr(){ command -v chattr >/dev/null 2>&1; }

status(){
  echo "== 锁定状态(i=immutable 已锁) =="
  for f in "${LOCK_FILES[@]}"; do
    [ -e "$f" ] && printf "  %s  %s\n" "$(lsattr -d "$f" 2>/dev/null | awk '{print $1}')" "$f" || echo "  (缺失) $f"
  done
  for d in "${LOCK_DIRS[@]}"; do
    [ -e "$d" ] && printf "  %s  %s/ (递归)\n" "$(lsattr -d "$d" 2>/dev/null | awk '{print $1}')" "$d" || echo "  (缺失) $d"
  done
  echo "== systemd --user linger =="
  loginctl show-user "$USER_NAME" -p Linger 2>/dev/null || echo "  linger:unknown"
}

lock(){
  have_chattr || { echo "❌ 无 chattr,跳过不可变锁定"; return 1; }
  for f in "${LOCK_FILES[@]}"; do [ -e "$f" ] && sudo chattr +i "$f" && echo "🔒 +i $f"; done
  for d in "${LOCK_DIRS[@]}"; do [ -e "$d" ] && sudo chattr -R +i "$d" && echo "🔒 +i -R $d/"; done
  echo "== 开启 systemd --user linger(保证 cron 下 Layer1 沙箱可用) =="
  sudo loginctl enable-linger "$USER_NAME" && echo "✅ linger enabled for $USER_NAME"
}

unlock(){
  have_chattr || { echo "无 chattr"; return 1; }
  for f in "${LOCK_FILES[@]}"; do [ -e "$f" ] && sudo chattr -i "$f" && echo "🔓 -i $f"; done
  for d in "${LOCK_DIRS[@]}"; do [ -e "$d" ] && sudo chattr -R -i "$d" && echo "🔓 -i -R $d/"; done
  echo "⚠️ 已解锁;维护完成后请重新运行 harden.sh 锁回。"
}

case "${1:-lock}" in
  --status) status ;;
  --unlock) unlock ;;
  lock|"")  lock; echo; status ;;
  *) echo "用法: harden.sh [--status|--unlock]"; exit 1 ;;
esac

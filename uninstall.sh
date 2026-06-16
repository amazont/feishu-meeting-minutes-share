#!/usr/bin/env bash
# 卸载每日会议纪要自动化:移除定时任务 + workflow。默认保留你的数据与配置。
#   ./uninstall.sh           移除 launchd/cron + workflow,保留 config.sh、纪要、state
#   ./uninstall.sh --purge   连同 config.sh 和 $BASE_DIR/.loop-engine 一起删(二次确认)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.example.daily-meeting-minutes"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

# 读 BASE_DIR(用于 --purge 时定位 .loop-engine);读不到给个默认
BASE_DIR="$HOME/会议纪要"
[ -f "$HERE/config.sh" ] && BASE_DIR="$(. "$HERE/config.sh"; echo "$BASE_DIR")"

echo "🧹 卸载每日会议纪要自动化"
echo "─────────────────────────────"

# 1) 移除定时任务(macOS launchd / Linux cron)
case "$(uname -s)" in
  Darwin)
    plist="$HOME/Library/LaunchAgents/$LABEL.plist"
    if [ -f "$plist" ]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      echo "✅ 已移除 launchd 任务并删除 $plist"
    else
      echo "ℹ️ 未发现 launchd plist,跳过"
    fi ;;
  Linux)
    marker="# daily-meeting-minutes ($LABEL)"
    if crontab -l 2>/dev/null | grep -qF "$marker"; then
      crontab -l 2>/dev/null | grep -vF "$marker" | crontab -
      echo "✅ 已从 crontab 移除任务"
    else
      echo "ℹ️ crontab 未发现该任务,跳过"
    fi ;;
  *) echo "⚠️ 未识别系统,请手动移除定时任务" ;;
esac

# 2) 删除已安装的 workflow
WF="$HOME/.claude/workflows/daily-meeting-minutes.js"
if [ -f "$WF" ]; then rm -f "$WF"; echo "✅ 已删除 workflow $WF"; else echo "ℹ️ 未发现已安装 workflow,跳过"; fi

# 3) 可选:清除配置与状态(不可逆,二次确认)
if [ "$PURGE" -eq 1 ]; then
  echo "─────────────────────────────"
  echo "⚠️ --purge 将删除以下内容(不可逆):"
  echo "    - $HERE/config.sh(你的 open_id/space 等配置)"
  echo "    - $BASE_DIR/.loop-engine(去重台账 + state.md)"
  echo "    注意:不会删除你的纪要正文目录 $BASE_DIR/<日期>/(请按需自行处理)"
  printf "确认删除?输入 yes 继续: "
  read -r ans || true
  if [ "$ans" = "yes" ]; then
    rm -f "$HERE/config.sh"
    rm -rf "$BASE_DIR/.loop-engine"
    echo "✅ 已删除 config.sh 与 .loop-engine"
  else
    echo "已取消 purge,配置与状态保留"
  fi
else
  echo "ℹ️ 已保留 config.sh、纪要与 state(如需彻底清除:./uninstall.sh --purge)"
fi

echo "─────────────────────────────"
echo "🎉 卸载完成。重新启用请跑 ./init.sh"

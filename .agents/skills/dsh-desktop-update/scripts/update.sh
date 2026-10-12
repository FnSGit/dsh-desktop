#!/usr/bin/env bash
# DSH Desktop 一键更新：git pull → submodule → install → build → 打包安装 → 启动验证
# 用法: update.sh [--check] [--no-start]
#   --check     只探测上游有没有更新，不做任何改动
#   --no-start  装完不自动启动
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PKG_SCRIPT="$REPO/.agents/skills/dsh-desktop-mac-package/scripts/package-mac-local.sh"
PORT=43120
CHECK=false; START=true
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    --no-start) START=false ;;
    *) echo "未知参数: $arg"; exit 2 ;;
  esac
done
[ -f "$PKG_SCRIPT" ] || { echo "❌ 找不到打包脚本: $PKG_SCRIPT"; exit 1; }

cd "$REPO"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
LOCAL=$(git rev-parse --short HEAD)
echo "▶ 获取远端 ${BRANCH} @ ${LOCAL} ..."
git fetch origin --prune

BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)
AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)

if [ "$CHECK" = true ]; then
  if [ "$BEHIND" -eq 0 ]; then
    echo "✅ 已是最新（本地领先 $AHEAD 个未推送提交）"
  else
    echo "⬇️  可更新，落后 $BEHIND 个提交："
    git log --oneline "HEAD..origin/$BRANCH" | head -10
  fi
  exit 0
fi

# ── 预检 ────────────────────────────────────────────────────────────────
if pgrep -f "DSH Desktop.app/Contents/MacOS" > /dev/null; then
  echo "▶ 退出运行中的 DSH Desktop（GUI 占用 node_modules 会导致 install/打包损坏）..."
  pkill -f "DSH Desktop.app" || true; sleep 2
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作树有未提交改动，先 commit 或清理（防改动丢失）:"
  git status --short | head -10
  exit 1
fi

# ── 拉取上游 ────────────────────────────────────────────────────────────
if [ "$BEHIND" -gt 0 ]; then
  echo "▶ git pull --rebase（落后 $BEHIND 个提交）..."
  if ! git pull --rebase origin "$BRANCH"; then
    echo "❌ rebase 冲突。放弃重试: git rebase --abort；或手动解决后 git rebase --continue"
    exit 1
  fi
  echo "  已更新到 $(git rev-parse --short HEAD)"
else
  echo "▶ 远端无新提交（本地领先 $AHEAD 个未推送提交），跳过 pull"
fi

echo "▶ 同步 submodule..."
git submodule update --init --recursive

echo "▶ 安装依赖..."
corepack yarn install --immutable

# 依赖残骸防护：ENOTSUP 失败残留的空目录会被 yarn 静默跳过
for probe in dsh-plugin-desktop/node_modules/vite/package.json dsh-plugin-desktop/node_modules/dshmarket/package.json; do
  [ -f "$REPO/$probe" ] || {
    echo "❌ 依赖不完整（$probe 缺失）。修复: rm -rf 根+4个workspace的 node_modules 后 corepack yarn install --immutable"
    echo "   详见 .agents/skills/dsh-desktop-mac-package/SKILL.md 环境红线"
    exit 1
  }
done

echo "▶ 构建..."
corepack yarn build

echo "▶ 打包并安装到 /Applications..."
bash "$PKG_SCRIPT" --install

# ── 启动验证 ────────────────────────────────────────────────────────────
if [ "$START" = true ]; then
  echo "▶ 启动并验证（等待 Web Host 监听 ${PORT}，最长 60s）..."
  open "/Applications/DSH Desktop.app"
  OK=false
  for i in $(seq 1 20); do
    sleep 3
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then OK=true; break; fi
  done
  if [ "$OK" = true ]; then
    echo "✅ 更新完成，Web Host 已监听 127.0.0.1:$PORT"
  else
    echo "⚠️  60s 内 $PORT 未监听（若在 app 设置里改过端口属误报）。首启排障见 .agents/skills/dsh-desktop-mac-package/SKILL.md"
    tail -3 "$HOME/Library/Application Support/DSH Desktop/logs/dsh-$(date +%Y-%m-%d).error.log" 2>/dev/null | grep -v frame-ancestors || true
    exit 1
  fi
fi

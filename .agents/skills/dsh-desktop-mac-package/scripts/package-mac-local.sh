#!/usr/bin/env bash
# 本地未签名打包 DSH Desktop mac app（arm64，绕过 Xcode 26 actool 依赖）。
# 用法: package-mac-local.sh [--universal] [--install]
#   --universal  双架构合并（需下载 electron x64 zip，慢）
#   --install    打包验证后安装到 /Applications
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DESKTOP="$REPO/dsh-plugin-desktop"
OUT="$DESKTOP/dist/mac-smoke"
ARCH="arm64"
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --universal) ARCH="universal" ;;
    --install) INSTALL=true ;;
    *) echo "未知参数: $arg"; exit 2 ;;
  esac
done

# 1. 环境：GUI 运行中禁止打包（Electron 占用 node_modules，link 会 ENOTSUP 并残留空目录）
if pgrep -f "DSH Desktop.app/Contents/MacOS" > /dev/null; then
  echo "❌ DSH Desktop 正在运行，先退出再打包: pkill -f 'DSH Desktop.app'"; exit 1
fi

# 2. 依赖健康：node_modules 有 ENOTSUP 残骸时此处拦截（空目录会被 yarn 静默跳过）
for probe in "$DESKTOP/node_modules/vite/package.json" "$DESKTOP/node_modules/dshmarket/package.json"; do
  if [ ! -f "$probe" ]; then
    echo "❌ 依赖不完整（$probe 缺失）。修复: pkill DSH 后 rm -rf 各 workspace node_modules，再 corepack yarn install --immutable"; exit 1
  fi
done

# 3. 构建产物：desktop-cli 必须在位（未构建先跑 corepack yarn build）
[ -f "$DESKTOP/lib/desktop-cli.js" ] || { echo "❌ 未构建，先执行 corepack yarn build"; exit 1; }

cd "$DESKTOP"
if [ "$ARCH" = "universal" ]; then
  EB_ARCH="--universal"
  VERIFY_ARCH="universal"
else
  EB_ARCH="--arm64"
  VERIFY_ARCH="arm64"
fi

echo "▶ electron-builder 打包（icon 用 .icns 绕过 actool）..."
DSH_ELECTRON_BUILDER_TRAVERSAL_ONLY=1 CSC_IDENTITY_AUTO_DISCOVERY=false \
  ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}" \
  node node_modules/electron-builder/cli.js --mac dmg $EB_ARCH \
  --publish never \
  --config.mac.notarize=false --config.npmRebuild=false \
  --config.mac.icon=build/app-icon.icns \
  --config.directories.output="$OUT"

echo "▶ smoke 验证..."
DSH_MAC_SMOKE_ARCH="$VERIFY_ARCH" node scripts/verify-mac-smoke.ts "$OUT"

DMG=$(ls "$OUT"/*.dmg | head -1)
echo "✅ 打包完成: $DMG ($(du -h "$DMG" | cut -f1))"

if [ "$INSTALL" = true ]; then
  echo "▶ 安装到 /Applications..."
  pkill -f "DSH Desktop.app" 2>/dev/null || true; sleep 2
  MNT=$(hdiutil attach "$DMG" -nobrowse | awk -F'\t' '/Apple_HFS/{print $NF}' | tail -1)
  trap 'hdiutil detach "$MNT" -quiet' EXIT
  rm -rf "/Applications/DSH Desktop.app"
  cp -R "$MNT/DSH Desktop.app" /Applications/
  xattr -dr com.apple.quarantine "/Applications/DSH Desktop.app" 2>/dev/null || true
  trap - EXIT
  hdiutil detach "$MNT" -quiet
  echo "✅ 已安装 /Applications/DSH Desktop.app（首启排障见 SKILL.md）"
fi

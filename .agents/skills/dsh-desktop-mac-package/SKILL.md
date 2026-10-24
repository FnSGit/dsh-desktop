---
name: dsh-desktop-mac-package
description: 本仓库（dsh-desktop）mac app 本地打包、安装与首启排障。要打包 DMG、更新 /Applications 里的 DSH Desktop、或打包版启动卡 recovery 界面 / Host 不监听 43120 时使用。核心坑：GUI 运行中禁止 yarn install、无 Xcode 26 需 .icns 绕过 actool、首启迁移需 pnpm HTTP 代理。
---

# DSH Desktop mac 打包与安装

本项目（dsh-desktop）在**无 Xcode 26**、**无签名证书**的机器上，把桌面 app 打成未签名 DMG 并安装本机使用的完整流程。首次使用先读「环境红线」。

## 前置条件

- Node 22.19+/24.x + Corepack Yarn 4.18.0，submodule 已初始化（`git submodule update --init --recursive`）
- 依赖已装（`corepack yarn install --immutable`）、已构建（`corepack yarn build`，产出 `lib/desktop-cli.js`）
- 网络：electron zip 走 npmmirror；本机代理 127.0.0.1:7890（HTTP）/7891（socks5，**pnpm 不可用**）

## 环境红线（违反必炸）

1. **GUI 运行中禁止 yarn install / 打包**。Electron 占用 `node_modules`，link 阶段 ENOTSUP 失败，且残留空目录（曾见 dshmarket、vite）会被后续 install **静默跳过**，问题延迟爆发。打包前：`pkill -f "DSH Desktop.app"`，然后跑封装脚本（自带这两道检查）。
2. **依赖残骸自查**：`ls dsh-plugin-desktop/node_modules/vite/package.json` 缺失即残骸。修复：kill 进程后 `rm -rf` 根 + 4 个 workspace 的 node_modules 重装。
3. **复刻命令逐字符核对变量名**。主会话手动复刻 materializer 命令时曾把 generation 路径写错，导致 3 次假成功。能跑脚本就不要手敲长命令。

## 打包（推荐入口）

```bash
# .agents/skills/dsh-desktop-mac-package/scripts/package-mac-local.sh
corepack yarn --cwd /path/to/dsh-desktop workspace dsh-plugin-desktop exec bash \
  .agents/skills/dsh-desktop-mac-package/scripts/package-mac-local.sh --install
```

或在仓库根目录：

```bash
bash .agents/skills/dsh-desktop-mac-package/scripts/package-mac-local.sh --install
```

脚本封装：环境检查 → electron-builder（icon 用 `.icns`）→ smoke 验证 → 可选安装。产物 `dsh-plugin-desktop/dist/mac-smoke/DSH Desktop-<版本>-arm64.dmg`。smoke 验证会启动 dist 产物 app，被 LaunchServices 注册成第二个 Launchpad 图标（2026-10-12 事故），脚本在验证后自动杀掉该实例并删除 `dist/mac-smoke/mac-arm64/` 解包产物。**关键教训（2026-10-15 补）**：仅 `lsregister -u` 注销不够——verifier 启动的 dist 实例不会自行退出，运行中的 app 会反复向 LaunchServices 重新注册，导致注销不粘、重启后 Launchpad 图标复现；必须先杀实例再删解包 app。若 dist 里那份 app 正是当前运行实例（`lsof -nP -iTCP:43120` 的进程路径可查证），删除后需从 `/Applications` 重新启动。

官方 `corepack yarn dist:mac-smoke` 需要 Xcode 26 的 `actool`（`build.mac.icon` 指向 Icon Composer 新格式 `.app-icon.icon`）。无 Xcode 26 的机器走上面的绕过路径：`--config.mac.icon=build/app-icon.icns`（仓库已备 `.icns`）+ 手动调 electron-builder，环境变量：

```
DSH_ELECTRON_BUILDER_TRAVERSAL_ONLY=1 CSC_IDENTITY_AUTO_DISCOVERY=false \
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
node node_modules/electron-builder/cli.js --mac dmg --arm64 --publish never \
  --config.mac.notarize=false --config.npmRebuild=false \
  --config.mac.icon=build/app-icon.icns --config.directories.output=<绝对路径>/dist/mac-smoke
```

验证：`DSH_MAC_SMOKE_ARCH=arm64 node scripts/verify-mac-smoke.ts <dist 目录>`（verifier 默认校验 universal 双架构，单架构打包必须带此变量，否则假失败）。手动跑 verifier 后必须：`pkill -f "DSH Desktop.app/Contents/MacOS/DSH"` 杀掉验证启动的实例，再 `rm -rf "<dist 目录>/mac-arm64"`，否则运行中的实例反复重新注册，Launchpad 会一直多一个图标（lsregister -u 对运行中 app 不粘）。

## 安装

```bash
hdiutil attach "<dmg>" -nobrowse
cp -R "/Volumes/DSH Desktop <版本>-arm64/DSH Desktop.app" /Applications/   # 卷名含版本号
hdiutil detach "/Volumes/DSH Desktop <版本>-arm64"
xattr -dr com.apple.quarantine "/Applications/DSH Desktop.app"  # adhoc 签名需去掉隔离属性
```

## 首启排障（打包版卡 recovery 界面 / 43120 不监听）

特征：app 窗口停在 recovery 页，`lsof -iTCP:43120` 无监听，`~/Library/Application Support/DSH Desktop/logs/dsh-2026-10-12.error.log` 有 `Profile dependency migration failed: profile materializer exited unsuccessfully (code=****, signal=null)`（退出码被掩码）。

根因：迁移子进程以 `ELECTRON_RUN_AS_NODE=1` + 内嵌 pnpm 11.8 在 `~/.dsh/profiles/desktop` 跑 `pnpm install --no-frozen-lockfile`，**环境是擦洗过的干净 env**（不继承 shell 的 HTTP_PROXY），pnpm 读到 `~/.npmrc` 的 `socks5://127.0.0.1:7891` 后原生 fetch 失败（ERR_PNPM_META_FETCH_FAIL）。

修复（持久，一次性）：

```bash
mkdir -p ~/.config/pnpm
printf 'proxy=http://127.0.0.1:7890\nhttps-proxy=http://127.0.0.1:7890\n' > ~/.config/pnpm/rc
```

materializer 保留 HOME，pnpm 11 读 XDG 全局 rc，后续迁移自动走通。已验证干净环境从零安装成功。

验证 app 活着：`lsof -nP -iTCP:43120 -sTCP:LISTEN`（Web Host）+ host 日志出现 `bridge.listening`（AA bridge）。token 认证生效时无 token 访问返回 403，token 只在 GUI 显示（日志不含）。

## 排障手段（复现 materializer）

复刻迁移命令拿真实报错（掩码退码的真实原因在这里）：

```bash
GEN=$(ls -d "$HOME/Library/Application Support/DSH Desktop/runtime-commands/generations/"*/ | tail -1)
cd ~/.dsh/profiles/desktop
ELECTRON_RUN_AS_NODE=1 "/Applications/DSH Desktop.app/Contents/MacOS/DSH Desktop" \
  --import "$GEN/private/clear-env.cjs" \
  "/Applications/DSH Desktop.app/Contents/Resources/app/node_modules/pnpm/bin/pnpm.mjs" \
  --config.minimumReleaseAge=0 install --no-frozen-lockfile
```

注意：**漏掉 `ELECTRON_RUN_AS_NODE=1` 会得到 exit 0 的假成功**（Electron 直接进 GUI，pnpm 没执行）。模拟 Finder 干净环境再加 `env -i HOME="$HOME" PATH=/usr/bin:/bin`。

诊断包：`~/Library/Application Support/DSH Desktop/diagnostics/diagnostics-*.zip`（含主进程启动报错）。相关源码：`dsh-plugin-desktop/src/profile-materializer.ts`、`src/profile.ts` 的 `profileDependencyMigrationRequired`（迁移通过条件：`.modules.yaml` 的 nodeLinker=hoisted + packageManager≥pnpm@10 + virtualStoreDirMaxLength=120，lockfile 的 autoInstallPeers=false）。

## 升级已有安装

```bash
cd <repo> && git pull && git submodule update --init --recursive
pkill -f "DSH Desktop.app"; sleep 2
corepack yarn install --immutable && corepack yarn build
bash .agents/skills/dsh-desktop-mac-package/scripts/package-mac-local.sh --install
open "/Applications/DSH Desktop.app"
```

安装包不再需要首启排障（profile 已 materialize，仅在 lockfile/工作区契约变化时才重新迁移）。

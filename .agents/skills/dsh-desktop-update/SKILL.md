---
name: dsh-desktop-update
description: 本仓库（dsh-desktop）一键更新已安装的 mac app。用户说「更新 dsh-desktop」「升级 DSH Desktop」「检查有没有新版本」或要在上游发布新版本后刷新本机安装时使用。流程：预检 → git pull → submodule → install → build → 打包安装 → 启动验证，全链路一条命令。
---

# DSH Desktop 一键更新

把「拉上游 → 重建 → 重新打包 → 换掉 /Applications 里的 app → 确认能跑」收进一条命令。打包细节（.icns 绕 actool、smoke 验证）由姊妹 skill **dsh-desktop-mac-package** 承担，本 skill 只管编排。

## 使用

```bash
# 只看远端有没有更新，不动任何东西
bash .agents/skills/dsh-desktop-update/scripts/update.sh --check

# 完整更新（默认装完自动启动并验证）
bash .agents/skills/dsh-desktop-update/scripts/update.sh

# 更新但不启动
bash .agents/skills/dsh-desktop-update/scripts/update.sh --no-start
```

脚本在仓库根目录之外也能跑（自行定位仓库根）。

## 脚本做什么

| 步骤 | 说明 |
|------|------|
| 预检 | kill 运行中的 app（GUI 占用 node_modules 会损坏 install/打包）；工作树脏则拒绝执行（防改动丢失） |
| pull | `fetch --prune` → `pull --rebase`（冲突即中止并提示 `git rebase --abort`） |
| submodule | `git submodule update --init --recursive`（deepseek-harness 钉在 pinned 版本） |
| install | `corepack yarn install --immutable` + 残骸探针（vite/dshmarket 空目录会被 yarn 静默跳过） |
| build | `corepack yarn build`（内含 market:prepare，会刷新 dshmarket 依赖版本） |
| 打包安装 | 复用 dsh-desktop-mac-package 的脚本 `--install`（electron-builder + smoke 验证 + /Applications 覆盖 + 去隔离） |
| 启动验证 | `open` app 后轮询 Web Host 端口 43120（最长 60s），失败时打出错误日志尾部 |

## 约定与已知行为

- **安装方式约定（2026-10-12）**：本机更新一律走本 skill 的本地打包安装流程（pull → install → build → 打包覆盖 /Applications）；不再使用官方 GitHub Release 的正式版安装包。除非用户明确要求，不要提议下载 Release DMG。
- **market 刷新提交**：`yarn build` 里 market:prepare 更新 dshmarket 版本（package.json + yarn.lock）。更新完检查 `git status`，有刷新就提交（历史惯例：`chore: 刷新 dshmarket 至 x.y.z（market:prepare）`）。
- **远端无新提交不是错误**：本地领先未推送提交时脚本跳过 pull 照常重建——用于改了本地桌面代码后重新打包。
- **43120 未监听的误报**：在 app 设置里改过 Web 端口时验证会超时报警，属预期；端口默认 43120。
- **首次安装**（机器上还没有 app）走姊妹 skill dsh-desktop-mac-package 的完整流程，含首启 Profile 迁移排障；已安装机器更新时 profile 已 materialize，不会再触发迁移。
- 本 skill 假定 macOS arm64 + Node 24 + Corepack；环境问题（代理、残骸、Xcode）见姊妹 skill 的「环境红线」与「首启排障」。

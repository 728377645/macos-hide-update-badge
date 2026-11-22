---
name: macos-hide-update-badge
description: 屏蔽 macOS 系统更新的红色角标与「有软件更新可用」提示。当用户抱怨 Mac 出现更新小红点、Dock 图标数字角标、系统设置侧栏「有软件更新可用」横幅、反复弹出的升级通知，或表示「不想升级系统 / 别老提示我更新」时使用。重点覆盖 macOS Sequoia 15 因 SIP 造成的清不掉问题。
agent_created: true
---

# 屏蔽 macOS 系统更新红点

## 用途

消除 macOS 的系统更新提示（Dock 角标、系统设置侧栏横幅、通知），同时保留静默安全更新。

真正的难点不是"关掉自动检查"，而是让受 SIP 保护的 `softwareupdated` 守护进程不再报告可用更新。仅靠 `defaults write` 关开关，红点会反复复活。

## 何时使用

- 用户说「屏蔽 mac 的系统更新小红点」「别提示我升级」「关掉更新角标」
- 系统设置左侧栏出现「有软件更新可用」并带红色数字
- Dock 里「系统设置」图标右上角有红色数字
- 用户不想升级系统版本，但希望保留安全补丁

## 三条核心原则

1. **先定位，再动手。** 红点有三种完全不同的机制（Dock 角标 / 侧栏横幅 / 通知），清错地方毫无效果。必须先截屏确认位置。
2. **精准屏蔽，绝不全封。** 只屏蔽 `gdmf.apple.com`（macOS 大版本通道），放开 `swscan` / `swdist` / `swquery`。全封会让扫描失败并回落到受 SIP 保护的本地缓存，红点反而永远清不掉——这是本任务最容易走错的一步。
3. **以截屏为验收标准。** 命令行状态正常不代表界面干净，必须 `screencapture` 后读图确认。

## 工作流

### 第 1 步：定位红点

询问用户位置，或直接截屏判断：

```bash
osascript -e 'tell application "System Settings" to activate'; sleep 3
screencapture -x /tmp/diag.png
```

用 Read 工具查看该图，确认属于哪一种：Dock 角标、侧栏横幅、通知。需要完整状态时运行：

```bash
sh scripts/diagnose.sh
```

### 第 2 步：执行修复

沙箱内 `sudo` 不可用（`operation not permitted: sudo`），必须通过 osascript 提权，用户输一次密码即可：

```bash
SKILL_DIR="$HOME/.workbuddy/skills/macos-hide-update-badge"
osascript -e "do shell script \"/bin/sh $SKILL_DIR/scripts/apply.sh\" with administrator privileges"
```

`scripts/apply.sh` 依次完成：备份 hosts → 只添加 `gdmf` 屏蔽 → 关闭自动检查与自动下载 → 保留安全更新开关 → 清理缓存键 → 清空 catalog 缓存 → 重启界面进程 → 输出验证结果。

### 第 2.5 步：单独清理用户级角标（必须以普通用户身份）

角标属于用户偏好域，放进 root 脚本里写不可靠（拿不到 GUI 上下文）。**不要**合并进上面的提权调用，直接在普通权限下执行：

```bash
defaults write com.apple.systempreferences AttentionPrefBundleIDs \
  -dict "com.apple.preferences.softwareupdate" 0
killall Dock
```

验证写入结果：`defaults read com.apple.systempreferences` 应显示 `"com.apple.preferences.softwareupdate" = 0;`

### 第 3 步：验证

三条同时满足才算完成：

1. `softwareupdate -l` 输出 `No new software available.`（若是「错误的URL」，说明屏蔽过度，检查 hosts 是否残留 `swscan` 屏蔽）
2. `LastRecommendedUpdatesAvailable = 0`，`LastResultCode` 为 0 或 2
3. 截屏确认侧栏横幅消失

若前两条已满足但横幅仍在，说明守护进程内存未刷新。此时**不要**尝试 kill 或 `launchctl bootout`（SIP 必拒），可让用户重启一次电脑。

### 第 4 步：处理顽固情况

- **`RecommendedUpdates` 里反复出现 Safari 条目**：本地 `/Library/Updates/ProductMetadata.plist` 缓存着旧版本。建议安装 Safari 更新（独立更新，不改变系统版本），装完条目自然消失。安装前需临时解除屏蔽，装完再加回，否则下载不到：

  ```bash
  osascript -e 'do shell script "softwareupdate -i --safari-only" with administrator privileges'
  ```

- **横幅显示的是 macOS 大版本（15.x / 26.x）**：`gdmf` 屏蔽应已生效；若仍出现，复查 hosts 与 `dscacheutil -q host -a name gdmf.apple.com` 的解析结果。

- **用户既不安装更新、也不接受横幅**：该横幅由受 SIP 保护的文件驱动，只有关闭 SIP 才能删除。明确告知安全代价后由用户决定，不要擅自建议关闭 SIP。

## 硬性约束

- **禁止用 `sed 'addr,+N'` 改 hosts**：BSD sed 不支持该语法，会静默失败（grep 能匹配但什么都没删）。改用 `awk` 或 `grep -v` 重写文件，改完必须用 `tail /etc/hosts` 与 `dscacheutil -q host -a name <domain>` 双重验证，不要只看退出码。
- **禁止重启 `softwareupdated`**：`kill -9`、`launchctl kickstart -k`、`launchctl kill`、`launchctl bootout` 全部被 SIP 拒绝（错误码 150）。
- **禁止删除 `/Library/Updates/ProductMetadata.plist`**：目录带 `restricted` 标志，root 也写不进。
- **`AttentionPrefBundleIDs` 必须写成 dict**：`-dict "com.apple.preferences.softwareupdate" 0`；整数 `0` 在 Ventura+ 已失效。
- **改 hosts 后必须刷 DNS**：`dscacheutil -flushcache; killall -HUP mDNSResponder`。

详细机制、SIP 实测错误码、已证伪方案清单见 `references/mechanism.md`——红点清不掉时先读它，可避免重复踩坑。

## 回滚

```bash
SKILL_DIR="$HOME/.workbuddy/skills/macos-hide-update-badge"
osascript -e "do shell script \"/bin/sh $SKILL_DIR/scripts/rollback.sh\" with administrator privileges"
```

移除 hosts 屏蔽、恢复自动检查、清理角标设置。原始 hosts 备份保留在 `/etc/hosts.hub.bak`。

## 汇报要点

完成后向用户说明：

- 红点具体位置与根因（不只是"关了个开关"）
- 当前策略：只挡大版本，Safari 等小更新仍可正常安装
- 安全更新（XProtect / 系统数据文件）保持开启
- 将来发布新版 Safari 时红点会再次出现，属正常现象
- 回滚方法

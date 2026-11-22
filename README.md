# macos-hide-update-badge

屏蔽 macOS 系统更新的红点与「有软件更新可用」提示，**同时保留静默安全更新**。

专门解决 macOS Sequoia（15.x）+ SIP 环境下「怎么清都清不掉」的小红点问题。

```
系统设置 · 左侧栏
  Apple 账户
  有软件更新可用  ①   ← 干掉这一行
  Wi-Fi
```

---

## 为什么普通的办法没用

网上流传的做法通常是 `defaults write ... AutomaticCheckEnabled -bool false` 加 `killall Dock`。这在 Sequoia 上**只能管一会儿**——红点过不了多久就自己回来了。

真正的原因有三层：

| 层 | 机制 | 只管这一层的结果 |
|---|---|---|
| ① 自动扫描 | `AutomaticCheckEnabled` 开关 | 后台不扫了，但一打开「系统设置」页面仍会主动查一次 |
| ② 用户偏好 | `AttentionPrefBundleIDs`（Dock 角标） | 只清 Dock 图标，侧栏横幅不受影响 |
| ③ 守护进程内存 | `softwareupdated` 报告的可用更新列表 | **真正决定横幅和角标的数据源** |

第三层是关键。`softwareupdated` 受 SIP 保护，**无法重启**：

| 尝试 | 结果 |
|---|---|
| `kill -9 <pid>` | `Operation not permitted` |
| `launchctl kickstart -k` | 无效，PID 不变 |
| `launchctl kill SIGKILL` | 被拒 |
| `launchctl bootout` | `150: Operation not permitted while System Integrity Protection is engaged` |

日志里那个 `1` 就活在它的内存里，改磁盘上任何文件它都不看。

### 最反直觉的一点：全封 hosts 反而更糟

直觉上会想到把 Apple 更新域名全屏蔽掉。实测**恰恰相反**：

- 全封 `gdmf` / `swscan` / `swdist` / `swquery` → 扫描**失败**（`LastResultCode = 100`，`错误的URL`）
- 扫描失败后，系统**回落到本地缓存** `/Library/Updates/ProductMetadata.plist`
- 那是个受 SIP 保护的 106KB 文件，`drwxr-xr-x@ root wheel restricted`，连 root 都删不掉
- 于是红点永远清不掉，重启也没用

正确做法是 **精准屏蔽，绝不全封**：只挡 `gdmf.apple.com`（macOS 大版本走这条通道），让 catalog 扫描能**成功**返回 `No new software available.`。扫描一旦成功，守护进程的内存状态就被真实刷新，横幅才失去存在理由。

---

## 用法

### 1. 先诊断（只读，不改任何东西）

```bash
sh scripts/diagnose.sh
```

输出当前红点来源、hosts 状态、缓存计数、`softwareupdated` 的 PID 与 SIP 状态。

### 2. 应用修复（需输一次密码）

```bash
osascript -e "do shell script \"/bin/sh $PWD/scripts/apply.sh\" with administrator privileges"
```

脚本会依次：备份 hosts → 只加一条 `gdmf` 屏蔽 → 刷 DNS → 关自动检查/下载 → **保留**安全更新开关 → 清缓存键 → 清 HTTP 缓存 → 试图重置 Dock 角标 → 重启界面进程 → 跑一次 `softwareupdate -l` 验证。

### 3. 清理用户级角标（普通权限，别绕过）

Dock 角标属于用户偏好域，root 脚本写不可靠。单独跑：

```bash
defaults write com.apple.systempreferences AttentionPrefBundleIDs \
  -dict "com.apple.preferences.softwareupdate" 0
killall Dock
```

> `-dict "com.apple.preferences.softwareupdate" 0` 这个写法不能省成整数 `0`——Ventura 之后整数写法已失效。

### 4. 验证

三条同时满足才算成功：

```bash
softwareupdate -l                      # 应为 No new software available.
defaults read /Library/Preferences/com.apple.SoftwareUpdate | grep LastRecommended
# 应为 LastRecommendedUpdatesAvailable = 0
screencapture -x /tmp/v.png            # 截屏确认侧栏横幅消失
```

如果前两条过了但横幅还在，说明守护进程内存没刷新，**重启一次电脑**即可（冷启动会重新读状态）。

---

## 保留了什么

这是本方案和「野蛮屏蔽」的主要区别：

| 项目 | 状态 | 说明 |
|---|---|---|
| macOS 大版本提示（15.x / 26.x） | ❌ 屏蔽 | `gdmf.apple.com` |
| Safari 等小更新 | ✅ 正常 | 仍可查询安装 |
| XProtect 安全响应 | ✅ 正常 | `CriticalUpdateInstall` 保持开启 |
| 系统数据文件 | ✅ 正常 | `ConfigDataInstall` 保持开启 |
| App Store 自动更新 | ❌ 关闭 | 可自行改回 |
| App Store 手动下载安装 | ✅ 正常 | |

**没有屏蔽** `mesu.apple.com` / `xp.apple.com`，所以安全补丁照常静默安装——这类更新不会产生红点，没必要一起砍掉。

---

## 回滚

```bash
osascript -e "do shell script \"/bin/sh $PWD/scripts/rollback.sh\" with administrator privileges"
```

移除 hosts 屏蔽块、恢复自动检查、清角标设置。脚本只删自己标记的那一块，**不会误伤** hosts 里其它规则。

原始备份在 `/etc/hosts.hub.bak`（仅首次运行写入，之后不覆盖）。

想临时升级 macOS 时，也可以只解除屏蔽：

```bash
sudo awk '!/=== block macOS software update/{f=1} f{print} /^0\.0\.0\.0 gdmf/{f=0}' /etc/hosts > /tmp/h
sudo cat /tmp/h > /etc/hosts
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

---

## 已知限制

- **重装系统 / 大版本升级后需重新运行**，hosts 会被系统更新重置。
- **Apple 发布新版 Safari 时红点会回来**，这属于正常可安装更新（几十 MB），装了就好。
- **不改 SIP、不删受保护文件**。如果「软件更新」页面本身显示了横幅，而上述手段全部无效，剩下唯一的路是关闭 SIP 删除 `ProductMetadata.plist`——**不建议**，只为消一个提示而降低整机安全防护不划算。
- **不保证未来 macOS 版本仍然适用**。机制基于 Sequoia 15.5 实测，Apple 改实现后可能失效。

---

## 作为 WorkBuddy 技能使用

本仓库同时是一个 [WorkBuddy](https://www.workbuddy.cn) Skill。装上后说「屏蔽系统更新红点」「别提示我升级」就会自动触发：

```bash
git clone https://github.com/728377645/macos-hide-update-badge.git \
  ~/.workbuddy/skills/macos-hide-update-badge
```

`SKILL.md` 里有完整工作流（含「先截屏定位，再动手」的强制步骤），`references/mechanism.md` 记录了机制细节、SIP 实测错误码和**已证伪方案清单**——红点清不掉时先读它，能省掉重复踩坑。

---

## 目录结构

```
├── SKILL.md                 技能定义：三条核心原则 + 工作流 + 硬性约束
├── scripts/
│   ├── diagnose.sh          只读诊断
│   ├── apply.sh             应用修复（需 root）
│   └── rollback.sh          回滚
└── references/
    └── mechanism.md         机制详解、SIP 错误码、已证伪方案
```

---

## 免责声明

脚本会修改 `/etc/hosts` 与系统级偏好设置。虽然带备份且可完整回滚，但**请先读懂再运行**。因关闭更新提示导致长期未安装系统安全补丁的风险由使用者自行承担——建议每隔一两个月手动检查一次系统更新。

## License

MIT

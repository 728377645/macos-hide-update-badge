# macOS 更新红点的机制与硬限制

本文件记录 macOS 15 Sequoia 下实测得到的机制结论。遇到红点清不掉时先读这里，避免重复踩坑。

## 一、红点有三种，机制完全不同

| 位置 | 机制 | 有效的处理方式 |
|---|---|---|
| Dock 图标右上角数字 | `com.apple.systempreferences` 的 `AttentionPrefBundleIDs` | 写成 **dict**：`-dict "com.apple.preferences.softwareupdate" 0`。整数写法 `0` 在 Ventura+ 已失效 |
| 系统设置左侧栏「有软件更新可用」横幅 | `SoftwareUpdateSettingsExtension` 读取 `softwareupdated` 的**内存态** | 只能让守护进程成功扫描出 0 个更新（见下） |
| 右上角通知横幅 | 通知中心 usernoted | 关闭系统设置的通知权限，或清理通知中心 |

**排查顺序：先截图确认位置，再动手。** 三种机制互不相通，清错地方完全无效。

## 二、侧栏横幅的数据链路

```
Apple 服务器 ──> softwareupdated（受 SIP 保护，运行期无法重启）
                        │
                        ├─ legacy 扫描：swscan.apple.com 的 .sucatalog.gz（Safari 等）
                        └─ MSU 扫描：gdmf.apple.com（macOS 大版本）
                        │
                        ▼
                SoftwareUpdateSettingsExtension ──> 侧栏横幅 + 红色数字
```

关键事实：

- 横幅读的是守护进程**内存**，不是 plist。证据：`softwareupdate -l --no-scan` 仍会吐出缓存的更新项。
- 因此改 `/Library/Preferences/com.apple.SoftwareUpdate.plist` 里的任何键，对已运行的守护进程**无效**。
- 扫描**失败**时，守护进程不会清零，而是回落到 `/Library/Updates/ProductMetadata.plist` 的本地缓存 → 红点顽固复现。

## 三、SIP 造成的硬限制（全部实测）

| 操作 | 结果 |
|---|---|
| `kill -9 <softwareupdated pid>` | `Operation not permitted` |
| `launchctl kickstart -k system/com.apple.softwareupdated` | 无效果，PID 不变 |
| `launchctl kill SIGKILL system/com.apple.softwareupdated` | 无效果 |
| `launchctl bootout system/com.apple.softwareupdated` | `Boot-out failed: 150: Operation not permitted while System Integrity Protection is engaged` |
| 写入或删除 `/Library/Updates/` 下文件 | 被拒绝（目录带 `restricted` 标志，`ls -laO` 可见） |
| 清理 `/var/db/SoftwareUpdate/Library/Caches/` | **可以**，但只是 NSURLCache，清不掉 `ProductMetadata.plist` |

结论：**不要试图重启或杀死 `softwareupdated`**。运行期唯一的办法是让它的下一次扫描成功返回零更新。

## 四、核心策略：精准屏蔽，而非全封

这是本技能最关键的一条经验。

**错误做法**：把 `gdmf` / `swscan` / `swdist` / `swquery` 全部指向 `0.0.0.0`。

后果：扫描直接失败（`LastResultCode = 100`、`NSURLErrorDomain -1000 错误的URL`），守护进程回落到 `ProductMetadata.plist` 的旧缓存，红点**每次都会复活**，且怎么清都清不掉。此时还会因为 `CatalogURL` 无法通过重启生效而陷入死循环。

**正确做法**：只屏蔽 `gdmf.apple.com`（macOS 大版本走这条 MSU 通道），放开 `swscan` / `swdist` / `swquery`。

效果：

- legacy 扫描（Safari 等小更新）能正常联网，若已是最新则如实返回 `No new software available.`
- MSU 扫描被 `gdmf` 挡住，`majorPrimaryDescriptor: (null)`，13GB 大版本提示进不来
- 守护进程内存态刷新为 0 → 横幅消失，且后续每次打开系统设置都保持干净

## 五、已证伪的方案，不要重复尝试

1. **`softwareupdate --ignore`**：Sequoia 已移除该参数（`--help` 里不存在）。
2. **`CatalogURL` 指向本地空 catalog**：Sequoia 不接受 `file://`；且该键只在守护进程启动时读取，而 SIP 不让重启守护进程。
3. **删除 `ProductMetadata.plist`**：受 `restricted` 保护，root 也删不掉。
4. **写 `LastRecommendedUpdatesAvailable = 0`**：写入成功但横幅不受影响（它不读这个键）。
5. **只清 `AttentionPrefBundleIDs`**：只对 Dock 角标有效，对侧栏横幅无效。
6. **重启电脑**：如果 `ProductMetadata.plist` 里仍有更新条目，重启后照样复发。

## 六、BSD sed 陷阱

macOS 自带的 `sed` 是 BSD 版本，**不支持 GNU 的 `addr,+N` 地址范围**：

```sh
# 不会报错，但静默什么都不删 —— 极易误判为"已生效"
sed -i '' '/marker/,+4d' /etc/hosts
```

修改 hosts 必须改用 `awk` 或 `grep -v` 重写文件，并且**改完要用 `tail` / `dscacheutil -q host` 验证**，不要只看命令退出码。

## 七、权限与执行方式

- 沙箱内 `sudo` 不可用（`operation not permitted: sudo`）。
- 需要 root 的操作统一用：
  ```sh
  osascript -e 'do shell script "/bin/sh /path/script.sh" with administrator privileges'
  ```
  这会弹出系统密码框，用户输一次密码即可执行整段脚本，避免逐条授权。
- 修改 hosts 后必须 `dscacheutil -flushcache` + `killall -HUP mDNSResponder`，否则 DNS 仍返回旧结果。

## 八、验收标准

改完必须同时满足：

1. `softwareupdate -l` 输出 `No new software available.`（而不是「错误的URL」）
2. `LastResultCode` 为 `0` 或 `2`，`LastRecommendedUpdatesAvailable = 0`
3. 截图确认系统设置侧栏的「有软件更新可用」横幅消失

第 3 条必须靠截屏验证（`screencapture -x` + 读图），不能靠命令行推断。

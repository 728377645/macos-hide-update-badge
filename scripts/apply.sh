#!/bin/sh
# 应用 macOS 更新红点屏蔽（需要 root）
# 用法:
#   osascript -e 'do shell script "/bin/sh /path/to/scripts/apply.sh" with administrator privileges'
#
# 策略：只屏蔽 gdmf.apple.com（挡 macOS 大版本 MSU 更新），放开 swscan/swdist/swquery
# 让 legacy 扫描能成功返回"No new software available"，从而刷新守护进程内存态。

HOSTS=/etc/hosts
P=/Library/Preferences/com.apple.SoftwareUpdate
MARK="# === block macOS software update (hide-update-badge) ==="

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: 需要 root。请用 osascript with administrator privileges 包裹执行。" >&2
  exit 1
fi

echo "=== 1. 备份 hosts ==="
[ -f /etc/hosts.hub.bak ] || cp "$HOSTS" /etc/hosts.hub.bak
echo "备份: /etc/hosts.hub.bak"

echo "=== 2. 清理旧屏蔽条目 ==="
# 只删除带标记的行及其后连续的 0.0.0.0 行，不动宿主其它 hosts 规则
# 陷阱：BSD sed 不支持 addr,+N 地址范围，会静默失败；awk 才可靠
awk '/=== block macOS software update/{skip=1; next}
     skip && /^0\.0\.0\.0 /{next}
     {skip=0; print}' "$HOSTS" > /tmp/hosts.hub.new
cat /tmp/hosts.hub.new > "$HOSTS"

echo "=== 3. 仅添加 gdmf 屏蔽 ==="
{
  printf '\n'
  printf '%s\n' "$MARK"
  printf '%s\n' "0.0.0.0 gdmf.apple.com"
} >> "$HOSTS"
tail -3 "$HOSTS"

echo "=== 4. 刷新 DNS ==="
dscacheutil -flushcache 2>/dev/null
killall -HUP mDNSResponder 2>/dev/null
sleep 1

echo "=== 5. 关闭自动检查/下载（保留安全更新）==="
defaults write "$P" AutomaticCheckEnabled -bool false
defaults write "$P" AutomaticDownload -bool false
defaults write "$P" AutomaticallyInstallMacOSUpdates -bool false
defaults write "$P" CriticalUpdateInstall -bool true
defaults write "$P" ConfigDataInstall -bool true

echo "=== 6. 清缓存键 ==="
for k in RecommendedUpdates LastRecommendedUpdatesAvailable LastUpdatesAvailable \
         LastFullSuccessfulDate LastSuccessfulDate LastSuccessfulBackgroundMSUScanDate \
         CatalogURL; do
  defaults delete "$P" "$k" 2>/dev/null
done
defaults write "$P" LastRecommendedUpdatesAvailable -int 0
defaults write "$P" LastUpdatesAvailable -int 0

echo "=== 7. 清 HTTP / catalog 缓存 ==="
rm -rf /var/db/SoftwareUpdate/Library/Caches/* 2>/dev/null
rm -rf /var/db/SoftwareUpdate/Library/HTTPStorages/* 2>/dev/null

echo "=== 8. 清用户级 Dock 角标 ==="
# Sequoia 必须写成 dict，整数写法无效
# 注意：root 脚本写用户偏好域不可靠（拿不到 GUI 上下文），失败时由调用方以普通用户身份补执行
CU=$(stat -f %Su /dev/console 2>/dev/null)
if [ -n "$CU" ] && [ "$CU" != "root" ]; then
  if sudo -u "$CU" /usr/bin/defaults write com.apple.systempreferences \
       AttentionPrefBundleIDs -dict "com.apple.preferences.softwareupdate" 0 2>/dev/null; then
    echo "已写入 $CU 的 AttentionPrefBundleIDs"
  else
    echo "SKIP: 请在普通用户下执行 defaults write com.apple.systempreferences AttentionPrefBundleIDs -dict com.apple.preferences.softwareupdate 0"
  fi
else
  echo "SKIP: 无法确定登录用户，请手动清理角标"
fi

echo "=== 9. 重启界面进程 ==="
killall -HUP cfprefsd 2>/dev/null
pkill -f SoftwareUpdateSettingsExtension 2>/dev/null
killall "System Settings" 2>/dev/null
killall Dock 2>/dev/null
sleep 2

echo "=== 10. 验证（关键：应输出 No new software available）==="
softwareupdate -l 2>&1 | head -6

echo
echo "完成。请打开系统设置确认侧边栏横幅是否消失。"
echo "如仍有横幅，说明守护进程内存未刷新，需重启电脑一次。"
exit 0

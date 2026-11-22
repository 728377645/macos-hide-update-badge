#!/bin/sh
# 回滚：恢复系统更新检测（需要 root）
# 用法: osascript -e 'do shell script "/bin/sh /path/to/scripts/rollback.sh" with administrator privileges'

HOSTS=/etc/hosts
P=/Library/Preferences/com.apple.SoftwareUpdate

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: 需要 root。" >&2
  exit 1
fi

echo "=== 1. 移除 hosts 屏蔽 ==="
awk '/=== block macOS software update/{skip=1; next}
     skip && /^0\.0\.0\.0 /{next}
     {skip=0; print}' "$HOSTS" > /tmp/hosts.hub.rb
cat /tmp/hosts.hub.rb > "$HOSTS"

echo "=== 2. 刷新 DNS ==="
dscacheutil -flushcache 2>/dev/null
killall -HUP mDNSResponder 2>/dev/null
sleep 1

echo "=== 3. 恢复自动检查更新 ==="
defaults write "$P" AutomaticCheckEnabled -bool true
defaults write "$P" AutomaticDownload -bool true
defaults write "$P" AutomaticallyInstallMacOSUpdates -bool true
defaults write "$P" CriticalUpdateInstall -bool true
defaults write "$P" ConfigDataInstall -bool true
killall -HUP cfprefsd 2>/dev/null

echo "=== 4. 清理 Dock 角标设置 ==="
CU=$(stat -f %Su /dev/console 2>/dev/null)
if [ -n "$CU" ] && [ "$CU" != "root" ]; then
  CU_UID=$(id -u "$CU" 2>/dev/null)
  launchctl asuser "$CU_UID" sudo -u "$CU" /usr/bin/defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null
  echo "已清除 $CU 的角标设置"
fi

echo "=== 5. 重启界面 ==="
killall Dock 2>/dev/null
killall "System Settings" 2>/dev/null
sleep 2

echo "=== 6. 验证（应能列出可用更新）==="
softwareupdate -l 2>&1 | head -10

echo
echo "已回滚。原始备份在 /etc/hosts.hub.bak（如存在）。"
exit 0

#!/bin/sh
# 诊断 macOS 更新红点来源（只读，不需要 root）
# 用法: sh diagnose.sh

echo "================ macOS 版本 ================"
sw_vers
echo
echo "================ SIP 状态 ================"
csrutil status
echo
echo "================ Safari 版本 ================"
defaults read /Applications/Safari.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "读取失败"
echo
echo "================ 可用更新（联网查询，可能耗时）================"
softwareupdate -l 2>&1 | head -20
echo
echo "================ 系统级更新偏好 ================"
defaults read /Library/Preferences/com.apple.SoftwareUpdate 2>&1 | grep -E \
  "AutomaticCheckEnabled|AutomaticDownload|AutomaticallyInstallMacOSUpdates|CriticalUpdateInstall|ConfigDataInstall|CatalogURL|LastRecommendedUpdatesAvailable|LastUpdatesAvailable|LastResultCode" \
  || echo "（无相关键）"
echo
echo "================ 缓存的更新条目 ================"
defaults read /Library/Preferences/com.apple.SoftwareUpdate 2>&1 | sed -n '/RecommendedUpdates/,/^    );/p' | grep -E "Display Name|Display Version" | head -12
echo
echo "================ Dock 角标（用户级，需在普通用户下执行本脚本）================"
defaults read com.apple.systempreferences 2>&1 | head -10
echo
echo "================ hosts 屏蔽状态 ================"
grep -nE "apple\.com" /etc/hosts 2>/dev/null || echo "（无 apple 相关条目）"
echo
echo "================ SIP 保护的文件 ================"
ls -laO /Library/Updates/ 2>&1 | head -6
echo
echo "================ 相关进程 ================"
launchctl print system/com.apple.softwareupdated 2>&1 | grep -E "pid =|state ="
pgrep -fl SoftwareUpdateSettingsExtension 2>/dev/null || echo "（扩展未运行）"
echo
echo "诊断完成"

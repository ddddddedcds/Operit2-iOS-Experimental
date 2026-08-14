#!/bin/sh
# roothide（Relaxin / Bootstrap）全量回归检查脚本
# 对应 HANDOVER 8.7 的五项风险 + 冷启动。用法（root 权限）：
#   scp roothide_regress.sh mobile@<ip>:/tmp/
#   ssh mobile@<ip> 'echo <PASSWORD> | sudo -S sh /tmp/roothide_regress.sh'
set -u

echo "================ 0. 环境 ================"
echo "JBROOT env: ${JBROOT:-<unset>}"
JBROOT_PHYS=""
for d in /var/containers/Bundle/Application/.jbroot-*; do
  [ -d "$d" ] && JBROOT_PHYS="$d" && break
done
echo "物理 jbroot: ${JBROOT_PHYS:-<未找到>}"
if [ -L /var/jb ]; then
  echo "/var/jb 符号链接 → $(readlink /var/jb)"
elif [ -d /var/jb ]; then
  echo "/var/jb 是目录"
else
  echo "/var/jb 不存在"
fi

echo "================ 1. daemon（8.7 风险1: 信任链）================"
if ps aux | grep -q "[o]perit_agent_daemon"; then
  echo "  ✓ daemon 运行中:"
  ps aux | grep "[o]perit_agent_daemon" | head -2
else
  echo "  ✗ daemon 未运行（检查 postinst ldid 重签是否成功：/var/mobile/.operit/logs/postinst.log）"
fi
echo "-- 数据目录下 agent.log --"
for base in /var/mobile/.operit ${JBROOT_PHYS}/var/mobile/.operit; do
  [ -f "$base/logs/agent.log" ] && echo "  ✓ $base/logs/agent.log ($(wc -c < "$base/logs/agent.log" 2>/dev/null) bytes, tail: $(tail -1 "$base/logs/agent.log" 2>/dev/null))"
done
echo "-- postinst 日志 --"
for base in /var/mobile/.operit ${JBROOT_PHYS}/var/mobile/.operit; do
  [ -f "$base/logs/postinst.log" ] && echo "  ✓ $base/logs/postinst.log（ldid 重签结果见其中 daemon signed 行）" && grep -E "daemon signed|ldid" "$base/logs/postinst.log" 2>/dev/null | tail -3
done

echo "================ 2. 数据目录双视图一致性（8.7 风险2）================"
echo "-- jbroot 视图 /var/mobile/.operit --"
ls /var/mobile/.operit/ 2>/dev/null || echo "  (不存在)"
echo "-- 物理 ${JBROOT_PHYS}/var/mobile/.operit --"
ls ${JBROOT_PHYS}/var/mobile/.operit/ 2>/dev/null || echo "  (不存在)"
echo "-- 关键数据文件（两个视图各查一次；修复后应都在同一物理目录）--"
for f in notifications.json usage.json app_lock.plist config.plist logs/tweak.log; do
  found=0
  for base in /var/mobile/.operit ${JBROOT_PHYS}/var/mobile/.operit; do
    if [ -e "$base/$f" ]; then
      echo "  ✓ $base/$f ($(wc -c < "$base/$f" 2>/dev/null) bytes)"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && echo "  - $f 未找到（该功能尚未触发）"
done

echo "================ 3. 设置面板 / CC 模块（8.7 风险4）================"
ls -d /Library/PreferenceLoader/Preferences/operitPrefs.bundle 2>/dev/null && echo "  ✓ operitPrefs.bundle 已安装" || echo "  ✗ prefs bundle 缺失"
ls -d /Library/CCSupport/OperitCC.bundle 2>/dev/null && echo "  ✓ OperitCC.bundle 已安装" || echo "  ✗ CC bundle 缺失"
echo "  （显示与否需进设置/控制中心人工确认）"

echo "================ 4. app 与 tweak（8.7 风险3/5）================"
ls -d /Applications/Runner.app 2>/dev/null && echo "  ✓ app 已安装" || echo "  ✗ app 缺失"
echo "  tweak 注入状态：装完 respring 后，SpringBoard 的 tweak.log 有输出即注入成功"
for base in /var/mobile/.operit ${JBROOT_PHYS}/var/mobile/.operit; do
  [ -f "$base/logs/tweak.log" ] && echo "  ✓ tweak.log: $base/logs/tweak.log（tail: $(tail -1 "$base/logs/tweak.log" 2>/dev/null)）"
done

echo "================ 5. 冷启动测速（预期：roothide 无 60s）================"
cat <<'EOF'
  1) killall -9 Runner（或上滑杀）
  2) 点开 Operit2，计时到界面出现 —— roothide 用 stock dyld，预期秒级
  3) 若秒开 → 60s 问题只在 Dopamine，roothide 可作主平台
EOF

echo "================ 6. 功能冒烟（人工/后续）================"
cat <<'EOF'
  通知拦截/记录：让任一 app 发一条通知 → 检查 notifications.json 新增
  应用锁：AI 或设置里 lock 一个 app → 打开被锁 app 见屏蔽页
  Siri：长按侧边键说一句 → 卡片出现 + 会话同步（8.7 风险5，需真机）
  权限：AI 调 contacts list → 弹授权 → 返回数据
EOF

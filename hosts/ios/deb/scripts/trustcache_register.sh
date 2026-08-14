#!/bin/sh
# 冷启动 60s 实验（HANDOVER §15）：把 Runner.app 全部 Mach-O 注册进 Dopamine trustcache
#
# 假设：60s = AMFI 对 ~726 个 embedded framework 逐个做 cdhash 慢路径验证
# （与 daemon 当初必须 trustcache 注册才免 -9 同一机制）。若成立，
# 注册后冷启动应大幅下降。
#
# 用法（rootless 设备，需 root 权限；mobile 有 sudo 即可）：
#   scp trustcache_register.sh mobile@<ip>:/tmp/
#   ssh mobile@<ip> 'echo <PASSWORD> | sudo -S sh /tmp/trustcache_register.sh'
#
# 注意：rootless 的 deb 从不打包 postinst（packdeb.py 仅 roothide 带），
# 所以本脚本是实验的唯一通道。注册对设备是持久内核状态（重启后仍有效，
# Dopamine 会把已注册项持久化；若重启丢失则重跑本脚本）。

set -u

# --- 定位 jbctl（Dopamine）---
JBCTL="$(command -v jbctl 2>/dev/null || true)"
[ -z "$JBCTL" ] && [ -x /var/jb/basebin/jbctl ] && JBCTL=/var/jb/basebin/jbctl
[ -z "$JBCTL" ] && [ -x /basebin/jbctl ] && JBCTL=/basebin/jbctl
if [ -z "$JBCTL" ]; then
  echo "ERROR: jbctl not found (command -v, /var/jb/basebin/jbctl, /basebin/jbctl)"
  exit 1
fi
echo "== jbctl: $JBCTL =="

APP=/var/jb/Applications/Runner.app
if [ ! -d "$APP" ]; then
  # roothide 布局兜底
  APP=/Applications/Runner.app
fi
if [ ! -d "$APP" ]; then
  echo "ERROR: app not found (tried /var/jb/Applications/Runner.app 与 /Applications/Runner.app)"
  exit 1
fi
echo "== app: $APP =="

# --- 注册前状态（对照）---
echo "== 注册前 trustcache info =="
"$JBCTL" trustcache info 2>&1 | head -8
echo "== daemon 现状（对照：未注册是否仍存活）=="
ps aux | grep -c "[o]perit_agent_daemon" | xargs echo "  daemon 进程数:"

# --- 逐个注册（只挑可执行 Mach-O：-perm -111；jbctl 会拒绝非 Mach-O）---
reg=0
cand=0
for f in "$APP/Runner" \
    $(find "$APP/Frameworks" -maxdepth 2 -type f -perm -111 2>/dev/null) \
    $(find "$APP/PlugIns" -maxdepth 3 -type f -perm -111 2>/dev/null); do
  [ -f "$f" ] || continue
  cand=$((cand + 1))
  if "$JBCTL" trustcache add "$f" 2>/dev/null; then
    reg=$((reg + 1))
    echo "  + $f"
  else
    echo "  - (rejected/already) $f"
  fi
done
echo "== 注册结果: $reg/$cand =="

echo "== 注册后 trustcache info =="
"$JBCTL" trustcache info 2>&1 | head -8

cat <<'EOF'

== 测速协议 ==
1. 杀 app：killall -9 Runner（或上滑杀掉）
2. 立即重开 Runner，用秒表/日志测到首帧的时间（基线 ~60s）
3. 对比注册前后；若明显下降 → 假设成立，冷启动可绕开减库直接优化
4. 若 trustcache 满了导致注册失败（看 reg/cand），需要评估精简注册范围
EOF

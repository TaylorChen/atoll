#!/bin/zsh
# Atoll 自测：验收前跑一遍，输出 PASS/FAIL 报告。
# 覆盖：进程/网关/hooks 完整性 + 事件闭环 + 审批挂起/决策 + 降级路径。
set -u
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
wait_for_exit() {
  local pid="$1"
  local i
  for i in {1..30}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}
pending_id() {
  curl -s "http://127.0.0.1:${ATOLL_PORT}/sessions" -H "X-Atoll-Token: ${ATOLL_TOKEN}" | python3 -c "
import json,sys
p=[x for x in json.load(sys.stdin)['pending'] if x['sessionKey']=='$SID']
print(p[0]['id'] if p else '')"
}
wait_for_pending() {
  local value=""
  local i
  for i in {1..30}; do
    value=$(pending_id)
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

B="$HOME/.atoll/bin/atoll-bridge"
EP="$HOME/.atoll/run/endpoint"

echo "== 1. 基础健康 =="
APP_COUNT=$(pgrep -f '(/Atoll\.app/Contents/MacOS/Atoll|/\.build/(debug|release)/Atoll)$' | wc -l | tr -d ' ')
[ "$APP_COUNT" = "1" ] && ok "App 单实例运行" || bad "App 进程数异常（应为 1，实际 $APP_COUNT）"
[ -f "$EP" ] && ok "endpoint 文件存在" || bad "endpoint 缺失"
source <(sed 's/^/export /' "$EP")
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ATOLL_PORT}/sessions" -H "X-Atoll-Token: ${ATOLL_TOKEN}")
[ "$CODE" = "200" ] && ok "网关鉴权访问 200" || bad "网关访问失败（$CODE）"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ATOLL_PORT}/sessions")
[ "$CODE" = "401" ] && ok "无 Token 拒绝 401" || bad "无 Token 未被拒绝（$CODE）"
N=$(grep -c '.atoll/' "$HOME/.claude/settings.json")
[ "$N" -ge 13 ] && ok "Claude hooks 完整（$N 条）" || bad "Claude hooks 缺失（$N/13）"
grep -q atoll "$HOME/.codex/hooks.json" && ok "Codex hooks 在位" || bad "Codex hooks 缺失"

echo "== 2. 事件闭环 =="
SID="selftest-$$"
echo "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" | $B --source claude
echo "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\",\"prompt\":\"自测\"}" | $B --source claude
echo "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | $B --source claude
echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"selftest-ok\",\"stderr\":\"\"}}" | $B --source claude
sleep 1
J=$(curl -s "http://127.0.0.1:${ATOLL_PORT}/sessions" -H "X-Atoll-Token: ${ATOLL_TOKEN}")
printf '%s' "$J" | grep -q "\"$SID\"" && ok "会话出现在面板" || bad "会话未出现"
printf '%s' "$J" | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=[x for x in d['sessions'] if x['id']=='$SID']
t=s[0]['toolLog'] if s else []
sys.exit(0 if t and t[0]['result']=='selftest-ok' else 1)" && ok "工具流水与结果摘要正确" || bad "工具流水/结果摘要异常"

echo "== 3. 审批挂起与决策 =="
echo "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"$SID\",\"tool_use_id\":\"codex-call\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch /tmp/x\"}}" | ATOLL_APPROVAL_ROUTE=atoll $B --source codex --hold > /tmp/atoll-selftest-hold.txt &
HPID=$!
PID2=$(wait_for_pending || true)
[ -n "$PID2" ] && ok "审批请求挂起（pending 出现）" || bad "审批未挂起"
kill -0 $HPID 2>/dev/null && ok "bridge 阻塞等待中" || bad "bridge 提前退出"
curl -s -X POST "http://127.0.0.1:${ATOLL_PORT}/decide" -H "X-Atoll-Token: ${ATOLL_TOKEN}" -d "{\"id\":\"$PID2\",\"action\":\"allow\"}" >/dev/null
wait $HPID
python3 -c "
import json,sys
d=json.load(open('/tmp/atoll-selftest-hold.txt'))
h=d.get('hookSpecificOutput', {})
decision=h.get('decision', {})
sys.exit(0 if d.get('continue') is True and h.get('hookEventName') == 'PermissionRequest'
         and decision.get('behavior') == 'allow' and 'updatedPermissions' not in decision else 1)" \
  && ok "Codex allow 使用官方响应协议回传" || bad "Codex 决策协议异常"
rm -f /tmp/atoll-selftest-hold.txt

echo "== 4. Agent 内处理后卡片同步 =="
echo "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"$SID\",\"tool_use_id\":\"external-call\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pwd\"}}" | ATOLL_APPROVAL_ROUTE=atoll $B --source codex --hold > /tmp/atoll-selftest-external.txt &
XPID=$!
PID3=$(wait_for_pending || true)
[ -n "$PID3" ] && ok "外部处理前审批卡已显示" || bad "外部处理测试未产生审批卡"
echo "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$SID\",\"tool_use_id\":\"external-call\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pwd\"}}" | $B --source codex
if wait_for_exit "$XPID"; then
  wait "$XPID"
  ok "Agent 内允许后 held bridge 已释放"
else
  bad "Agent 内允许后 held bridge 仍阻塞"
  kill "$XPID" 2>/dev/null || true
  wait "$XPID" 2>/dev/null || true
fi
J=$(curl -s "http://127.0.0.1:${ATOLL_PORT}/sessions" -H "X-Atoll-Token: ${ATOLL_TOKEN}")
printf '%s' "$J" | python3 -c "
import json,sys
p=[x for x in json.load(sys.stdin)['pending'] if x['sessionKey']=='$SID']
sys.exit(0 if not p else 1)" && ok "Agent 内处理后审批卡已消失" || bad "Agent 内处理后审批卡仍残留"
rm -f /tmp/atoll-selftest-external.txt

echo "== 5. 清理 =="
echo "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" | $B --source claude
ok "自测会话已结束"

echo ""
echo "结果：$PASS 通过 / $FAIL 失败"
[ "$FAIL" = "0" ] && echo "🪸 Atoll 全部自测通过，可以开始人工验收" || echo "⚠ 有失败项，请先排查"
exit $FAIL

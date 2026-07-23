#!/bin/bash
# Atoll statusLine bridge: captures rate_limits from the JSON Claude Code pipes
# in on every message, caches it for the app, then transparently chains to any
# pre-existing statusLine command so the user's visible output is unchanged.
input=$(cat)

# ── Atoll: cache rate_limits + context usage (managed) ──────────
cache="$HOME/.atoll/cache/usage.json"
mkdir -p "$(dirname "$cache")" 2>/dev/null
printf '%s' "$input" | /usr/bin/jq -c '{
  five_hour: .rate_limits.five_hour,
  seven_day: .rate_limits.seven_day,
  context: .context_window.used_percentage,
  session_id: .session_id,
  at: now
}' > "$cache" 2>/dev/null

# Capture Claude Code's own AI-generated session name, keyed by session id,
# so the app can label cards with a real title instead of the raw first prompt.
sid=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // empty' 2>/dev/null)
sname=$(printf '%s' "$input" | /usr/bin/jq -r '.session_name // empty' 2>/dev/null)
if [ -n "$sid" ] && [ -n "$sname" ]; then
  names="$HOME/.atoll/cache/session-names.json"
  existing=$(cat "$names" 2>/dev/null || echo '{}')
  tmp=$(printf '%s' "$existing" | /usr/bin/jq -c --arg id "$sid" --arg n "$sname" '. + {($id): $n}' 2>/dev/null)
  [ -n "$tmp" ] && printf '%s' "$tmp" > "$names"
fi
# ── End Atoll bridge ────────────────────────────────────────────

# Chain to the wrapped upstream statusLine, if one was captured at install.
wrapped="$HOME/.atoll/cache/wrapped-statusline"
if [ -f "$wrapped" ]; then
  cmd=$(cat "$wrapped")
  [ -n "$cmd" ] && printf '%s' "$input" | eval "$cmd"
fi

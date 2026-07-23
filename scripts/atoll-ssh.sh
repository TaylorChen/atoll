#!/bin/bash
# Atoll SSH remote monitoring: run agents on a remote host, watch them locally.
#
#   atoll-ssh.sh deploy  user@host   push bridge + configure remote hooks
#   atoll-ssh.sh connect user@host   open reverse tunnel (remote → local gateway)
#   atoll-ssh.sh remove  user@host   strip remote hooks + files
#
# Events flow: remote CLI hook → remote bridge → 127.0.0.1:TUNNEL_PORT
#   → (ssh -R reverse tunnel) → local gateway 127.0.0.1:ATOLL_PORT.
set -euo pipefail

TUNNEL_PORT=17899   # remote-side port forwarded to the local gateway
ATOLL_DIR="$HOME/.atoll"
BRIDGE_SRC="$HOME/atoll/bridge"

usage() { echo "用法: atoll-ssh.sh {deploy|connect|remove} user@host"; exit 1; }

read_local_endpoint() {
  # shellcheck disable=SC1090
  source <(sed 's/^/export /' "$ATOLL_DIR/run/endpoint")
}

remote_arch() {
  local host="$1"
  local uname_m
  uname_m=$(ssh "$host" 'uname -m' 2>/dev/null)
  case "$uname_m" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) echo "unsupported" ;;
  esac
}

deploy() {
  local host="$1"
  local arch; arch=$(remote_arch "$host")
  [ "$arch" = "unsupported" ] && { echo "❌ 远端架构不支持"; exit 1; }
  read_local_endpoint

  echo "→ 交叉编译 $arch bridge…"
  ( cd "$BRIDGE_SRC" && GOOS=linux GOARCH="${arch#linux-}" \
    go build -ldflags="-s -w" -o "/tmp/atoll-bridge-$arch" . )

  echo "→ 上传 bridge 到远端…"
  ssh "$host" 'mkdir -p ~/.atoll/bin ~/.atoll/run'
  scp -q "/tmp/atoll-bridge-$arch" "$host:~/.atoll/bin/atoll-bridge"
  scp -q "$HOME/atoll/scripts/atoll-launcher" "$host:~/.atoll/bin/atoll-launcher"
  ssh "$host" 'chmod +x ~/.atoll/bin/atoll-bridge ~/.atoll/bin/atoll-launcher'

  echo "→ 写远端 endpoint（指向隧道端口 + 本地 Token）…"
  local remote_host_label; remote_host_label=$(ssh "$host" 'hostname' 2>/dev/null || echo "$host")
  ssh "$host" "cat > ~/.atoll/run/endpoint <<EOF
ATOLL_PORT=$TUNNEL_PORT
ATOLL_TOKEN=$ATOLL_TOKEN
ATOLL_HOST=$remote_host_label
EOF
chmod 600 ~/.atoll/run/endpoint"

  echo "→ 配置远端 Claude Code hooks…"
  scp -q "$HOME/atoll/scripts/install-hooks.py" "$host:~/.atoll/install-hooks.py"
  ssh "$host" 'python3 ~/.atoll/install-hooks.py 2>&1 | head -3'
  echo "✅ 部署完成。运行 'atoll-ssh.sh connect $host' 建立隧道。"
}

connect() {
  local host="$1"
  read_local_endpoint
  echo "→ 建立反向隧道：远端 127.0.0.1:$TUNNEL_PORT → 本地网关 :$ATOLL_PORT"
  echo "  （保持此终端打开；Ctrl-C 断开。自动重连。）"
  while true; do
    ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -R "$TUNNEL_PORT:127.0.0.1:$ATOLL_PORT" "$host" || true
    echo "⚠ 隧道断开，5 秒后重连…"; sleep 5
  done
}

remove() {
  local host="$1"
  echo "→ 移除远端 hooks 与文件…"
  ssh "$host" 'python3 ~/.atoll/install-hooks.py --remove 2>&1 | head -3; rm -rf ~/.atoll'
  echo "✅ 已移除。"
}

[ $# -lt 2 ] && usage
case "$1" in
  deploy) deploy "$2" ;;
  connect) connect "$2" ;;
  remove) remove "$2" ;;
  *) usage ;;
esac

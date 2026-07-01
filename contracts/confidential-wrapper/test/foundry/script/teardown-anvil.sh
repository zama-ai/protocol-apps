#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PID_FILE=".anvil.pid"
PORT=""
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./script/teardown-anvil.sh [--pid-file <path>] [--port <port>] [--force]

Stops Anvil processes started by this package.

Default behavior:
  - If .anvil.pid exists, stop that process and remove the pid file.
  - If no pid file exists, do nothing.

Options:
  --port <port>       Also stop an Anvil listener on this TCP port.
                     Useful after interrupted bake runs on port 8545.
  --force             Allow --port to kill a listener whose command line does
                     not look like Anvil. Use sparingly.
  --pid-file <path>   Override the pid file path. Defaults to .anvil.pid.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid-file)
      [[ $# -ge 2 ]] || { echo "--pid-file requires a path" >&2; exit 2; }
      PID_FILE="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "--port requires a port" >&2; exit 2; }
      PORT="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

is_running() {
  kill -0 "$1" 2>/dev/null
}

cmdline() {
  ps -p "$1" -o command= 2>/dev/null || true
}

looks_like_anvil() {
  cmdline "$1" | grep -Eq '(^|[[:space:]/])anvil([[:space:]]|$)'
}

stop_pid() {
  local pid="$1" label="$2"
  if [[ -z "$pid" ]]; then
    return 0
  fi
  if ! is_running "$pid"; then
    echo "${label}: pid ${pid} is not running"
    return 0
  fi

  echo "${label}: stopping pid ${pid}"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! is_running "$pid"; then
      echo "${label}: stopped pid ${pid}"
      return 0
    fi
    sleep 0.1
  done

  echo "${label}: pid ${pid} did not exit after SIGTERM; sending SIGKILL"
  kill -9 "$pid" 2>/dev/null || true
}

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  stop_pid "$pid" "$PID_FILE"
  rm -f "$PID_FILE"
else
  echo "No pid file at ${PID_FILE}"
fi

if [[ -n "$PORT" ]]; then
  if ! command -v lsof >/dev/null 2>&1; then
    echo "lsof is required for --port cleanup" >&2
    exit 1
  fi

  pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
  if [[ "${#pids[@]}" -eq 0 ]]; then
    echo "No listener on TCP port ${PORT}"
    exit 0
  fi

  for pid in "${pids[@]}"; do
    if looks_like_anvil "$pid"; then
      stop_pid "$pid" "port ${PORT}"
    elif [[ "$FORCE" -eq 1 ]]; then
      echo "port ${PORT}: pid ${pid} does not look like Anvil; --force set"
      stop_pid "$pid" "port ${PORT}"
    else
      echo "port ${PORT}: refusing to stop pid ${pid}; command is:" >&2
      echo "  $(cmdline "$pid")" >&2
      echo "Pass --force only if you are sure this process should be stopped." >&2
      exit 1
    fi
  done
fi

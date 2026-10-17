#!/bin/sh

set -eu

app_dir=/opt/opencode-webui
data_dir=/var/lib/opencode-webui
run_dir=$data_dir/run
log_dir=$data_dir/logs
mkdir -p "$run_dir" "$log_dir"

start_one() {
  name=$1
  shift
  pid_file=$run_dir/$name.pid
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "$name is already running (pid $(cat "$pid_file"))" >&2
    return
  fi
  rm -f "$pid_file"
  runuser -u opencode -- "$@" >> "$log_dir/$name.log" 2>&1 </dev/null &
  echo "$!" > "$pid_file"
  sleep 1
  if ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "$name failed to start; see $log_dir/$name.log" >&2
    rm -f "$pid_file"
    return 1
  fi
  echo "Started $name (pid $(cat "$pid_file"))" >&2
}

stop_one() {
  name=$1
  pid_file=$run_dir/$name.pid
  if [ ! -f "$pid_file" ]; then
    echo "$name is not running" >&2
    return
  fi
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    for _ in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pid_file"
  echo "Stopped $name" >&2
}

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 start|stop|status|logs [api|webui|tunnel]" >&2
  exit 2
fi

case "$1" in
  start)
    if [ "$(id -u)" -ne 0 ]; then
      echo "Run this command as root." >&2
      exit 1
    fi
    start_one api sh -c "cd '$data_dir/workspace' && exec /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 4096 --print-logs"
    start_one webui env PORT=3000 API_URL=http://127.0.0.1:4096 \
      DIST_DIR="$app_dir/app-prefixable/dist" \
      /usr/local/bin/bun run "$app_dir/docker/serve-ui.ts"
    start_one tunnel /usr/local/bin/cloudflared tunnel --no-autoupdate \
      --url http://127.0.0.1:3000
    echo "Logs: $log_dir/*.log" >&2
    ;;
  stop)
    if [ "$(id -u)" -ne 0 ]; then
      echo "Run this command as root." >&2
      exit 1
    fi
    stop_one tunnel
    stop_one webui
    stop_one api
    ;;
  status)
    for name in api webui tunnel; do
      pid_file=$run_dir/$name.pid
      if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo "$name running (pid $(cat "$pid_file"))"
      else
        echo "$name stopped"
      fi
    done
    ;;
  logs)
    if [ "$#" -lt 2 ]; then
      echo "Usage: $0 logs api|webui|tunnel" >&2
      exit 2
    fi
    name=$2
    case "$name" in
      api|webui|tunnel) tail -n 100 -f "$log_dir/$name.log" ;;
      *) echo "Usage: $0 logs api|webui|tunnel" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "Usage: $0 start|stop|status|logs [api|webui|tunnel]" >&2
    exit 2
    ;;
esac

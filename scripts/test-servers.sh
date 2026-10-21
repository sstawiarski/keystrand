#!/usr/bin/env bash
set -euo pipefail

# Description: Starts (or stops) the Redis and Valkey servers the live tests expect.
#   redis    Redis 8 with modules on 127.0.0.1:6390 (every live test target)
#   valkey   Valkey 9 on 127.0.0.1:6392 (Valkey tests)
#   cluster  Valkey 9 cluster on 127.0.0.1:7001-7003 (Valkey cluster tests)
# Usage: scripts/test-servers.sh [native] [start|stop|status] [all|redis|valkey|cluster]
#   Docker mode (default) runs the containers keystrand-test, keystrand-valkey (valkey-bundle with modules),
#   and keystrand-vkc-0..2 (host networking). start creates missing containers and starts stopped ones;
#   stop leaves them in place.
#   Native mode runs Homebrew redis-server and valkey-server processes with their state under
#   .build/test-servers/<name>/ (pid file, log, working dir); stop kills them by pid file.
#   Never touches 127.0.0.1:6379.

readonly REDIS_NAME="keystrand-test"
readonly VALKEY_NAME="keystrand-valkey"
readonly CLUSTER_PORTS=(7001 7002 7003)

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/test-servers.sh [native] [start|stop|status] [all|redis|valkey|cluster]

Starts, stops, or reports the servers the live tests use: Redis 8 on 6390,
Valkey 9 on 6392, and a three-node Valkey 9 cluster on 7001-7003.

  native   run Homebrew redis-server / valkey-server processes instead of Docker
           containers; state, pid files, and logs live in .build/test-servers/
  start    (default) start the servers; already running ones are left alone
  stop     stop the servers (Docker containers are kept for the next start)
  status   report each server

Environment (native mode):
  KEYSTRAND_REDIS_SERVER   redis-server binary; default Homebrew's opt/redis, then PATH
  KEYSTRAND_VALKEY_SERVER  valkey-server binary; default valkey-server on PATH
  KEYSTRAND_REDIS_CLI      redis-cli binary; default Homebrew's opt/redis, then PATH
  KEYSTRAND_VALKEY_CLI     valkey-cli binary; default valkey-cli on PATH
  KEYSTRAND_REDIS_MODULES  space-separated module paths for --loadmodule; default
                           every module in Homebrew's redis modules directory;
                           an empty value loads none
USAGE
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf "Error: '%s' is required but not installed.\n" "$1" >&2
    exit 1
  }
}

# Docker mode

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

ensure_container() {
  local name="$1"
  shift
  if container_running "$name"; then
    printf '%s: already running\n' "$name"
  elif container_exists "$name"; then
    docker start "$name" >/dev/null
    printf '%s: started\n' "$name"
  else
    docker run -d --name "$name" "$@" >/dev/null
    printf '%s: created\n' "$name"
  fi
}

wait_for_ping() {
  local name="$1" cli="$2" port="$3"
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec "$name" "$cli" -p "$port" PING >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  printf 'Error: %s did not answer PING on port %s after %s attempts\n' "$name" "$port" "$attempt" >&2
  return 1
}

start_redis() {
  ensure_container "$REDIS_NAME" -p 6390:6379 redis:8
  wait_for_ping "$REDIS_NAME" redis-cli 6379
}

start_valkey() {
  ensure_container "$VALKEY_NAME" -p 6392:6379 valkey/valkey-bundle:9
  wait_for_ping "$VALKEY_NAME" valkey-cli 6379
}

start_cluster() {
  local index port
  for index in "${!CLUSTER_PORTS[@]}"; do
    port="${CLUSTER_PORTS[$index]}"
    ensure_container "keystrand-vkc-$index" --network host valkey/valkey:9 valkey-server \
      --port "$port" --cluster-enabled yes --cluster-announce-ip 127.0.0.1 \
      --cluster-announce-port "$port" --cluster-announce-bus-port "1$port" \
      --cluster-databases 4 --appendonly no
    wait_for_ping "keystrand-vkc-$index" valkey-cli "$port"
  done
  if [[ "$(cluster_info)" == *"cluster_slots_assigned:0"* ]]; then
    local nodes=()
    for port in "${CLUSTER_PORTS[@]}"; do nodes+=("127.0.0.1:$port"); done
    local output
    if ! output=$(docker exec keystrand-vkc-0 valkey-cli --cluster create "${nodes[@]}" --cluster-yes 2>&1); then
      printf '%s\n' "$output" >&2
      return 1
    fi
    printf 'cluster: slots assigned\n'
  fi
  wait_for_cluster_ok
}

cluster_info() {
  docker exec keystrand-vkc-0 valkey-cli -p "${CLUSTER_PORTS[0]}" CLUSTER INFO 2>/dev/null || true
}

wait_for_cluster_ok() {
  local attempt
  for attempt in $(seq 1 60); do
    if [[ "$(cluster_info)" == *"cluster_state:ok"* ]]; then
      printf 'cluster: state ok\n'
      return 0
    fi
    sleep 0.5
  done
  printf 'Error: cluster did not reach cluster_state:ok after %s attempts\n' "$attempt" >&2
  return 1
}

stop_container() {
  if container_running "$1"; then
    docker stop "$1" >/dev/null
    printf '%s: stopped\n' "$1"
  fi
}

status_container() {
  if container_running "$1"; then
    printf '%s: running\n' "$1"
  elif container_exists "$1"; then
    printf '%s: stopped\n' "$1"
  else
    printf '%s: missing\n' "$1"
  fi
}

cluster_names() {
  local index
  for index in "${!CLUSTER_PORTS[@]}"; do printf 'keystrand-vkc-%s\n' "$index"; done
}

names_for() {
  case "$1" in
    all) printf '%s\n%s\n' "$REDIS_NAME" "$VALKEY_NAME"; cluster_names ;;
    redis) printf '%s\n' "$REDIS_NAME" ;;
    valkey) printf '%s\n' "$VALKEY_NAME" ;;
    cluster) cluster_names ;;
  esac
}

docker_main() {
  local action="$1" target="$2" name
  require_cmd docker
  case "$action" in
    start)
      if [[ "$target" == all || "$target" == redis ]]; then start_redis; fi
      if [[ "$target" == all || "$target" == valkey ]]; then start_valkey; fi
      if [[ "$target" == all || "$target" == cluster ]]; then start_cluster; fi
      ;;
    stop)
      while IFS= read -r name; do stop_container "$name"; done < <(names_for "$target")
      ;;
    status)
      while IFS= read -r name; do status_container "$name"; done < <(names_for "$target")
      ;;
    *) usage ;;
  esac
}

# Native mode

# KEYSTRAND_TEST_PORT_OFFSET shifts every native port, so the script can be checked next to running servers.
readonly PORT_OFFSET="${KEYSTRAND_TEST_PORT_OFFSET:-0}"
STATE_DIR="$(cd "$(dirname "$0")/.." && pwd -P)/.build/test-servers"
if ((PORT_OFFSET != 0)); then STATE_DIR+="-offset-$PORT_OFFSET"; fi
readonly STATE_DIR
readonly NATIVE_REDIS_PORT=$((6390 + PORT_OFFSET))
readonly NATIVE_VALKEY_PORT=$((6392 + PORT_OFFSET))
NATIVE_CLUSTER_PORTS=()
for cluster_port in "${CLUSTER_PORTS[@]}"; do NATIVE_CLUSTER_PORTS+=($((cluster_port + PORT_OFFSET))); done
readonly NATIVE_CLUSTER_PORTS

brew_opt_redis() {
  local prefix="${HOMEBREW_PREFIX:-}"
  if [[ -z "$prefix" ]] && command -v brew >/dev/null 2>&1; then prefix="$(brew --prefix)"; fi
  [[ -n "$prefix" && -d "$prefix/opt/redis" ]] && printf '%s/opt/redis\n' "$prefix"
}

resolve_bin() {
  local override="$1" name="$2" redis_opt="${3:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
  elif [[ -n "$redis_opt" && -x "$redis_opt/bin/$name" ]]; then
    printf '%s\n' "$redis_opt/bin/$name"
  elif command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  else
    printf "Error: '%s' is required but not installed (brew install %s).\n" "$name" "${name%%-*}" >&2
    return 1
  fi
}

redis_modules() {
  local redis_opt="$1" module
  if [[ -n "${KEYSTRAND_REDIS_MODULES+set}" ]]; then
    printf '%s\n' "$KEYSTRAND_REDIS_MODULES"
  elif [[ -n "$redis_opt" && -d "$redis_opt/lib/redis/modules" ]]; then
    for module in "$redis_opt"/lib/redis/modules/*.so; do
      if [[ -e "$module" ]]; then printf '%s ' "$module"; fi
    done
    printf '\n'
  else
    printf '\n'
  fi
}

listening_pids() {
  lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
}

pid_from_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' <"$file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
}

wait_for_native_ping() {
  local name="$1" cli="$2" port="$3" attempt
  for attempt in $(seq 1 40); do
    if "$cli" -h 127.0.0.1 -p "$port" PING >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  printf 'Error: %s did not answer PING on port %s; see %s/server.log\n' "$name" "$port" "$STATE_DIR/$name" >&2
  return 1
}

# Starts one server process unless its port is taken. Extra arguments go to the server.
start_native() {
  local name="$1" port="$2" server="$3" cli="$4"
  shift 4
  local dir="$STATE_DIR/$name"
  local pid holders
  holders="$(listening_pids "$port")"
  if pid="$(pid_from_file "$dir/server.pid")" && grep -qx "$pid" <<<"$holders"; then
    printf '%s: already running (pid %s, port %s)\n' "$name" "$pid" "$port"
    return 0
  fi
  if [[ -n "$holders" ]]; then
    printf 'Error: %s cannot start, port %s is already in use:\n' "$name" "$port" >&2
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
    return 1
  fi
  mkdir -p "$dir"
  "$server" --port "$port" --bind 127.0.0.1 --dir "$dir" --pidfile "$dir/server.pid" \
    --logfile "$dir/server.log" --daemonize yes --save "" --appendonly no "$@"
  wait_for_native_ping "$name" "$cli" "$port"
  printf '%s: started (port %s, log %s/server.log)\n' "$name" "$port" "$dir"
}

start_native_redis() {
  local redis_opt server cli modules module
  redis_opt="$(brew_opt_redis || true)"
  server="$(resolve_bin "${KEYSTRAND_REDIS_SERVER:-}" redis-server "$redis_opt")"
  cli="$(resolve_bin "${KEYSTRAND_REDIS_CLI:-}" redis-cli "$redis_opt")"
  if [[ -z "${KEYSTRAND_REDIS_SERVER:-}" ]] && ! "$server" --version | grep -q '^Redis server'; then
    printf 'Error: %s is not Redis (%s).\n' "$server" "$("$server" --version)" >&2
    printf 'Install it next to Valkey with: brew unlink valkey && brew install redis && brew unlink redis && brew link valkey\n' >&2
    printf 'or set KEYSTRAND_REDIS_SERVER to a redis-server binary.\n' >&2
    return 1
  fi
  local args=()
  read -r -a modules <<<"$(redis_modules "$redis_opt")"
  for module in ${modules[@]+"${modules[@]}"}; do args+=(--loadmodule "$module"); done
  start_native redis "$NATIVE_REDIS_PORT" "$server" "$cli" ${args[@]+"${args[@]}"}
}

valkey_bins() {
  VALKEY_SERVER="$(resolve_bin "${KEYSTRAND_VALKEY_SERVER:-}" valkey-server)"
  VALKEY_CLI="$(resolve_bin "${KEYSTRAND_VALKEY_CLI:-}" valkey-cli)"
}

start_native_valkey() {
  valkey_bins
  start_native valkey "$NATIVE_VALKEY_PORT" "$VALKEY_SERVER" "$VALKEY_CLI"
}

native_cluster_info() {
  "$VALKEY_CLI" -h 127.0.0.1 -p "${NATIVE_CLUSTER_PORTS[0]}" CLUSTER INFO 2>/dev/null || true
}

start_native_cluster() {
  valkey_bins
  local index port
  for index in "${!NATIVE_CLUSTER_PORTS[@]}"; do
    port="${NATIVE_CLUSTER_PORTS[$index]}"
    start_native "vkc-$index" "$port" "$VALKEY_SERVER" "$VALKEY_CLI" \
      --cluster-enabled yes --cluster-config-file nodes.conf --cluster-port $((port + 10000)) \
      --cluster-announce-ip 127.0.0.1 --cluster-databases 4
  done
  if [[ "$(native_cluster_info)" == *"cluster_slots_assigned:0"* ]]; then
    local nodes=() output
    for port in "${NATIVE_CLUSTER_PORTS[@]}"; do nodes+=("127.0.0.1:$port"); done
    if ! output=$("$VALKEY_CLI" --cluster create "${nodes[@]}" --cluster-yes 2>&1); then
      printf '%s\n' "$output" >&2
      return 1
    fi
    printf 'cluster: slots assigned\n'
  fi
  local attempt
  for attempt in $(seq 1 60); do
    if [[ "$(native_cluster_info)" == *"cluster_state:ok"* ]]; then
      printf 'cluster: state ok\n'
      return 0
    fi
    sleep 0.5
  done
  printf 'Error: cluster did not reach cluster_state:ok after %s attempts\n' "$attempt" >&2
  return 1
}

stop_native() {
  local name="$1" dir="$STATE_DIR/$1" pid attempt
  if ! pid="$(pid_from_file "$dir/server.pid")"; then
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for attempt in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s: stopped\n' "$name"
      return 0
    fi
    sleep 0.25
  done
  printf 'Error: %s (pid %s) did not exit after %s checks\n' "$name" "$pid" "$attempt" >&2
  return 1
}

status_native() {
  local name="$1" port="$2" pid holders
  if pid="$(pid_from_file "$STATE_DIR/$name/server.pid")"; then
    printf '%s: running (pid %s, port %s)\n' "$name" "$pid" "$port"
    return 0
  fi
  holders="$(listening_pids "$port")"
  if [[ -n "$holders" ]]; then
    printf '%s: stopped (port %s is held by pid %s)\n' "$name" "$port" "$(tr '\n' ' ' <<<"$holders" | sed 's/ $//')"
  else
    printf '%s: stopped\n' "$name"
  fi
}

native_servers_for() {
  local index
  if [[ "$1" == all || "$1" == redis ]]; then printf 'redis %s\n' "$NATIVE_REDIS_PORT"; fi
  if [[ "$1" == all || "$1" == valkey ]]; then printf 'valkey %s\n' "$NATIVE_VALKEY_PORT"; fi
  if [[ "$1" == all || "$1" == cluster ]]; then
    for index in "${!NATIVE_CLUSTER_PORTS[@]}"; do printf 'vkc-%s %s\n' "$index" "${NATIVE_CLUSTER_PORTS[$index]}"; done
  fi
}

native_main() {
  local action="$1" target="$2" name port
  require_cmd lsof
  case "$action" in
    start)
      if [[ "$target" == all || "$target" == redis ]]; then start_native_redis; fi
      if [[ "$target" == all || "$target" == valkey ]]; then start_native_valkey; fi
      if [[ "$target" == all || "$target" == cluster ]]; then start_native_cluster; fi
      ;;
    stop)
      while read -r name port; do stop_native "$name"; done < <(native_servers_for "$target")
      ;;
    status)
      while read -r name port; do status_native "$name" "$port"; done < <(native_servers_for "$target")
      ;;
    *) usage ;;
  esac
}

main() {
  local mode=docker
  if [[ "${1:-}" == native ]]; then
    mode=native
    shift
  fi
  case "${1:-}" in -h | --help) usage ;; esac
  local action="${1:-start}" target="${2:-all}"
  [[ "$action" =~ ^(start|stop|status)$ ]] || usage
  [[ "$target" =~ ^(all|redis|valkey|cluster)$ ]] || usage
  if [[ "$mode" == native ]]; then
    native_main "$action" "$target"
  else
    docker_main "$action" "$target"
  fi
}

main "$@"

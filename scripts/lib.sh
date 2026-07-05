#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config/cluster.env}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

load_config() {
  local section="" line key value var section_key
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//$'\r'/}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$line" == *"="* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    value="${value%\"}"
    value="${value#\"}"
    section_key="$(config_name "$section" "$key")"
    printf -v "$section_key" '%s' "$value"
    export "$section_key"
  done < "$CONFIG_FILE"

  map_config_aliases
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

config_name() {
  local section="$1" key="$2"
  local name="${section}_${key}"
  name="$(printf '%s' "$name" | tr '[:lower:].-' '[:upper:]__')"
  name="${name//[^A-Z0-9_]/_}"
  printf '%s' "$name"
}

csv_to_array() {
  local var_name="$1" csv="$2" item
  local -a values=()
  IFS=',' read -ra values <<< "$csv"
  for item in "${!values[@]}"; do
    values[$item]="$(trim "${values[$item]}")"
  done
  eval "$var_name=(\"\${values[@]}\")"
}

map_config_aliases() {
  CLUSTER_NAME="${CLUSTER_NAME:-${CLUSTER_NAME_NAME:-pg17-ha}}"
  SCOPE="${CLUSTER_SCOPE:-${CLUSTER_NAME}}"

  INSTALL_ROOT="${DEPLOY_INSTALL_ROOT:-/opt/pg-ha-installer}"
  SSH_USER="${DEPLOY_SSH_USER:-root}"
  SSH_PASSWORD="${DEPLOY_SSH_PASSWORD:-}"
  SSH_KEY="${DEPLOY_SSH_KEY:-}"
  SSH_PORT="${DEPLOY_SSH_PORT:-22}"

  OS_TIMEZONE="${OS_TIMEZONE:-Asia/Shanghai}"
  OS_ENABLE_CHRONY="${OS_ENABLE_CHRONY:-true}"
  OS_DISABLE_TRANSPARENT_HUGEPAGE="${OS_DISABLE_TRANSPARENT_HUGEPAGE:-true}"
  OS_APPLY_SYSCTL="${OS_APPLY_SYSCTL:-true}"
  OS_APPLY_LIMITS="${OS_APPLY_LIMITS:-true}"
  OS_OPEN_FIREWALL_PORTS="${OS_OPEN_FIREWALL_PORTS:-true}"
  OS_MANAGE_SELINUX="${OS_MANAGE_SELINUX:-false}"

  POSTGRES_VERSION="${POSTGRESQL_VERSION:-17.10}"
  POSTGRES_PORT="${POSTGRESQL_PORT:-5432}"
  POSTGRES_OS_USER="${POSTGRESQL_OS_USER:-postgres}"
  PG_PREFIX="${POSTGRESQL_PREFIX:-/pg/pghome}"
  PG_DATA="${POSTGRESQL_DATA_DIR:-/pgdata/pg17}"
  PG_WAL_ARCHIVE="${POSTGRESQL_WAL_ARCHIVE:-/pgwal/archive_wals}"
  PG_BACKUP="${POSTGRESQL_BACKUP_DIR:-/pgbak}"
  PGDATABASE="${POSTGRESQL_DATABASE:-postgres}"
  POSTGRES_SUPERUSER="${POSTGRESQL_SUPERUSER:-postgres}"
  POSTGRES_SUPERPASS="${POSTGRESQL_SUPERPASS:-ChangeMe_pg17_super}"
  REPLICATION_USER="${POSTGRESQL_REPLICATION_USER:-replicator}"
  REPLICATION_PASS="${POSTGRESQL_REPLICATION_PASS:-ChangeMe_pg17_repl}"
  REWIND_USER="${POSTGRESQL_REWIND_USER:-rewind}"
  REWIND_PASS="${POSTGRESQL_REWIND_PASS:-ChangeMe_pg17_rewind}"
  MAX_CONNECTIONS="${POSTGRESQL_MAX_CONNECTIONS:-300}"
  SHARED_BUFFERS="${POSTGRESQL_SHARED_BUFFERS:-4GB}"
  EFFECTIVE_CACHE_SIZE="${POSTGRESQL_EFFECTIVE_CACHE_SIZE:-12GB}"
  MAINTENANCE_WORK_MEM="${POSTGRESQL_MAINTENANCE_WORK_MEM:-512MB}"
  WORK_MEM="${POSTGRESQL_WORK_MEM:-16MB}"
  WAL_KEEP_SIZE="${POSTGRESQL_WAL_KEEP_SIZE:-2GB}"
  MAX_WAL_SIZE="${POSTGRESQL_MAX_WAL_SIZE:-8GB}"
  SYNCHRONOUS_MODE="${POSTGRESQL_SYNCHRONOUS_MODE:-false}"
  SYNCHRONOUS_MODE_STRICT="${POSTGRESQL_SYNCHRONOUS_MODE_STRICT:-false}"

  ETCD_VERSION="${ETCD_VERSION:-v3.6.12}"
  ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-2379}"
  ETCD_PEER_PORT="${ETCD_PEER_PORT:-2380}"
  ETCD_DATA="${ETCD_DATA_DIR:-/pg/etcd}"
  ETCD_CONFIG_FILE="${ETCD_CONFIG_FILE:-/etc/etcd.conf.yml}"
  ETCD_BIN_DIR="${ETCD_BIN_DIR:-/usr/local/bin}"

  PATRONI_VERSION="${PATRONI_VERSION:-3.0.4}"
  PATRONI_PORT="${PATRONI_PORT:-8008}"
  PATRONI_HOME="${PATRONI_HOME:-/etc/patroni}"
  PATRONI_LOG_DIR="${PATRONI_LOG_DIR:-/var/log/patroni}"

  VIP_ADDRESS="${VIP_ADDRESS:-}"
  VIP_CIDR="${VIP_CIDR:-24}"
  VIP_DEVICE="${VIP_DEVICE:-eth0}"
  VIP_LABEL="${VIP_LABEL:-pgvip}"

  csv_to_array PG_NODES "${POSTGRESQL_NODES:-pg01:10.0.0.121,pg02:10.0.0.122,pg03:10.0.0.123}"
  csv_to_array ETCD_NODES "${ETCD_NODES:-${POSTGRESQL_NODES:-pg01:10.0.0.121,pg02:10.0.0.122,pg03:10.0.0.123}}"
  CLUSTER_NODES=("${PG_NODES[@]}")
}

apply_node_overrides() {
  local node_name="$1" prefix var base
  prefix="NODE_$(printf '%s' "$node_name" | tr '[:lower:].-' '[:upper:]__')_"
  for var in $(compgen -v "$prefix"); do
    [[ -n "${!var}" ]] || continue
    base="${var#$prefix}"
    case "$base" in
      PREFIX) PG_PREFIX="${!var}" ;;
      DATA_DIR) PG_DATA="${!var}" ;;
      WAL_ARCHIVE) PG_WAL_ARCHIVE="${!var}" ;;
      BACKUP_DIR) PG_BACKUP="${!var}" ;;
      ETCD_DATA_DIR) ETCD_DATA="${!var}" ;;
      PATRONI_HOME) PATRONI_HOME="${!var}" ;;
      PATRONI_LOG_DIR) PATRONI_LOG_DIR="${!var}" ;;
    esac
  done
}

node_name_by_ip() {
  local ip="$1" item name node_ip
  for item in "${PG_NODES[@]}" "${ETCD_NODES[@]}"; do
    name="${item%%:*}"
    node_ip="${item#*:}"
    if [[ "$node_ip" == "$ip" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

node_ip_by_name() {
  local wanted="$1" item name node_ip
  for item in "${PG_NODES[@]}" "${ETCD_NODES[@]}"; do
    name="${item%%:*}"
    node_ip="${item#*:}"
    if [[ "$name" == "$wanted" ]]; then
      printf '%s\n' "$node_ip"
      return 0
    fi
  done
  return 1
}

all_node_ips() {
  local item seen="" ip
  for item in "${PG_NODES[@]}" "${ETCD_NODES[@]}"; do
    ip="${item#*:}"
    [[ " $seen " == *" $ip "* ]] && continue
    seen="$seen $ip"
    printf '%s\n' "$ip"
  done
}

pg_node_ips() {
  local item
  for item in "${PG_NODES[@]}"; do
    printf '%s\n' "${item#*:}"
  done
}

etcd_initial_cluster() {
  local item name node_ip parts=()
  for item in "${ETCD_NODES[@]}"; do
    name="${item%%:*}"
    node_ip="${item#*:}"
    parts+=("${name}=http://${node_ip}:${ETCD_PEER_PORT}")
  done
  local IFS=,
  printf '%s\n' "${parts[*]}"
}

etcd_hosts_yaml() {
  local item node_ip
  for item in "${ETCD_NODES[@]}"; do
    node_ip="${item#*:}"
    printf '    - %s:%s\n' "$node_ip" "$ETCD_CLIENT_PORT"
  done
}

etcd_client_endpoints() {
  local item node_ip parts=()
  for item in "${ETCD_NODES[@]}"; do
    node_ip="${item#*:}"
    parts+=("http://${node_ip}:${ETCD_CLIENT_PORT}")
  done
  local IFS=,
  printf '%s\n' "${parts[*]}"
}

primary_ip() {
  printf '%s\n' "${CLUSTER_NODES[0]#*:}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

current_ip() {
  local item ip
  for item in "${PG_NODES[@]}" "${ETCD_NODES[@]}"; do
    ip="${item#*:}"
    if ip addr show | grep -qw "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  hostname -I | awk '{print $1}'
}

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    die "no supported package manager found"
  fi
}

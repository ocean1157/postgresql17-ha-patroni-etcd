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
    printf -v "CONFIG_HAS_${section_key}" '%s' true
  done < "$CONFIG_FILE"

  map_config_aliases
}

apply_hardware_parameter_defaults() {
  # deploy.sh calculates these values once on the deployment host and exports
  # PG_HARDWARE_DEFAULTS_RESOLVED=true to every target node. This prevents each
  # target from calculating a different Patroni global configuration.
  [[ "${PG_HARDWARE_DEFAULTS_RESOLVED:-false}" != "true" ]] || return 0

  local cpu mem_mb mem_gb shared_buffers effective_cache maintenance_mem
  local max_connections max_worker_processes max_parallel_workers max_parallel_gather missing=false
  cpu="$(nproc)"
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  mem_gb=$((mem_mb / 1024))

  shared_buffers=$((mem_gb * 25 / 100))
  [[ "$shared_buffers" -ge 1 ]] || shared_buffers=1
  effective_cache=$((mem_gb * 75 / 100))

  max_connections=$((cpu * 3))
  # Patroni 3.x validates max_connections with a minimum of 25. Values below
  # 25 are rejected and Patroni falls back to its default (100).
  [[ "$max_connections" -ge 25 ]] || max_connections=25

  maintenance_mem=$((mem_gb * 2 / 100))
  [[ "$maintenance_mem" -ge 1 ]] || maintenance_mem=1
  [[ "$maintenance_mem" -le 8 ]] || maintenance_mem=8

  max_worker_processes="$cpu"
  # Patroni 3.0.4 validates max_worker_processes with a minimum of 2.
  [[ "$max_worker_processes" -ge 2 ]] || max_worker_processes=2
  max_parallel_workers=$((cpu / 2))
  [[ "$max_parallel_workers" -ge 2 ]] || max_parallel_workers=2
  max_parallel_gather=$((cpu / 8))
  [[ "$max_parallel_gather" -ge 2 ]] || max_parallel_gather=2
  [[ "$max_parallel_gather" -le 8 ]] || max_parallel_gather=8

  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_SHARED_BUFFERS:-false}" != "true" ]]; then
    POSTGRESQL_CONF_SHARED_BUFFERS="${shared_buffers}GB"; missing=true
  fi
  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE:-false}" != "true" ]]; then
    POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE="${effective_cache}GB"; missing=true
  fi
  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_MAX_CONNECTIONS:-false}" != "true" ]]; then
    POSTGRESQL_CONF_MAX_CONNECTIONS="$max_connections"; missing=true
  fi
  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_MAINTENANCE_WORK_MEM:-false}" != "true" ]]; then
    POSTGRESQL_CONF_MAINTENANCE_WORK_MEM="${maintenance_mem}GB"; missing=true
  fi
  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_MAX_WORKER_PROCESSES:-false}" != "true" ]]; then
    POSTGRESQL_CONF_MAX_WORKER_PROCESSES="$max_worker_processes"; missing=true
  fi
  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_MAX_PARALLEL_WORKERS:-false}" != "true" ]]; then
    POSTGRESQL_CONF_MAX_PARALLEL_WORKERS="$max_parallel_workers"; missing=true
  fi
  if [[ "${CONFIG_HAS_POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER:-false}" != "true" ]]; then
    POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER="$max_parallel_gather"; missing=true
  fi

  export POSTGRESQL_CONF_SHARED_BUFFERS POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE
  export POSTGRESQL_CONF_MAX_CONNECTIONS POSTGRESQL_CONF_MAINTENANCE_WORK_MEM
  export POSTGRESQL_CONF_MAX_WORKER_PROCESSES POSTGRESQL_CONF_MAX_PARALLEL_WORKERS
  export POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER
  PGCONF_SHARED_BUFFERS="$POSTGRESQL_CONF_SHARED_BUFFERS"
  PGCONF_EFFECTIVE_CACHE_SIZE="$POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE"
  PGCONF_MAX_CONNECTIONS="$POSTGRESQL_CONF_MAX_CONNECTIONS"
  PGCONF_MAINTENANCE_WORK_MEM="$POSTGRESQL_CONF_MAINTENANCE_WORK_MEM"
  PGCONF_MAX_WORKER_PROCESSES="$POSTGRESQL_CONF_MAX_WORKER_PROCESSES"
  PGCONF_MAX_PARALLEL_WORKERS="$POSTGRESQL_CONF_MAX_PARALLEL_WORKERS"
  PGCONF_MAX_PARALLEL_WORKERS_PER_GATHER="$POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER"
  PG_HARDWARE_DEFAULTS_RESOLVED=true
  export PG_HARDWARE_DEFAULTS_RESOLVED

  if [[ "$missing" == "true" ]]; then
    log "PostgreSQL missing parameters calculated once on deployment host: cpu=${cpu}, memory=${mem_gb}GB"
  fi
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
  DEPLOY_PARALLEL_JOBS="${DEPLOY_PARALLEL_JOBS:-0}"
  YUM_SOURCE="${REPOSITORY_YUM_SOURCE:-}"
  YUM_DISABLE_REPOS="${REPOSITORY_YUM_DISABLE_REPOS:-${RPM_DISABLE_REPOS:-}}"
  PIP_SOURCE="${REPOSITORY_PIP_SOURCE:-}"
  OFFLINE_INSTALL="${REPOSITORY_OFFLINE_INSTALL:-auto}"

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
  PGDATABASE="${POSTGRESQL_DATABASE:-postgres}"
  PG_PREFIX="${POSTGRESQL_INSTALL_PREFIX:-${POSTGRESQL_PREFIX:-/pg/pghome}}"
  PG_DATA="${POSTGRESQL_INSTALL_DATA_DIR:-${POSTGRESQL_DATA_DIR:-/pgdata/pg17}}"
  PG_CONFIGURE_OPTIONS="${POSTGRESQL_INSTALL_CONFIGURE_OPTIONS:---with-openssl --with-zlib --with-uuid=e2fs --with-python}"
  POSTGRES_SUPERUSER="${POSTGRESQL_AUTH_SUPERUSER:-${POSTGRESQL_SUPERUSER:-postgres}}"
  POSTGRES_SUPERPASS="${POSTGRESQL_AUTH_SUPERPASS:-${POSTGRESQL_SUPERPASS:-}}"
  REPLICATION_USER="${POSTGRESQL_AUTH_REPLICATION_USER:-${POSTGRESQL_REPLICATION_USER:-replicator}}"
  REPLICATION_PASS="${POSTGRESQL_AUTH_REPLICATION_PASS:-${POSTGRESQL_REPLICATION_PASS:-}}"
  REWIND_USER="${POSTGRESQL_AUTH_REWIND_USER:-${POSTGRESQL_REWIND_USER:-rewind}}"
  REWIND_PASS="${POSTGRESQL_AUTH_REWIND_PASS:-${POSTGRESQL_REWIND_PASS:-}}"
  PGCONF_LISTEN_ADDRESSES="${POSTGRESQL_CONF_LISTEN_ADDRESSES:-*}"
  PGCONF_MAX_CONNECTIONS="${POSTGRESQL_CONF_MAX_CONNECTIONS:-300}"
  PGCONF_SHARED_BUFFERS="${POSTGRESQL_CONF_SHARED_BUFFERS:-4GB}"
  PGCONF_EFFECTIVE_CACHE_SIZE="${POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE:-12GB}"
  PGCONF_MAINTENANCE_WORK_MEM="${POSTGRESQL_CONF_MAINTENANCE_WORK_MEM:-512MB}"
  PGCONF_MAX_WORKER_PROCESSES="${POSTGRESQL_CONF_MAX_WORKER_PROCESSES:-$(nproc)}"
  PGCONF_MAX_PARALLEL_WORKERS="${POSTGRESQL_CONF_MAX_PARALLEL_WORKERS:-2}"
  PGCONF_MAX_PARALLEL_WORKERS_PER_GATHER="${POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER:-2}"
  PGCONF_WORK_MEM="${POSTGRESQL_CONF_WORK_MEM:-16MB}"
  PGCONF_WAL_LEVEL="${POSTGRESQL_CONF_WAL_LEVEL:-replica}"
  PGCONF_WAL_LOG_HINTS="${POSTGRESQL_CONF_WAL_LOG_HINTS:-on}"
  PGCONF_MAX_WAL_SENDERS="${POSTGRESQL_CONF_MAX_WAL_SENDERS:-10}"
  PGCONF_MAX_REPLICATION_SLOTS="${POSTGRESQL_CONF_MAX_REPLICATION_SLOTS:-10}"
  PGCONF_WAL_KEEP_SIZE="${POSTGRESQL_CONF_WAL_KEEP_SIZE:-2GB}"
  PGCONF_MAX_WAL_SIZE="${POSTGRESQL_CONF_MAX_WAL_SIZE:-8GB}"
  PGCONF_CHECKPOINT_COMPLETION_TARGET="${POSTGRESQL_CONF_CHECKPOINT_COMPLETION_TARGET:-0.9}"
  PGCONF_HOT_STANDBY="${POSTGRESQL_CONF_HOT_STANDBY:-on}"
  PGCONF_HOT_STANDBY_FEEDBACK="${POSTGRESQL_CONF_HOT_STANDBY_FEEDBACK:-on}"
  PGCONF_PASSWORD_ENCRYPTION="${POSTGRESQL_CONF_PASSWORD_ENCRYPTION:-scram-sha-256}"
  PGCONF_SHARED_PRELOAD_LIBRARIES="${POSTGRESQL_CONF_SHARED_PRELOAD_LIBRARIES:-pg_stat_statements}"
  PGCONF_PG_STAT_STATEMENTS_MAX="${POSTGRESQL_CONF_PG_STAT_STATEMENTS_MAX:-10000}"
  PGCONF_PG_STAT_STATEMENTS_TRACK="${POSTGRESQL_CONF_PG_STAT_STATEMENTS_TRACK:-all}"
  PGCONF_CRON_DATABASE_NAME="${POSTGRESQL_CONF_CRON_DATABASE_NAME:-${PGDATABASE}}"
  PGCONF_LOGGING_COLLECTOR="${POSTGRESQL_CONF_LOGGING_COLLECTOR:-on}"
  PGCONF_LOG_DIRECTORY="${POSTGRESQL_CONF_LOG_DIRECTORY:-log}"
  PGCONF_LOG_FILENAME="${POSTGRESQL_CONF_LOG_FILENAME:-postgresql-%Y-%m-%d.log}"
  PGCONF_LOG_LINE_PREFIX="${POSTGRESQL_CONF_LOG_LINE_PREFIX:-%m [%p] %u@%d %r %a }"
  PGCONF_LOG_MIN_DURATION_STATEMENT="${POSTGRESQL_CONF_LOG_MIN_DURATION_STATEMENT:-1000}"
  PGCONF_ARCHIVE_MODE="${POSTGRESQL_CONF_ARCHIVE_MODE:-on}"
  PGCONF_UNIX_SOCKET_DIRECTORIES="${POSTGRESQL_CONF_UNIX_SOCKET_DIRECTORIES:-/var/run/postgresql}"

  PG_PROBACKUP_VERSION="${PG_PROBACKUP_VERSION:-2.5.16}"
  PG_PROBACKUP_BACKUP_HOST="${PG_PROBACKUP_BACKUP_HOST:-full}"
  PG_PROBACKUP_BACKUP_DIR="${PG_PROBACKUP_BACKUP_DIR:-/pgbak/pg_probackup}"
  PG_PROBACKUP_INSTANCE="${PG_PROBACKUP_INSTANCE:-${SCOPE}}"
  PG_PROBACKUP_BINARY="${PG_PROBACKUP_BINARY:-/usr/local/bin/pg_probackup}"
  PG_PROBACKUP_JOB_SCRIPT="${PG_PROBACKUP_JOB_SCRIPT:-/usr/local/bin/pg_ha_probackup.sh}"
  PG_PROBACKUP_RETENTION_REDUNDANCY="${PG_PROBACKUP_RETENTION_REDUNDANCY:-4}"
  PG_PROBACKUP_RETENTION_WINDOW="${PG_PROBACKUP_RETENTION_WINDOW:-30}"
  PG_PROBACKUP_CRON_MINUTE="${PG_PROBACKUP_CRON_MINUTE:-30}"
  PG_PROBACKUP_CRON_HOUR="${PG_PROBACKUP_CRON_HOUR:-1}"
  PG_PROBACKUP_FULL_BACKUP_DAY="${PG_PROBACKUP_FULL_BACKUP_DAY:-0}"
  PG_PROBACKUP_INCREMENTAL_MODE="${PG_PROBACKUP_INCREMENTAL_MODE:-PAGE}"
  PG_PROBACKUP_BACKUP_USER="${PG_PROBACKUP_BACKUP_USER:-${POSTGRES_SUPERUSER}}"
  PGCONF_ARCHIVE_COMMAND="${POSTGRESQL_CONF_ARCHIVE_COMMAND:-${PG_PROBACKUP_BINARY} archive-push -B ${PG_PROBACKUP_BACKUP_DIR} --instance ${PG_PROBACKUP_INSTANCE} --wal-file-path=%p --wal-file-name=%f}"
  PG_CRON_VERSION="${PG_CRON_VERSION:-1.6.7}"

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
  PATRONI_VENV="${PATRONI_VENV:-/opt/patroni-venv}"
  PATRONI_BIN_DIR="${PATRONI_BIN_DIR:-/usr/local/bin}"
  PATRONI_BIN="${PATRONI_BIN_DIR}/patroni"
  PATRONICTL_BIN="${PATRONI_BIN_DIR}/patronictl"
  PATRONI_TTL="${PATRONI_DCS_TTL:-30}"
  PATRONI_LOOP_WAIT="${PATRONI_DCS_LOOP_WAIT:-10}"
  PATRONI_RETRY_TIMEOUT="${PATRONI_DCS_RETRY_TIMEOUT:-10}"
  PATRONI_MAXIMUM_LAG_ON_FAILOVER="${PATRONI_DCS_MAXIMUM_LAG_ON_FAILOVER:-1048576}"
  PATRONI_USE_PG_REWIND="${PATRONI_DCS_USE_PG_REWIND:-true}"
  PATRONI_USE_SLOTS="${PATRONI_DCS_USE_SLOTS:-true}"
  SYNCHRONOUS_MODE="${PATRONI_SYNC_SYNCHRONOUS_MODE:-${POSTGRESQL_SYNCHRONOUS_MODE:-false}}"
  SYNCHRONOUS_MODE_STRICT="${PATRONI_SYNC_SYNCHRONOUS_MODE_STRICT:-${POSTGRESQL_SYNCHRONOUS_MODE_STRICT:-false}}"
  SYNCHRONOUS_NODE_COUNT="${PATRONI_SYNC_SYNCHRONOUS_NODE_COUNT:-1}"

  VIP_ADDRESS="${VIP_ADDRESS:-}"
  VIP_CIDR="${VIP_CIDR:-24}"
  VIP_DEVICE="${VIP_DEVICE:-eth0}"
  VIP_LABEL="${VIP_LABEL:-pgvip}"

  csv_to_array PG_NODES "${POSTGRESQL_NODES:-pg01:10.0.0.121,pg02:10.0.0.122,pg03:10.0.0.123}"
  csv_to_array ETCD_NODES "${ETCD_NODES:-${POSTGRESQL_NODES:-pg01:10.0.0.121,pg02:10.0.0.122,pg03:10.0.0.123}}"
  CLUSTER_NODES=("${PG_NODES[@]}")
  validate_pg_probackup_backup_host
}

validate_pg_probackup_backup_host() {
  local item node_name
  case "$PG_PROBACKUP_BACKUP_HOST" in
    full|leader) return 0 ;;
    standby)
      [[ "${#PG_NODES[@]}" -gt 1 ]] || die "config [pg_probackup] backup_host=standby requires at least two PostgreSQL nodes"
      return 0
      ;;
  esac
  for item in "${PG_NODES[@]}"; do
    node_name="${item%%:*}"
    [[ "$PG_PROBACKUP_BACKUP_HOST" == "$node_name" ]] && return 0
  done
  die "invalid [pg_probackup] backup_host='$PG_PROBACKUP_BACKUP_HOST'; allowed values: full, leader, standby, or a node name from [postgresql].nodes"
}

pg_probackup_cron_enabled_for_node() {
  local node_name="$1"
  case "$PG_PROBACKUP_BACKUP_HOST" in
    full|leader|standby) return 0 ;;
    *) [[ "$PG_PROBACKUP_BACKUP_HOST" == "$node_name" ]] ;;
  esac
}

node_has_role() {
  local wanted_ip="$1" role="$2" item
  case "$role" in
    postgresql) for item in "${PG_NODES[@]}"; do [[ "${item#*:}" == "$wanted_ip" ]] && return 0; done ;;
    etcd) for item in "${ETCD_NODES[@]}"; do [[ "${item#*:}" == "$wanted_ip" ]] && return 0; done ;;
    *) die "unknown node role: $role" ;;
  esac
  return 1
}

is_postgresql_node() { node_has_role "$1" postgresql; }
is_etcd_node() { node_has_role "$1" etcd; }

require_database_passwords() {
  [[ -n "$POSTGRES_SUPERPASS" ]] || die "config [postgresql.auth] superpass cannot be empty"
  [[ -n "$REPLICATION_PASS" ]] || die "config [postgresql.auth] replication_pass cannot be empty"
  [[ -n "$REWIND_PASS" ]] || die "config [postgresql.auth] rewind_pass cannot be empty"
}

node_tag_value() {
  local node_name="$1" tag_name="$2" default_value="$3" var_name
  var_name="NODE_$(printf '%s' "$node_name" | tr '[:lower:].-' '[:upper:]__')_TAGS_$(printf '%s' "$tag_name" | tr '[:lower:].-' '[:upper:]__')"
  if [[ -n "${!var_name:-}" ]]; then
    printf '%s\n' "${!var_name}"
  else
    printf '%s\n' "$default_value"
  fi
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

node_name_by_ip_role() {
  local ip="$1" role="$2" item
  case "$role" in
    postgresql)
      for item in "${PG_NODES[@]}"; do [[ "${item#*:}" == "$ip" ]] && printf '%s\n' "${item%%:*}" && return 0; done
      ;;
    etcd)
      for item in "${ETCD_NODES[@]}"; do [[ "${item#*:}" == "$ip" ]] && printf '%s\n' "${item%%:*}" && return 0; done
      ;;
    *) die "unknown node role: $role" ;;
  esac
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

etcd_node_ips() {
  local item
  for item in "${ETCD_NODES[@]}"; do
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

primary_etcd_ip() {
  printf '%s\n' "${ETCD_NODES[0]#*:}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

rpm_arch() {
  uname -m
}

os_release_value() {
  local key="$1" value
  value="$(awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' /etc/os-release 2>/dev/null || true)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s\n' "$value"
}

current_os_id() {
  local id
  id="$(os_release_value ID)"
  printf '%s\n' "${id:-unknown}"
}

current_os_version() {
  local version
  version="$(os_release_value VERSION_ID)"
  printf '%s\n' "${version:-unknown}"
}

current_os_major() {
  local version major
  version="$(current_os_version)"
  major="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || major="unknown"
  printf '%s\n' "$major"
}

os_compat_from_id_version() {
  local id="$1" version="$2" major
  id="${id,,}"
  major="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1

  case "$id" in
    centos|rhel|redhat|rocky|almalinux|anolis|ol|oracle|oraclelinux)
      printf 'el%s\n' "$major"
      ;;
    *)
      return 1
      ;;
  esac
}

current_os_compat_id() {
  local id version major like compat
  id="$(current_os_id)"
  version="$(current_os_version)"
  if compat="$(os_compat_from_id_version "$id" "$version")"; then
    printf '%s\n' "$compat"
    return 0
  fi

  major="$(current_os_major)"
  like=" $(os_release_value ID_LIKE) "
  if [[ "$major" =~ ^[0-9]+$ && ( "$like" == *" rhel "* || "$like" == *" centos "* || "$like" == *" fedora "* ) ]]; then
    printf 'el%s\n' "$major"
    return 0
  fi

  printf 'unknown\n'
}

current_os_id_version() {
  printf '%s %s\n' "$(current_os_id)" "$(current_os_version)"
}

current_os_pretty() {
  local pretty
  pretty="$(os_release_value PRETTY_NAME)"
  printf '%s\n' "${pretty:-$(current_os_id_version)}"
}

require_supported_rpm_os() {
  local compat
  compat="$(current_os_compat_id)"
  case "$compat" in
    el7|el8) return 0 ;;
    *) die "unsupported RPM OS: $(current_os_pretty). Supported: CentOS 7 compatible OS and Anolis/RHEL/CentOS 8 compatible OS" ;;
  esac
}

rpm_package_manager() {
  local compat
  compat="$(current_os_compat_id)"
  case "$compat" in
    el7)
      if command -v yum >/dev/null 2>&1; then printf 'yum\n'; return 0; fi
      if command -v dnf >/dev/null 2>&1; then printf 'dnf\n'; return 0; fi
      ;;
    el8)
      if command -v dnf >/dev/null 2>&1; then printf 'dnf\n'; return 0; fi
      if command -v yum >/dev/null 2>&1; then printf 'yum\n'; return 0; fi
      ;;
    *)
      if command -v dnf >/dev/null 2>&1; then printf 'dnf\n'; return 0; fi
      if command -v yum >/dev/null 2>&1; then printf 'yum\n'; return 0; fi
      ;;
  esac
  return 1
}

current_python_tag() {
  python3 -c 'import sys; print("cp%d%d" % sys.version_info[:2])' 2>/dev/null || printf 'unknown\n'
}

ensure_python3_command() {
  if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  local py py_path pip_path
  for py in python3.12 python3.11 python3.10 python3.9 python3.8 python3.7 python3.6; do
    if command -v "$py" >/dev/null 2>&1; then
      py_path="$(command -v "$py")"
      mkdir -p /usr/local/bin
      [[ -e /usr/local/bin/python3 ]] || ln -s "$py_path" /usr/local/bin/python3
      break
    fi
  done

  if command -v python3 >/dev/null 2>&1 && ! python3 -m pip --version >/dev/null 2>&1; then
    for py in pip3.12 pip3.11 pip3.10 pip3.9 pip3.8 pip3.7 pip3.6 pip3; do
      if command -v "$py" >/dev/null 2>&1; then
        pip_path="$(command -v "$py")"
        mkdir -p /usr/local/bin
        [[ -e /usr/local/bin/pip3 ]] || ln -s "$pip_path" /usr/local/bin/pip3
        break
      fi
    done
  fi

  command -v python3 >/dev/null 2>&1 || return 1
  python3 -m pip --version >/dev/null 2>&1
}

select_rpm_package_dir() {
  local compat arch candidate
  compat="$(current_os_compat_id)"
  arch="$(rpm_arch)"
  for candidate in \
    "$PROJECT_DIR/packages/rpm/$compat/$arch" \
    "$PROJECT_DIR/packages/rpm/$compat" \
    "$PROJECT_DIR/packages/rpm"; do
    [[ -d "$candidate" ]] || continue
    compgen -G "$candidate/*.rpm" >/dev/null || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

select_python_package_dir() {
  local tag arch compat candidate
  tag="$(current_python_tag)"
  arch="$(rpm_arch)"
  compat="$(current_os_compat_id)"
  for candidate in \
    "$PROJECT_DIR/packages/python/$compat/$tag/$arch" \
    "$PROJECT_DIR/packages/python/$tag/$arch" \
    "$PROJECT_DIR/packages/python/$tag" \
    "$PROJECT_DIR/packages/python"; do
    [[ -d "$candidate" ]] || continue
    compgen -G "$candidate/*" >/dev/null || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
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
  local manager
  if manager="$(rpm_package_manager)"; then
    require_supported_rpm_os
    rpm_repo_install "$manager" "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    die "no supported package manager found"
  fi
}

is_url() { [[ "$1" =~ ^(https?|ftp|file):// ]]; }

normalize_pip_index() {
  local url="${1%/}"
  [[ "$url" == */simple ]] || url="${url}/simple"
  printf '%s\n' "$url"
}

pip_source_args() {
  PIP_SOURCE_ARGS=()
  [[ -n "${PIP_SOURCE:-}" ]] || return 0
  if [[ "$PIP_SOURCE" == *" "* ]]; then
    # shellcheck disable=SC2206
    PIP_SOURCE_ARGS=( $PIP_SOURCE )
  else
    PIP_SOURCE_ARGS=(--index-url "$(normalize_pip_index "$PIP_SOURCE")")
  fi
}

yum_source_args() {
  YUM_SOURCE_ARGS=()
  [[ -n "${YUM_SOURCE:-}" ]] || return 0
  if [[ "$YUM_SOURCE" == *.repo || "$YUM_SOURCE" == *.repo\?* ]]; then
    local repo_dir="/tmp/pg-ha-yum-repos"
    mkdir -p "$repo_dir"
    if is_url "$YUM_SOURCE"; then
      if command -v curl >/dev/null 2>&1; then curl -fsSL "$YUM_SOURCE" -o "$repo_dir/cluster.repo"
      elif command -v wget >/dev/null 2>&1; then wget -qO "$repo_dir/cluster.repo" "$YUM_SOURCE"
      else die "curl or wget is required"; fi
    else
      cp -f "$YUM_SOURCE" "$repo_dir/cluster.repo"
    fi
    YUM_SOURCE_ARGS=(--setopt="reposdir=$repo_dir")
  elif is_url "$YUM_SOURCE" || [[ "$YUM_SOURCE" == /* ]]; then
    local repo_dir="/tmp/pg-ha-yum-repos" baseurl
    mkdir -p "$repo_dir"
    if is_url "$YUM_SOURCE"; then
      baseurl="$YUM_SOURCE"
    else
      baseurl="file://$YUM_SOURCE"
    fi
    cat > "$repo_dir/cluster-source.repo" <<EOF
[cluster-source]
name=cluster-source
baseurl=$baseurl
enabled=1
gpgcheck=0
EOF
    YUM_SOURCE_ARGS=(--setopt="reposdir=$repo_dir" --enablerepo=cluster-source)
  else
    local i
    IFS=',' read -ra YUM_SOURCE_ARGS <<< "$YUM_SOURCE"
    for i in "${!YUM_SOURCE_ARGS[@]}"; do YUM_SOURCE_ARGS[$i]="--enablerepo=$(trim "${YUM_SOURCE_ARGS[$i]}")"; done
  fi
}

manifest_value() {
  local manifest="$1" key="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$manifest" 2>/dev/null || true
}

assert_offline_environment_matches() {
  local rpm_dir="${1:-}" manifest
  manifest="$PROJECT_DIR/packages/OFFLINE-ENVIRONMENT.txt"
  [[ -n "$rpm_dir" && -f "$rpm_dir/OFFLINE-ENVIRONMENT.txt" ]] && manifest="$rpm_dir/OFFLINE-ENVIRONMENT.txt"
  [[ -f "$manifest" ]] || return 0

  local built_os built_id built_version built_compat current_compat built_arch current_arch
  built_os="$(manifest_value "$manifest" os)"
  built_compat="$(manifest_value "$manifest" os_compat)"
  if [[ -z "$built_compat" && -n "$built_os" ]]; then
    built_id="${built_os%% *}"
    built_version="${built_os#* }"
    built_compat="$(os_compat_from_id_version "$built_id" "$built_version" || true)"
  fi

  current_compat="$(current_os_compat_id)"
  if [[ -n "$built_compat" && "$built_compat" != "$current_compat" ]]; then
    die "offline RPM packages were built for '$built_compat', but current OS is '$current_compat' ($(current_os_pretty)). Re-run scripts/download-package.sh on a matching OS family: CentOS 7 => el7, Anolis 8.10 => el8"
  fi

  built_arch="$(manifest_value "$manifest" arch)"
  current_arch="$(rpm_arch)"
  if [[ -n "$built_arch" && "$built_arch" != "$current_arch" ]]; then
    die "offline RPM packages were built for architecture '$built_arch', but current architecture is '$current_arch'"
  fi
}

rpm_repo_install() {
  local manager="$1"
  shift
  [[ "$#" -gt 0 ]] || die "${manager} install requested with no packages"
  local -a install_cmd=("$manager")
  local -a disabled_repos=()
  local disabled_repo
  if [[ -n "${YUM_DISABLE_REPOS:-}" ]]; then
    IFS=',' read -ra disabled_repos <<< "$YUM_DISABLE_REPOS"
    for disabled_repo in "${!disabled_repos[@]}"; do
      install_cmd+=("--disablerepo=$(trim "${disabled_repos[$disabled_repo]}")")
    done
  fi
  yum_source_args
  if [[ -n "${YUM_SOURCE:-}" ]]; then
    install_cmd+=("${YUM_SOURCE_ARGS[@]}")
  fi
  local rpm_dir=""

  rpm_install_local() {
    rpm_dir="$(select_rpm_package_dir || true)"
    [[ -n "$rpm_dir" ]] || return 1
    [[ -f "$rpm_dir/repodata/repomd.xml" ]] || die "packages/rpm exists but has no repodata. Re-run scripts/download-package.sh on an online host that matches the target OS major version and architecture"
    assert_offline_environment_matches "$rpm_dir"
    log "using packages/rpm local repository with online repositories disabled: $*"
    local local_repo_dir="/tmp/pg-ha-local-rpm-repo"
    rm -rf "$local_repo_dir"
    mkdir -p "$local_repo_dir"
    cat > "$local_repo_dir/pg-ha-local.repo" <<EOF
[pg-ha-local]
name=pg-ha-local
baseurl=file://$rpm_dir
enabled=1
gpgcheck=0
EOF
    "$manager" \
      --disablerepo='*' \
      --setopt="reposdir=$local_repo_dir" \
      --enablerepo=pg-ha-local \
      --setopt=multilib_policy=best \
      --nogpgcheck \
      install -y "$@"
  }

  local offline_mode="${OFFLINE_INSTALL,,}"
  if [[ "$offline_mode" == "true" ]]; then
    rpm_install_local "$@" || die "offline_install=true but local RPM repository install failed. Check packages/rpm, OS major version, CPU architecture, and dnf/yum conflict messages above"
    return 0
  fi

  log "using ${manager} online repositories to install packages: $*"
  if "${install_cmd[@]}" install -y --setopt=timeout=60 --setopt=retries=5 "$@"; then
    return 0
  fi

  log "${manager} online install failed; cleaning metadata and retrying once"
  "$manager" clean all || true
  "${install_cmd[@]}" makecache -y || true
  if "${install_cmd[@]}" install -y --setopt=timeout=60 --setopt=retries=5 "$@"; then
    return 0
  fi

  if [[ "$offline_mode" != "false" ]]; then
    log "${manager} online repositories unavailable; falling back to packages/rpm"
    rpm_install_local "$@" && return 0
  fi

  die "${manager} install failed. Check DNS, repository configuration, mirror availability, or prepare packages/rpm with scripts/download-package.sh"
}
rpm_prereq_packages() {
  local compat
  compat="$(current_os_compat_id)"
  cat <<'EOF'
gcc
make
bison
flex
readline-devel
zlib-devel
openssl-devel
libuuid-devel
libicu-devel
perl
tar
gzip
sudo
chrony
iproute
iputils
cronie
openssh-clients
EOF
  case "$compat" in
    el7)
      printf '%s\n' python3 python3-devel python3-pip yum-utils
      ;;
    el8)
      printf '%s\n' python3 python3-devel python3-pip
      ;;
    *)
      printf '%s\n' python3 python3-devel python3-pip
      ;;
  esac
}

rpm_etcd_prereq_packages() {
  cat <<'EOF'
tar
gzip
sudo
chrony
iproute
iputils
openssh-clients
EOF
}

rpm_python_packages() {
  case "$(current_os_compat_id)" in
    el7)
      printf '%s\n' python3 python3-pip
      ;;
    *)
      printf '%s\n' python3 python3-pip
      ;;
  esac
}

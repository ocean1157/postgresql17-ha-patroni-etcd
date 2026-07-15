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
  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"

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

  validate_required_config
  map_config_aliases
}

require_config_key() {
  local var_name="$1" config_key="${2:-$1}"
  local marker="CONFIG_HAS_${var_name}"

  [[ "${!marker:-false}" == "true" ]] || die "required config $config_key is missing in $CONFIG_FILE"
}

require_config_value() {
  local var_name="$1" config_key="$2"

  require_config_key "$var_name" "$config_key"
  [[ -n "$(trim "${!var_name:-}")" ]] || die "required config $config_key must not be empty in $CONFIG_FILE"
}

validate_required_config() {
  local var marker
  require_config_value ETCD_NODES "[etcd].nodes"
  require_config_value POSTGRESQL_NODES "[postgresql].nodes"

  local -a required_values=(
    CLUSTER_NAME CLUSTER_SCOPE
    DEPLOY_INSTALL_ROOT DEPLOY_SSH_USER DEPLOY_SSH_PORT DEPLOY_PARALLEL_JOBS
    OS_TIMEZONE OS_ENABLE_CHRONY OS_DISABLE_TRANSPARENT_HUGEPAGE OS_APPLY_SYSCTL
    OS_APPLY_LIMITS OS_OPEN_FIREWALL_PORTS OS_MANAGE_SELINUX
    REPOSITORY_OFFLINE_INSTALL
    ETCD_VERSION ETCD_CLIENT_PORT ETCD_PEER_PORT ETCD_DATA_DIR ETCD_LOG_DIR
    ETCD_CONFIG_FILE ETCD_BIN_DIR
    POSTGRESQL_VERSION POSTGRESQL_PORT POSTGRESQL_OS_USER POSTGRESQL_DATABASE
    POSTGRESQL_INSTALL_PREFIX POSTGRESQL_INSTALL_DATA_DIR POSTGRESQL_INSTALL_CONFIGURE_OPTIONS
    POSTGRESQL_AUTH_SUPERUSER POSTGRESQL_AUTH_SUPERPASS
    POSTGRESQL_AUTH_REPLICATION_USER POSTGRESQL_AUTH_REPLICATION_PASS
    POSTGRESQL_AUTH_REWIND_USER POSTGRESQL_AUTH_REWIND_PASS POSTGRESQL_AUTH_PGPASS_FILE
    POSTGRESQL_CONF_LISTEN_ADDRESSES POSTGRESQL_CONF_WORK_MEM POSTGRESQL_CONF_WAL_LEVEL
    POSTGRESQL_CONF_WAL_LOG_HINTS POSTGRESQL_CONF_MAX_WAL_SENDERS
    POSTGRESQL_CONF_MAX_REPLICATION_SLOTS POSTGRESQL_CONF_WAL_KEEP_SIZE
    POSTGRESQL_CONF_MAX_WAL_SIZE POSTGRESQL_CONF_CHECKPOINT_COMPLETION_TARGET
    POSTGRESQL_CONF_HOT_STANDBY POSTGRESQL_CONF_HOT_STANDBY_FEEDBACK
    POSTGRESQL_CONF_PASSWORD_ENCRYPTION POSTGRESQL_CONF_SHARED_PRELOAD_LIBRARIES
    POSTGRESQL_CONF_PG_STAT_STATEMENTS_MAX POSTGRESQL_CONF_PG_STAT_STATEMENTS_TRACK
    POSTGRESQL_CONF_CRON_DATABASE_NAME POSTGRESQL_CONF_LOGGING_COLLECTOR
    POSTGRESQL_CONF_LOG_DIRECTORY POSTGRESQL_CONF_LOG_FILENAME
    POSTGRESQL_CONF_LOG_LINE_PREFIX POSTGRESQL_CONF_LOG_MIN_DURATION_STATEMENT
    POSTGRESQL_CONF_ARCHIVE_MODE
    PG_PROBACKUP_VERSION PG_PROBACKUP_BACKUP_HOST PG_PROBACKUP_BACKUP_DIR PG_PROBACKUP_LOG_DIR
    PG_PROBACKUP_INSTANCE PG_PROBACKUP_BINARY PG_PROBACKUP_JOB_SCRIPT
    PG_PROBACKUP_RETENTION_REDUNDANCY PG_PROBACKUP_RETENTION_WINDOW
    PG_PROBACKUP_CRON_MINUTE PG_PROBACKUP_CRON_HOUR PG_PROBACKUP_FULL_BACKUP_DAY
    PG_PROBACKUP_INCREMENTAL_MODE PG_PROBACKUP_BACKUP_USER
    PG_CRON_VERSION PG_REPACK_VERSION
    PATRONI_VERSION PATRONI_PORT PATRONI_HOME PATRONI_LOG_DIR PATRONI_VENV PATRONI_BIN_DIR
    PATRONI_DCS_TTL PATRONI_DCS_LOOP_WAIT PATRONI_DCS_RETRY_TIMEOUT
    PATRONI_DCS_MAXIMUM_LAG_ON_FAILOVER PATRONI_DCS_USE_PG_REWIND PATRONI_DCS_USE_SLOTS
    PATRONI_SYNC_SYNCHRONOUS_MODE PATRONI_SYNC_SYNCHRONOUS_MODE_STRICT
    PATRONI_SYNC_SYNCHRONOUS_NODE_COUNT VIP_LABEL
  )
  local -a required_keys=(
    DEPLOY_SSH_PASSWORD DEPLOY_SSH_KEY REPOSITORY_YUM_SOURCE
    REPOSITORY_YUM_DISABLE_REPOS REPOSITORY_PIP_SOURCE
    VIP_ADDRESS VIP_CIDR VIP_DEVICE
  )

  for var in "${required_values[@]}"; do
    require_config_value "$var" "$var"
  done
  for var in "${required_keys[@]}"; do
    require_config_key "$var" "$var"
  done
  for var in POSTGRESQL_CONF_SHARED_BUFFERS POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE POSTGRESQL_CONF_MAX_CONNECTIONS POSTGRESQL_CONF_MAINTENANCE_WORK_MEM POSTGRESQL_CONF_MAX_WORKER_PROCESSES POSTGRESQL_CONF_MAX_PARALLEL_WORKERS POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER; do
    marker="CONFIG_HAS_${var}"
    if [[ "${!marker:-false}" == "true" ]]; then
      require_config_value "$var" "$var"
    fi
  done

  validate_config_values
}

validate_config_values() {
  local value path

  case "${REPOSITORY_OFFLINE_INSTALL,,}" in auto|true|false) ;; *) die "config [repository].offline_install must be auto, true, or false" ;; esac
  case "${OS_MANAGE_SELINUX,,}" in false|permissive) ;; *) die "config [os].manage_selinux must be false or permissive" ;; esac
  [[ "$POSTGRESQL_AUTH_SUPERUSER" != "$POSTGRESQL_AUTH_REPLICATION_USER" && "$POSTGRESQL_AUTH_SUPERUSER" != "$POSTGRESQL_AUTH_REWIND_USER" && "$POSTGRESQL_AUTH_REPLICATION_USER" != "$POSTGRESQL_AUTH_REWIND_USER" ]] || die "config [postgresql.auth] superuser, replication_user, and rewind_user must be different users"
  validate_port "$DEPLOY_SSH_PORT" "[deploy].ssh_port"
  validate_port "$ETCD_CLIENT_PORT" "[etcd].client_port"
  validate_port "$ETCD_PEER_PORT" "[etcd].peer_port"
  validate_port "$POSTGRESQL_PORT" "[postgresql].port"
  validate_port "$PATRONI_PORT" "[patroni].port"
  [[ "$DEPLOY_PARALLEL_JOBS" =~ ^[0-9]+$ ]] || die "config [deploy].parallel_jobs must be a non-negative integer"
  for value in "$OS_ENABLE_CHRONY" "$OS_DISABLE_TRANSPARENT_HUGEPAGE" "$OS_APPLY_SYSCTL" "$OS_APPLY_LIMITS" "$OS_OPEN_FIREWALL_PORTS" "$PATRONI_DCS_USE_PG_REWIND" "$PATRONI_DCS_USE_SLOTS" "$PATRONI_SYNC_SYNCHRONOUS_MODE" "$PATRONI_SYNC_SYNCHRONOUS_MODE_STRICT"; do
    case "${value,,}" in true|false) ;; *) die "boolean config values must be true or false; got '$value'" ;; esac
  done
  if [[ -n "$VIP_ADDRESS" ]]; then
    validate_ipv4 "$VIP_ADDRESS" "[vip].address"
    [[ -n "$(trim "$VIP_CIDR")" ]] || die "config [vip].cidr is required when [vip].address is set"
    [[ "$VIP_CIDR" =~ ^[0-9]+$ ]] && (( VIP_CIDR >= 0 && VIP_CIDR <= 32 )) || die "config [vip].cidr must be an integer from 0 to 32"
    [[ -n "$(trim "$VIP_DEVICE")" ]] || die "config [vip].device is required when [vip].address is set"
  fi
  for path in "$DEPLOY_INSTALL_ROOT" "$ETCD_DATA_DIR" "$ETCD_LOG_DIR" "$ETCD_CONFIG_FILE" "$ETCD_BIN_DIR" "$POSTGRESQL_INSTALL_PREFIX" "$POSTGRESQL_INSTALL_DATA_DIR" "$POSTGRESQL_AUTH_PGPASS_FILE" "$PG_PROBACKUP_BACKUP_DIR" "$PG_PROBACKUP_LOG_DIR" "$PG_PROBACKUP_BINARY" "$PG_PROBACKUP_JOB_SCRIPT" "$PATRONI_HOME" "$PATRONI_LOG_DIR" "$PATRONI_VENV" "$PATRONI_BIN_DIR"; do
    [[ "$path" == /* ]] || die "filesystem config paths must be absolute; got '$path'"
  done
  [[ "$PG_PROBACKUP_CRON_MINUTE" =~ ^[0-9]+$ ]] && (( 10#$PG_PROBACKUP_CRON_MINUTE <= 59 )) || die "config [pg_probackup].cron_minute must be an integer from 0 to 59"
  [[ "$PG_PROBACKUP_CRON_HOUR" =~ ^[0-9]+$ ]] && (( 10#$PG_PROBACKUP_CRON_HOUR <= 23 )) || die "config [pg_probackup].cron_hour must be an integer from 0 to 23"
  [[ "$PG_PROBACKUP_FULL_BACKUP_DAY" =~ ^[0-9]+$ ]] && (( 10#$PG_PROBACKUP_FULL_BACKUP_DAY <= 6 )) || die "config [pg_probackup].full_backup_day must be an integer from 0 to 6"
  for value in "$PATRONI_DCS_TTL" "$PATRONI_DCS_LOOP_WAIT" "$PATRONI_DCS_RETRY_TIMEOUT" "$PATRONI_DCS_MAXIMUM_LAG_ON_FAILOVER" "$PATRONI_SYNC_SYNCHRONOUS_NODE_COUNT"; do
    [[ "$value" =~ ^[0-9]+$ ]] || die "Patroni numeric config values must be non-negative integers; got '$value'"
  done
}

validate_port() {
  local port="$1" config_key="$2"
  [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || die "config $config_key must be an integer from 1 to 65535"
}

validate_ipv4() {
  local address="$1" config_key="$2" octet
  local -a octets
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "config $config_key must be a valid IPv4 address; got '$address'"
  IFS='.' read -ra octets <<< "$address"
  for octet in "${octets[@]}"; do
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || die "config $config_key must be a valid IPv4 address; got '$address'"
  done
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
  SCOPE="$CLUSTER_SCOPE"

  INSTALL_ROOT="$DEPLOY_INSTALL_ROOT"
  SSH_USER="$DEPLOY_SSH_USER"
  SSH_PASSWORD="$DEPLOY_SSH_PASSWORD"
  SSH_KEY="$DEPLOY_SSH_KEY"
  SSH_PORT="$DEPLOY_SSH_PORT"
  YUM_SOURCE="$REPOSITORY_YUM_SOURCE"
  YUM_DISABLE_REPOS="$REPOSITORY_YUM_DISABLE_REPOS"
  PIP_SOURCE="$REPOSITORY_PIP_SOURCE"
  OFFLINE_INSTALL="$REPOSITORY_OFFLINE_INSTALL"

  POSTGRES_VERSION="$POSTGRESQL_VERSION"
  POSTGRES_PORT="$POSTGRESQL_PORT"
  POSTGRES_OS_USER="$POSTGRESQL_OS_USER"
  PGDATABASE="$POSTGRESQL_DATABASE"
  PG_PREFIX="$POSTGRESQL_INSTALL_PREFIX"
  PG_DATA="$POSTGRESQL_INSTALL_DATA_DIR"
  PG_CONFIGURE_OPTIONS="$POSTGRESQL_INSTALL_CONFIGURE_OPTIONS"
  POSTGRES_SUPERUSER="$POSTGRESQL_AUTH_SUPERUSER"
  POSTGRES_SUPERPASS="$POSTGRESQL_AUTH_SUPERPASS"
  REPLICATION_USER="$POSTGRESQL_AUTH_REPLICATION_USER"
  REPLICATION_PASS="$POSTGRESQL_AUTH_REPLICATION_PASS"
  REWIND_USER="$POSTGRESQL_AUTH_REWIND_USER"
  REWIND_PASS="$POSTGRESQL_AUTH_REWIND_PASS"
  PGPASS_FILE="$POSTGRESQL_AUTH_PGPASS_FILE"
  PGCONF_LISTEN_ADDRESSES="$POSTGRESQL_CONF_LISTEN_ADDRESSES"
  PGCONF_MAX_CONNECTIONS="${POSTGRESQL_CONF_MAX_CONNECTIONS:-300}"
  PGCONF_SHARED_BUFFERS="${POSTGRESQL_CONF_SHARED_BUFFERS:-4GB}"
  PGCONF_EFFECTIVE_CACHE_SIZE="${POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE:-12GB}"
  PGCONF_MAINTENANCE_WORK_MEM="${POSTGRESQL_CONF_MAINTENANCE_WORK_MEM:-512MB}"
  PGCONF_MAX_WORKER_PROCESSES="${POSTGRESQL_CONF_MAX_WORKER_PROCESSES:-$(nproc)}"
  PGCONF_MAX_PARALLEL_WORKERS="${POSTGRESQL_CONF_MAX_PARALLEL_WORKERS:-2}"
  PGCONF_MAX_PARALLEL_WORKERS_PER_GATHER="${POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER:-2}"
  PGCONF_WORK_MEM="$POSTGRESQL_CONF_WORK_MEM"
  PGCONF_WAL_LEVEL="$POSTGRESQL_CONF_WAL_LEVEL"
  PGCONF_WAL_LOG_HINTS="$POSTGRESQL_CONF_WAL_LOG_HINTS"
  PGCONF_MAX_WAL_SENDERS="$POSTGRESQL_CONF_MAX_WAL_SENDERS"
  PGCONF_MAX_REPLICATION_SLOTS="$POSTGRESQL_CONF_MAX_REPLICATION_SLOTS"
  PGCONF_WAL_KEEP_SIZE="$POSTGRESQL_CONF_WAL_KEEP_SIZE"
  PGCONF_MAX_WAL_SIZE="$POSTGRESQL_CONF_MAX_WAL_SIZE"
  PGCONF_CHECKPOINT_COMPLETION_TARGET="$POSTGRESQL_CONF_CHECKPOINT_COMPLETION_TARGET"
  PGCONF_HOT_STANDBY="$POSTGRESQL_CONF_HOT_STANDBY"
  PGCONF_HOT_STANDBY_FEEDBACK="$POSTGRESQL_CONF_HOT_STANDBY_FEEDBACK"
  PGCONF_PASSWORD_ENCRYPTION="$POSTGRESQL_CONF_PASSWORD_ENCRYPTION"
  PGCONF_SHARED_PRELOAD_LIBRARIES="$POSTGRESQL_CONF_SHARED_PRELOAD_LIBRARIES"
  PGCONF_PG_STAT_STATEMENTS_MAX="$POSTGRESQL_CONF_PG_STAT_STATEMENTS_MAX"
  PGCONF_PG_STAT_STATEMENTS_TRACK="$POSTGRESQL_CONF_PG_STAT_STATEMENTS_TRACK"
  PGCONF_CRON_DATABASE_NAME="$POSTGRESQL_CONF_CRON_DATABASE_NAME"
  PGCONF_LOGGING_COLLECTOR="$POSTGRESQL_CONF_LOGGING_COLLECTOR"
  PGCONF_LOG_DIRECTORY="$POSTGRESQL_CONF_LOG_DIRECTORY"
  PGCONF_LOG_FILENAME="$POSTGRESQL_CONF_LOG_FILENAME"
  PGCONF_LOG_LINE_PREFIX="$POSTGRESQL_CONF_LOG_LINE_PREFIX"
  PGCONF_LOG_MIN_DURATION_STATEMENT="$POSTGRESQL_CONF_LOG_MIN_DURATION_STATEMENT"
  PGCONF_ARCHIVE_MODE="$POSTGRESQL_CONF_ARCHIVE_MODE"
  PGCONF_UNIX_SOCKET_DIRECTORIES="${POSTGRESQL_CONF_UNIX_SOCKET_DIRECTORIES:-/var/run/postgresql}"

  PGCONF_ARCHIVE_COMMAND="$PG_PROBACKUP_BINARY archive-push -B $PG_PROBACKUP_BACKUP_DIR --instance $PG_PROBACKUP_INSTANCE --wal-file-path=%p --wal-file-name=%f"

  ETCD_DATA="$ETCD_DATA_DIR"

  PATRONI_BIN="${PATRONI_BIN_DIR}/patroni"
  PATRONICTL_BIN="${PATRONI_BIN_DIR}/patronictl"
  PATRONI_TTL="$PATRONI_DCS_TTL"
  PATRONI_LOOP_WAIT="$PATRONI_DCS_LOOP_WAIT"
  PATRONI_RETRY_TIMEOUT="$PATRONI_DCS_RETRY_TIMEOUT"
  PATRONI_MAXIMUM_LAG_ON_FAILOVER="$PATRONI_DCS_MAXIMUM_LAG_ON_FAILOVER"
  PATRONI_USE_PG_REWIND="$PATRONI_DCS_USE_PG_REWIND"
  PATRONI_USE_SLOTS="$PATRONI_DCS_USE_SLOTS"
  SYNCHRONOUS_MODE="$PATRONI_SYNC_SYNCHRONOUS_MODE"
  SYNCHRONOUS_MODE_STRICT="$PATRONI_SYNC_SYNCHRONOUS_MODE_STRICT"
  SYNCHRONOUS_NODE_COUNT="$PATRONI_SYNC_SYNCHRONOUS_NODE_COUNT"

  csv_to_array PG_NODES "$POSTGRESQL_NODES"
  csv_to_array ETCD_NODES "$ETCD_NODES"
  validate_node_list PG_NODES "[postgresql].nodes"
  validate_node_list ETCD_NODES "[etcd].nodes"
  validate_node_tags
  if [[ -n "$VIP_ADDRESS" ]]; then
    local item
    for item in "${PG_NODES[@]}" "${ETCD_NODES[@]}"; do
      [[ "${item#*:}" != "$VIP_ADDRESS" ]] || die "config [vip].address must not duplicate a PostgreSQL or etcd node IP: $VIP_ADDRESS"
    done
  fi
  if [[ "${SYNCHRONOUS_MODE,,}" == "true" ]]; then
    (( 10#$SYNCHRONOUS_NODE_COUNT < ${#PG_NODES[@]} )) || die "config [patroni.sync].synchronous_node_count must be less than the PostgreSQL node count when synchronous_mode=true"
  fi
  CLUSTER_NODES=("${PG_NODES[@]}")
  validate_pg_probackup_backup_host
}

validate_node_list() {
  local array_name="$1" config_key="$2" item name address seen_names="" seen_addresses=""
  local -a nodes
  eval "nodes=(\"\${${array_name}[@]}\")"
  ((${#nodes[@]} > 0)) || die "config $config_key must contain at least one node"
  for item in "${nodes[@]}"; do
    [[ "$item" == *:* && "${item#*:}" != *:* ]] || die "config $config_key entry '$item' must use node_name:IPv4 format"
    name="${item%%:*}"
    address="${item#*:}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "config $config_key contains invalid node name '$name'"
    validate_ipv4 "$address" "$config_key node '$name'"
    [[ " $seen_names " != *" $name "* ]] || die "config $config_key contains duplicate node name '$name'"
    [[ " $seen_addresses " != *" $address "* ]] || die "config $config_key contains duplicate IP '$address'"
    seen_names+=" $name"
    seen_addresses+=" $address"
  done
}

validate_node_tags() {
  local item node_name tag
  for item in "${PG_NODES[@]}"; do
    node_name="${item%%:*}"
    for tag in nofailover noloadbalance clonefrom nosync; do
      node_tag_value "$node_name" "$tag" >/dev/null
    done
  done
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
  local node_name="$1" tag_name="$2" var_name marker value
  var_name="NODE_$(printf '%s' "$node_name" | tr '[:lower:].-' '[:upper:]__')_TAGS_$(printf '%s' "$tag_name" | tr '[:lower:].-' '[:upper:]__')"
  marker="CONFIG_HAS_${var_name}"
  [[ "${!marker:-false}" == "true" ]] || die "required config [node.$node_name.tags].$tag_name is missing in $CONFIG_FILE"
  value="${!var_name:-}"
  case "${value,,}" in
    true|false) printf '%s\n' "${value,,}" ;;
    '') die "required config [node.$node_name.tags].$tag_name must not be empty in $CONFIG_FILE" ;;
    *) die "config [node.$node_name.tags].$tag_name must be true or false; got '$value'" ;;
  esac
}

apply_node_overrides() {
  local node_name="$1" prefix var base
  prefix="NODE_$(printf '%s' "$node_name" | tr '[:lower:].-' '[:upper:]__')_"
  for var in $(compgen -v "$prefix"); do
    [[ -n "${!var}" ]] || continue
    base="${var#$prefix}"
    case "$base" in
      PREFIX) [[ "${!var}" == /* ]] || die "config [node.$node_name].prefix must be an absolute path"; PG_PREFIX="${!var}" ;;
      DATA_DIR) [[ "${!var}" == /* ]] || die "config [node.$node_name].data_dir must be an absolute path"; PG_DATA="${!var}" ;;
      ETCD_DATA_DIR) [[ "${!var}" == /* ]] || die "config [node.$node_name].etcd_data_dir must be an absolute path"; ETCD_DATA="${!var}" ;;
      PATRONI_HOME) [[ "${!var}" == /* ]] || die "config [node.$node_name].patroni_home must be an absolute path"; PATRONI_HOME="${!var}" ;;
      PATRONI_LOG_DIR) [[ "${!var}" == /* ]] || die "config [node.$node_name].patroni_log_dir must be an absolute path"; PATRONI_LOG_DIR="${!var}" ;;
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

patroni_pg_hba_yaml() {
  local indent="${1:-    }" item node_ip
  for item in "${PG_NODES[@]}"; do
    node_ip="${item#*:}"
    printf '%s- host replication %s %s/32 trust\n' "$indent" "$REPLICATION_USER" "$node_ip"
    printf '%s- host all %s %s/32 trust\n' "$indent" "$REWIND_USER" "$node_ip"
  done
  printf '%s- host all all 0.0.0.0/0 scram-sha-256\n' "$indent"
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
  [[ -n "$PIP_SOURCE" ]] || return 0
  if [[ "$PIP_SOURCE" == *" "* ]]; then
    # shellcheck disable=SC2206
    PIP_SOURCE_ARGS=( $PIP_SOURCE )
  else
    PIP_SOURCE_ARGS=(--index-url "$(normalize_pip_index "$PIP_SOURCE")")
  fi
}

yum_source_args() {
  YUM_SOURCE_ARGS=()
  [[ -n "$YUM_SOURCE" ]] || return 0
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
  if [[ -n "$YUM_DISABLE_REPOS" ]]; then
    IFS=',' read -ra disabled_repos <<< "$YUM_DISABLE_REPOS"
    for disabled_repo in "${!disabled_repos[@]}"; do
      install_cmd+=("--disablerepo=$(trim "${disabled_repos[$disabled_repo]}")")
    done
  fi
  yum_source_args
  if [[ -n "$YUM_SOURCE" ]]; then
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

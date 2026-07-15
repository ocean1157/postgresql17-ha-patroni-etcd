#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config
apply_hardware_parameter_defaults
LOCAL_IP="$(current_ip)"
require_database_passwords

[[ "$(id -u)" -eq 0 ]] || die "run as root"

ssh_base=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
scp_base=(scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
if [[ -n "$SSH_KEY" ]]; then
  [[ -r "$SSH_KEY" ]] || die "configured SSH private key is not readable: $SSH_KEY"
  ssh_base+=(-i "$SSH_KEY")
  scp_base+=(-i "$SSH_KEY")
fi

if [[ -n "$SSH_PASSWORD" && -z "$SSH_KEY" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    log "sshpass 未安装，使用 yum/dnf 安装以支持密码方式分发项目"
    pkg_install sshpass
  fi
  ssh_base=(sshpass -p "$SSH_PASSWORD" "${ssh_base[@]}")
  scp_base=(sshpass -p "$SSH_PASSWORD" "${scp_base[@]}")
else
  # Key-based/default SSH authentication is the preferred path and does not
  # need sshpass. BatchMode prevents an unattended deployment from hanging on
  # an interactive password prompt when key authentication is not ready.
  ssh_base+=(-o BatchMode=yes)
  scp_base+=(-o BatchMode=yes)
fi

run_remote() {
  local ip="$1"
  shift
  "${ssh_base[@]}" "${SSH_USER}@${ip}" "$@"
}

run_remote_retry() {
  local ip="$1"
  shift
  local attempt
  for attempt in 1 2 3; do
    if run_remote "$ip" "$@"; then
      return 0
    fi
    log "节点 $ip 远程命令第 ${attempt} 次执行失败，5 秒后重试"
    sleep 5
  done
  return 1
}

node_project_dir() {
  local ip="$1"
  if [[ "$ip" == "$LOCAL_IP" ]]; then
    printf '%s\n' "$PROJECT_DIR"
  else
    printf '%s\n' "$INSTALL_ROOT"
  fi
}

copy_project() {
  local ip="$1"
  if [[ "$ip" == "$LOCAL_IP" ]]; then
    log "本机节点 $ip 直接使用当前项目目录：$PROJECT_DIR"
    return 0
  fi
  log "copy project to $ip:$INSTALL_ROOT"
  run_remote_retry "$ip" "mkdir -p '$INSTALL_ROOT'"
  tar -C "$PROJECT_DIR" \
    --exclude='./.git' \
    --exclude='./.idea' \
    --exclude='./.codex_remote.py' \
    --exclude='./deploy-logs' \
    -czf - . | "${ssh_base[@]}" "${SSH_USER}@${ip}" "tar -C '$INSTALL_ROOT' -xzf -"
}

install_node() {
  local ip="$1" remote_project_dir
  remote_project_dir="$(node_project_dir "$ip")"
  log "install node $ip"
  run_remote_retry "$ip" "cd '$remote_project_dir' && \
    PG_HARDWARE_DEFAULTS_RESOLVED=true \
    POSTGRESQL_CONF_SHARED_BUFFERS='$PGCONF_SHARED_BUFFERS' \
    POSTGRESQL_CONF_EFFECTIVE_CACHE_SIZE='$PGCONF_EFFECTIVE_CACHE_SIZE' \
    POSTGRESQL_CONF_MAX_CONNECTIONS='$PGCONF_MAX_CONNECTIONS' \
    POSTGRESQL_CONF_MAINTENANCE_WORK_MEM='$PGCONF_MAINTENANCE_WORK_MEM' \
    POSTGRESQL_CONF_MAX_WORKER_PROCESSES='$PGCONF_MAX_WORKER_PROCESSES' \
    POSTGRESQL_CONF_MAX_PARALLEL_WORKERS='$PGCONF_MAX_PARALLEL_WORKERS' \
    POSTGRESQL_CONF_MAX_PARALLEL_WORKERS_PER_GATHER='$PGCONF_MAX_PARALLEL_WORKERS_PER_GATHER' \
    SKIP_SERVICE_START=1 bash scripts/node-install.sh"
}

enable_etcd_unit() {
  local ip="$1"
  log "enable etcd systemd unit on $ip"
  run_remote_retry "$ip" "systemctl daemon-reload && systemctl enable etcd.service"
}

enable_patroni_unit() {
  local ip="$1"
  log "enable Patroni systemd unit on $ip"
  run_remote_retry "$ip" "systemctl daemon-reload && systemctl enable patroni.service"
}

start_etcd_node() {
  local ip="$1"
  log "start etcd on $ip"
  run_remote_retry "$ip" "systemctl reset-failed etcd.service || true; systemctl start --no-block etcd.service"
}

start_patroni_node() {
  local ip="$1"
  log "start patroni on $ip"
  run_remote_retry "$ip" "systemctl reset-failed patroni.service || true; systemctl start patroni.service"
}

verify_etcd_node() {
  local ip="$1"
  log "verify etcd service on $ip"
  run_remote_retry "$ip" "systemctl is-enabled etcd.service && systemctl is-active etcd.service"
}

verify_patroni_node() {
  local ip="$1"
  log "verify Patroni service on $ip"
  run_remote_retry "$ip" "systemctl is-enabled patroni.service && systemctl is-active patroni.service"
}

verify_etcd_install_node() {
  local ip="$1"
  log "verify etcd install files on $ip"
  run_remote_retry "$ip" "failed=0
check_path() {
  mode=\"\$1\"
  path=\"\$2\"
  case \"\$mode\" in
    x) test -x \"\$path\" ;;
    f) test -f \"\$path\" ;;
    d) test -d \"\$path\" ;;
    *) echo \"UNKNOWN-CHECK \$mode \$path\"; failed=1; return ;;
  esac
  if [ \"\$?\" -eq 0 ]; then
    echo \"OK \$mode \$path\"
  else
    echo \"MISSING \$mode \$path\"
    failed=1
  fi
}
check_path x '$ETCD_BIN_DIR/etcd'
check_path x '$ETCD_BIN_DIR/etcdctl'
check_path x '$ETCD_BIN_DIR/etcdutl'
check_path f '$ETCD_CONFIG_FILE'
check_path f /etc/systemd/system/etcd.service
exit \"\$failed\""
}

verify_patroni_install_node() {
  local ip="$1" node_name cron_expected=false
  node_name="$(node_name_by_ip_role "$ip" postgresql)"
  pg_probackup_cron_enabled_for_node "$node_name" && cron_expected=true
  log "verify PostgreSQL/Patroni install files on $ip"
  run_remote_retry "$ip" "failed=0
check_path() {
  mode=\"\$1\"
  path=\"\$2\"
  case \"\$mode\" in
    x) test -x \"\$path\" ;;
    f) test -f \"\$path\" ;;
    d) test -d \"\$path\" ;;
    *) echo \"UNKNOWN-CHECK \$mode \$path\"; failed=1; return ;;
  esac
  if [ \"\$?\" -eq 0 ]; then
    echo \"OK \$mode \$path\"
  else
    echo \"MISSING \$mode \$path\"
    failed=1
  fi
}
check_path f '$PATRONI_HOME/patroni.yml'
check_path x '$PATRONI_BIN'
check_path x '$PATRONICTL_BIN'
check_path x '$PG_PREFIX/bin/postgres'
check_path x '$PG_PREFIX/bin/pg_config'
check_path x '$PG_PREFIX/bin/pg_repack'
check_path f '$PG_PREFIX/share/extension/pg_repack.control'
check_path x '$PG_PROBACKUP_BINARY'
check_path x '$PG_PROBACKUP_JOB_SCRIPT'
check_path f /etc/systemd/system/patroni.service
if [[ '$cron_expected' == 'true' ]] && crontab -u '$POSTGRES_OS_USER' -l 2>/dev/null | grep -Fq '$PG_PROBACKUP_JOB_SCRIPT'; then
  echo 'OK postgres crontab $PG_PROBACKUP_JOB_SCRIPT'
elif [[ '$cron_expected' != 'true' ]] && ! crontab -u '$POSTGRES_OS_USER' -l 2>/dev/null | grep -Fq '$PG_PROBACKUP_JOB_SCRIPT'; then
  echo 'OK postgres crontab is disabled by backup_host=$PG_PROBACKUP_BACKUP_HOST'
else
  echo 'INVALID postgres crontab for backup_host=$PG_PROBACKUP_BACKUP_HOST'
  failed=1
fi
exit \"\$failed\""
}

create_database_extensions() {
  log "初始化 PostgreSQL 扩展 pg_cron、pg_repack 和 pg_stat_statements"
  run_remote_retry "$(primary_ip)" "leader_ip=\$('$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | awk '\$1 == \"|\" && \$6 == \"Leader\" {print \$4; exit}'); \
    test -n \"\$leader_ip\"; \
    PGPASSWORD='$POSTGRES_SUPERPASS' '$PG_PREFIX/bin/psql' -h \"\$leader_ip\" -p '$POSTGRES_PORT' -U '$POSTGRES_SUPERUSER' -d '$PGCONF_CRON_DATABASE_NAME' -v ON_ERROR_STOP=1 \
      -c 'CREATE EXTENSION IF NOT EXISTS pg_cron;' \
      -c 'CREATE EXTENSION IF NOT EXISTS pg_repack;' \
      -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;' \
      -c \"SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_cron','pg_repack','pg_stat_statements') ORDER BY extname;\""
}

initialize_pg_probackup_node() {
  local ip="$1" remote_project_dir
  remote_project_dir="$(node_project_dir "$ip")"
  log "initialize pg_probackup on $ip"
  run_remote_retry "$ip" "cd '$remote_project_dir' && PG_HARDWARE_DEFAULTS_RESOLVED=true bash scripts/node-install.sh --init-pg-probackup"
}

run_initial_full_backup_node() {
  local ip="$1"
  log "request initial FULL pg_probackup backup on $ip"
  run_remote_retry "$ip" "su - '$POSTGRES_OS_USER' -c \"'$PG_PROBACKUP_JOB_SCRIPT' FULL\""
}

verify_initial_full_backup() {
  local ip
  for ip in $(pg_node_ips); do
    if run_remote "$ip" "su - '$POSTGRES_OS_USER' -c \"'$PG_PROBACKUP_BINARY' show -B '$PG_PROBACKUP_BACKUP_DIR' --instance '$PG_PROBACKUP_INSTANCE'\" 2>/dev/null | grep -Eq 'FULL.*OK'"; then
      log "initial FULL pg_probackup backup verified on $ip"
      return 0
    fi
  done
  die "initial FULL pg_probackup backup was not found with status OK on any PostgreSQL node"
}

verify_max_connections_node() {
  local ip="$1"
  log "verify max_connections=$PGCONF_MAX_CONNECTIONS on $ip"
  run_remote_retry "$ip" "actual=\$(su - '$POSTGRES_OS_USER' -c \"psql -XAt -c 'show max_connections'\"); \
    test \"\$actual\" = '$PGCONF_MAX_CONNECTIONS' || { echo \"max_connections expected=$PGCONF_MAX_CONNECTIONS actual=\$actual\"; exit 1; }"
}

apply_patroni_runtime_config() {
  log "写入 Patroni 全局动态配置，确保硬件参数和预加载参数对首次部署及复跑生效"
  run_remote_retry "$(primary_ip)" "'$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' edit-config --force \
    --set 'postgresql.parameters.shared_buffers=$PGCONF_SHARED_BUFFERS' \
    --set 'postgresql.parameters.effective_cache_size=$PGCONF_EFFECTIVE_CACHE_SIZE' \
    --set 'postgresql.parameters.max_connections=$PGCONF_MAX_CONNECTIONS' \
    --set 'postgresql.parameters.maintenance_work_mem=$PGCONF_MAINTENANCE_WORK_MEM' \
    --set 'postgresql.parameters.max_worker_processes=$PGCONF_MAX_WORKER_PROCESSES' \
    --set 'postgresql.parameters.max_parallel_workers=$PGCONF_MAX_PARALLEL_WORKERS' \
    --set 'postgresql.parameters.max_parallel_workers_per_gather=$PGCONF_MAX_PARALLEL_WORKERS_PER_GATHER' \
    --set 'postgresql.parameters.shared_preload_libraries=$PGCONF_SHARED_PRELOAD_LIBRARIES' \
    --set 'postgresql.parameters.cron.database_name=$PGCONF_CRON_DATABASE_NAME'"

  log "等待 Patroni 将动态配置写入各节点"
  sleep 5
  log "重启 Patroni 管理的 PostgreSQL 实例以应用 postmaster 参数"
  run_remote_retry "$(primary_ip)" "'$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' restart --force '$SCOPE'"

  log "wait for Patroni cluster after runtime config"
  run_remote_retry "$(primary_ip)" "for i in {1..120}; do '$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'Leader' && '$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'streaming' && exit 0; sleep 2; done; journalctl -u patroni.service -n 120 --no-pager; exit 1"

  # When max_connections is reduced, replicas temporarily keep the higher
  # value recorded in pg_controldata. Checkpoint the leader, then restart only
  # members that Patroni marks pending so the lower value can converge safely.
  run_remote_retry "$(primary_ip)" "leader_ip=\$('$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | awk '\$1 == \"|\" && \$6 == \"Leader\" {print \$4; exit}'); \
    test -n \"\$leader_ip\"; \
    PGPASSWORD='$POSTGRES_SUPERPASS' '$PG_PREFIX/bin/psql' -h \"\$leader_ip\" -p '$POSTGRES_PORT' -U '$POSTGRES_SUPERUSER' -d '$PGDATABASE' -v ON_ERROR_STOP=1 -c 'CHECKPOINT;'"
  sleep 5
  run_remote_retry "$(primary_ip)" "'$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' restart --force --pending '$SCOPE' || true"
  run_remote_retry "$(primary_ip)" "for i in {1..120}; do '$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'Leader' && '$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'streaming' && exit 0; sleep 2; done; journalctl -u patroni.service -n 120 --no-pager; exit 1"
}

parallel_limit() {
  local node_count configured
  node_count="$(all_node_ips | wc -l | tr -d ' ')"
  configured="$DEPLOY_PARALLEL_JOBS"
  if [[ "$configured" =~ ^[0-9]+$ ]] && [[ "$configured" -gt 0 ]]; then
    if [[ "$configured" -gt "$node_count" ]]; then
      printf '%s\n' "$node_count"
    else
      printf '%s\n' "$configured"
    fi
  else
    printf '%s\n' "$node_count"
  fi
}

run_parallel_phase() {
  local phase="$1" func="$2" limit running=0 ip pid failed=0
  shift 2
  local -a pids=()
  local -A pid_ip=()
  limit="$(parallel_limit)"
  log "${phase} 开始，并发度=${limit}"

  for ip in "$@"; do
    (
      "$func" "$ip"
    ) &
    pid=$!
    pids+=("$pid")
    pid_ip["$pid"]="$ip"
    running=$((running + 1))

    if [[ "$running" -ge "$limit" ]]; then
      local first_pid="${pids[0]}"
      if ! wait "$first_pid"; then
        log "${phase} 节点 ${pid_ip[$first_pid]} 执行失败"
        failed=1
      fi
      unset "pid_ip[$first_pid]"
      pids=("${pids[@]:1}")
      running=$((running - 1))
    fi
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      log "${phase} 节点 ${pid_ip[$pid]} 执行失败"
      failed=1
    fi
  done

  [[ "$failed" -eq 0 ]] || die "${phase} 失败"
  log "${phase} 完成"
}

main() {
  local ip
  local -a node_ips pg_ips etcd_ips
  # shellcheck disable=SC2207
  node_ips=($(all_node_ips))
  # shellcheck disable=SC2207
  pg_ips=($(pg_node_ips))
  # shellcheck disable=SC2207
  etcd_ips=($(etcd_node_ips))

  run_parallel_phase "分发项目" copy_project "${node_ips[@]}"
  run_parallel_phase "安装节点" install_node "${node_ips[@]}"
  run_parallel_phase "校验 etcd 安装文件" verify_etcd_install_node "${etcd_ips[@]}"
  run_parallel_phase "校验 PostgreSQL/Patroni 安装文件" verify_patroni_install_node "${pg_ips[@]}"
  run_parallel_phase "启用 etcd systemd 单元" enable_etcd_unit "${etcd_ips[@]}"
  run_parallel_phase "启用 Patroni systemd 单元" enable_patroni_unit "${pg_ips[@]}"
  run_parallel_phase "启动 etcd" start_etcd_node "${etcd_ips[@]}"

  log "wait for etcd health"
  run_remote_retry "$(primary_etcd_ip)" "test -x '$ETCD_BIN_DIR/etcdctl' && for i in {1..90}; do env -u ETCDCTL_ENDPOINTS ETCDCTL_API=3 '$ETCD_BIN_DIR/etcdctl' --endpoints=$(etcd_client_endpoints) endpoint health && exit 0; sleep 2; done; systemctl status etcd.service --no-pager; exit 1"

  run_parallel_phase "启动 patroni" start_patroni_node "${pg_ips[@]}"

  log "wait for Patroni cluster"
  run_remote_retry "$(primary_ip)" "for i in {1..120}; do '$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'Leader' && '$PATRONICTL_BIN' -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'streaming' && exit 0; sleep 2; done; journalctl -u patroni.service -n 120 --no-pager; exit 1"

  apply_patroni_runtime_config
  run_parallel_phase "验证 max_connections" verify_max_connections_node "${pg_ips[@]}"
  run_parallel_phase "初始化 pg_probackup 实例" initialize_pg_probackup_node "${pg_ips[@]}"
  create_database_extensions
  run_parallel_phase "执行首次 pg_probackup 全量备份" run_initial_full_backup_node "${pg_ips[@]}"
  verify_initial_full_backup
  run_parallel_phase "验证 etcd 服务" verify_etcd_node "${etcd_ips[@]}"
  run_parallel_phase "验证 Patroni 服务" verify_patroni_node "${pg_ips[@]}"

  log "cluster deployment commands finished"
  log "check with: su - $POSTGRES_OS_USER -c '$PATRONICTL_BIN -c $PATRONI_HOME/patroni.yml list'"
}

main "$@"

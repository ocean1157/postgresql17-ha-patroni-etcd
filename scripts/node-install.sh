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

[[ "$(id -u)" -eq 0 ]] || die "run as root"

ARCH="$(detect_arch)"
MY_IP="$(current_ip)"
MY_POSTGRESQL_NAME="$(node_name_by_ip_role "$MY_IP" postgresql || true)"
MY_ETCD_NAME="$(node_name_by_ip_role "$MY_IP" etcd || true)"
MY_NAME="${MY_POSTGRESQL_NAME:-$MY_ETCD_NAME}"
[[ -n "$MY_NAME" ]] || die "current node IP $MY_IP is not present in PostgreSQL or etcd nodes"
apply_node_overrides "$MY_NAME"
IS_POSTGRESQL_NODE=false
IS_ETCD_NODE=false
is_postgresql_node "$MY_IP" && IS_POSTGRESQL_NODE=true
is_etcd_node "$MY_IP" && IS_ETCD_NODE=true

is_true() {
  [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" || "${1,,}" == "on" ]]
}

run_with_heartbeat() {
  local label="$1"
  shift
  log "${label} start"
  "$@" &
  local pid=$!
  while kill -0 "$pid" >/dev/null 2>&1; do
    sleep 30
    if kill -0 "$pid" >/dev/null 2>&1; then
      log "${label} still running, pid=$pid"
    fi
  done
  wait "$pid"
  log "${label} finished"
}

install_prereqs() {
  log "install system dependencies according to repository mode"
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    local pkg missing_count=0
    local -a prereq_pkgs missing_pkgs=()
    # shellcheck disable=SC2207
    if is_true "$IS_POSTGRESQL_NODE"; then
      prereq_pkgs=($(rpm_prereq_packages))
    else
      prereq_pkgs=($(rpm_etcd_prereq_packages))
    fi
    for pkg in "${prereq_pkgs[@]}"; do
      if ! rpm -q "$pkg" >/dev/null 2>&1; then
        missing_pkgs+=("$pkg")
        missing_count=$((missing_count + 1))
      fi
    done
    if [[ "$missing_count" -eq 0 ]]; then
      log "system dependencies already installed; skipping yum/dnf"
    else
      pkg_install "${missing_pkgs[@]}"
    fi
    if is_true "$IS_POSTGRESQL_NODE"; then
      ensure_python3_command || die "python3 and pip are required after installing system dependencies"
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    if is_true "$IS_POSTGRESQL_NODE"; then
      pkg_install gcc make bison flex libreadline-dev zlib1g-dev libssl-dev uuid-dev libicu-dev perl tar gzip python3 python3-dev python3-pip python3-venv sudo chrony
    else
      pkg_install tar gzip sudo chrony
    fi
  else
    die "no supported package manager found"
  fi
}

configure_os() {
  log "configure operating system baseline"

  if [[ -n "$OS_TIMEZONE" ]] && command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$OS_TIMEZONE" || true
  fi

  if is_true "$OS_ENABLE_CHRONY"; then
    systemctl enable --now chronyd >/dev/null 2>&1 || systemctl enable --now chrony >/dev/null 2>&1 || true
  fi

  if is_true "$OS_DISABLE_TRANSPARENT_HUGEPAGE"; then
    cat >/etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=postgresql.service patroni.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -f /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true; test -f /sys/kernel/mm/transparent_hugepage/defrag && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now disable-thp.service >/dev/null 2>&1 || true
  fi

  if is_true "$OS_APPLY_SYSCTL"; then
    cat >/etc/sysctl.d/99-postgresql-ha.conf <<'EOF'
fs.aio-max-nr = 1048576
fs.file-max = 76724600
fs.nr_open = 20480000
net.core.netdev_max_backlog = 10000
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.somaxconn = 4096
net.core.wmem_default = 262144
net.core.wmem_max = 4194304
net.ipv4.ip_local_port_range = 40000 65535
net.ipv4.tcp_fin_timeout = 5
vm.overcommit_memory = 0
vm.swappiness = 10
EOF
    sysctl --system >/dev/null || true
  fi

  if is_true "$OS_APPLY_LIMITS"; then
    cat >/etc/security/limits.d/99-postgresql-ha.conf <<EOF
${POSTGRES_OS_USER} soft nproc unlimited
${POSTGRES_OS_USER} hard nproc unlimited
${POSTGRES_OS_USER} soft nofile 102400
${POSTGRES_OS_USER} hard nofile 102400
${POSTGRES_OS_USER} soft stack unlimited
${POSTGRES_OS_USER} hard stack unlimited
${POSTGRES_OS_USER} soft core unlimited
${POSTGRES_OS_USER} hard core unlimited
${POSTGRES_OS_USER} soft memlock unlimited
${POSTGRES_OS_USER} hard memlock unlimited
EOF
  fi

  if [[ "${OS_MANAGE_SELINUX,,}" == "permissive" ]] && command -v getenforce >/dev/null 2>&1; then
    setenforce 0 >/dev/null 2>&1 || true
    if [[ -f /etc/selinux/config ]]; then
      sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    fi
  fi
}

configure_firewall() {
  if is_true "$OS_OPEN_FIREWALL_PORTS" && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "open firewall ports for PostgreSQL HA"
    if is_true "$IS_POSTGRESQL_NODE"; then
      firewall-cmd --permanent --add-port="${POSTGRES_PORT}/tcp"
      firewall-cmd --permanent --add-port="${PATRONI_PORT}/tcp"
    fi
    if is_true "$IS_ETCD_NODE"; then
      firewall-cmd --permanent --add-port="${ETCD_CLIENT_PORT}/tcp"
      firewall-cmd --permanent --add-port="${ETCD_PEER_PORT}/tcp"
    fi
    firewall-cmd --reload
  fi
}

create_users_dirs() {
  log "create directories for node roles: postgresql=$IS_POSTGRESQL_NODE etcd=$IS_ETCD_NODE"
  id "$POSTGRES_OS_USER" >/dev/null 2>&1 || useradd -m -U "$POSTGRES_OS_USER"
  if is_true "$IS_ETCD_NODE"; then
    mkdir -p "$ETCD_DATA" "$ETCD_BIN_DIR"
    chown -R "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$ETCD_DATA" "$ETCD_BIN_DIR"
    chmod 755 "$ETCD_DATA" "$ETCD_BIN_DIR"
  fi
  if is_true "$IS_POSTGRESQL_NODE"; then
    mkdir -p "$PG_PREFIX" "$PG_DATA" "$PG_PROBACKUP_BACKUP_DIR" "$PATRONI_HOME" "$PATRONI_LOG_DIR" "$PATRONI_BIN_DIR" /var/run/postgresql
    chown -R "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PG_PREFIX" "$PG_DATA" "$PG_PROBACKUP_BACKUP_DIR" "$PATRONI_LOG_DIR" "$PATRONI_HOME" "$PATRONI_BIN_DIR"
    chown "$POSTGRES_OS_USER:$POSTGRES_OS_USER" /var/run/postgresql
    chmod 755 "$PG_PREFIX" "$PATRONI_HOME" "$PATRONI_BIN_DIR"
    chmod 775 /var/run/postgresql
    chmod 700 "$PG_DATA" "$PG_PROBACKUP_BACKUP_DIR"
  fi
}

reconcile_node_roles() {
  # Preserve data and installed binaries, but make sure services generated by a
  # previous topology cannot keep running after this node loses a role.
  if ! is_true "$IS_POSTGRESQL_NODE" && [[ -f /etc/systemd/system/patroni.service ]]; then
    systemctl disable --now patroni.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/patroni.service
  fi
  if ! is_true "$IS_ETCD_NODE" && [[ -f /etc/systemd/system/etcd.service ]]; then
    systemctl disable --now etcd.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/etcd.service
  fi
  systemctl daemon-reload
}

write_postgres_env() {
  log "write postgres environment file"
  local pg_home
  pg_home="$(getent passwd "$POSTGRES_OS_USER" | cut -d: -f6)"
  [[ -n "$pg_home" ]] || pg_home="/home/${POSTGRES_OS_USER}"
  cat >"${pg_home}/.pgev" <<EOF
# PostgreSQL HA environment generated by installer.
export PGHOME=${PG_PREFIX}
export PGDATA=${PG_DATA}
export PGPORT=${POSTGRES_PORT}
export PGDATABASE=${PGDATABASE}
export PGUSER=${POSTGRES_SUPERUSER}
export PGHOST=/var/run/postgresql
export PATRONI_CONFIG=${PATRONI_HOME}/patroni.yml
export PATRONICTL_CONFIG_FILE=${PATRONI_HOME}/patroni.yml
export ETCDCTL_ENDPOINTS=$(etcd_client_endpoints)
export PG_PROBACKUP=${PG_PROBACKUP_BINARY}
export PG_PROBACKUP_BACKUP_DIR=${PG_PROBACKUP_BACKUP_DIR}
export PATH=\$PGHOME/bin:${PATRONI_VENV}/bin:${PATRONI_BIN_DIR}:${ETCD_BIN_DIR}:$(dirname "$PG_PROBACKUP_BINARY"):\$PATH
export LD_LIBRARY_PATH=\$PGHOME/lib:\${LD_LIBRARY_PATH:-}
EOF
  chown "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "${pg_home}/.pgev"
  chmod 0640 "${pg_home}/.pgev"
  if ! grep -q 'source ~/.pgev' "${pg_home}/.bashrc" 2>/dev/null; then
    printf '\n# PostgreSQL HA environment\n[ -f ~/.pgev ] && source ~/.pgev\n' >> "${pg_home}/.bashrc"
  fi
  chown "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "${pg_home}/.bashrc"
}

install_postgres() {
  if [[ -x "$PG_PREFIX/bin/postgres" ]]; then
    log "PostgreSQL already installed at $PG_PREFIX"
    return 0
  fi
  local tgz="$PROJECT_DIR/packages/postgresql-${POSTGRES_VERSION}.tar.gz"
  [[ -f "$tgz" ]] || die "missing $tgz; run scripts/download-package.sh first"
  log "build PostgreSQL $POSTGRES_VERSION"
  local build_dir="/tmp/postgresql-${POSTGRES_VERSION}-build"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  tar -xzf "$tgz" -C "$build_dir" --strip-components=1
  # shellcheck disable=SC2206
  local configure_options=( $PG_CONFIGURE_OPTIONS )
  (
    cd "$build_dir"
    run_with_heartbeat "PostgreSQL configure" ./configure --prefix="$PG_PREFIX" "${configure_options[@]}"
    run_with_heartbeat "PostgreSQL make" make -j"$(nproc)"
    run_with_heartbeat "PostgreSQL make install" make install
    cd contrib
    run_with_heartbeat "PostgreSQL contrib make" make -j"$(nproc)"
    run_with_heartbeat "PostgreSQL contrib make install" make install
  )
  chown -R "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PG_PREFIX"
}

install_etcd() {
  if [[ -x "$ETCD_BIN_DIR/etcd" && -x "$ETCD_BIN_DIR/etcdctl" && -x "$ETCD_BIN_DIR/etcdutl" ]]; then
    log "etcd already installed at $ETCD_BIN_DIR"
    return 0
  fi
  local tgz="$PROJECT_DIR/packages/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
  [[ -f "$tgz" ]] || die "missing $tgz; run scripts/download-package.sh first"
  log "install etcd $ETCD_VERSION"
  local tmp="/tmp/etcd-${ETCD_VERSION}"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  tar -xzf "$tgz" -C "$tmp" --strip-components=1
  mkdir -p "$ETCD_BIN_DIR"
  install -m 0755 "$tmp/etcd" "$ETCD_BIN_DIR/etcd"
  install -m 0755 "$tmp/etcdctl" "$ETCD_BIN_DIR/etcdctl"
  install -m 0755 "$tmp/etcdutl" "$ETCD_BIN_DIR/etcdutl"
}

install_pg_probackup() {
  if [[ -x "$PG_PROBACKUP_BINARY" ]]; then
    log "pg_probackup already installed at $PG_PROBACKUP_BINARY"
    return 0
  fi
  local tgz="$PROJECT_DIR/packages/pg_probackup-${PG_PROBACKUP_VERSION}.tar.gz"
  local pg_tgz="$PROJECT_DIR/packages/postgresql-${POSTGRES_VERSION}.tar.gz"
  [[ -f "$tgz" ]] || die "missing $tgz; run scripts/download-package.sh first"
  [[ -f "$pg_tgz" ]] || die "missing $pg_tgz; run scripts/download-package.sh first"
  log "build pg_probackup $PG_PROBACKUP_VERSION"
  local build_dir="/tmp/pg_probackup-${PG_PROBACKUP_VERSION}-build"
  local pg_src_dir="/tmp/postgresql-${POSTGRES_VERSION}-src-for-pg_probackup"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  tar -xzf "$tgz" -C "$build_dir" --strip-components=1
  if [[ ! -f "$pg_src_dir/src/include/portability/instr_time.h" ]]; then
    rm -rf "$pg_src_dir"
    mkdir -p "$pg_src_dir"
    tar -xzf "$pg_tgz" -C "$pg_src_dir" --strip-components=1
  fi
  (
    cd "$build_dir"
    run_with_heartbeat "pg_probackup make" env PATH="$PG_PREFIX/bin:$PATH" make USE_PGXS=1 top_srcdir="$pg_src_dir"
    run_with_heartbeat "pg_probackup make install" env PATH="$PG_PREFIX/bin:$PATH" make USE_PGXS=1 top_srcdir="$pg_src_dir" install
  )
  local installed_binary="$PG_PREFIX/bin/pg_probackup"
  [[ -x "$installed_binary" ]] || die "pg_probackup build did not produce $installed_binary"
  mkdir -p "$(dirname "$PG_PROBACKUP_BINARY")"
  ln -sf "$installed_binary" "$PG_PROBACKUP_BINARY"
}

install_pg_cron() {
  if [[ -f "$PG_PREFIX/share/extension/pg_cron.control" ]]; then
    log "pg_cron already installed under $PG_PREFIX"
    return 0
  fi

  local tgz="$PROJECT_DIR/packages/pg_cron-${PG_CRON_VERSION}.tar.gz"
  [[ -f "$tgz" ]] || die "missing $tgz; run scripts/download-package.sh first"
  [[ -x "$PG_PREFIX/bin/pg_config" ]] || die "missing $PG_PREFIX/bin/pg_config; install PostgreSQL first"

  log "build pg_cron $PG_CRON_VERSION"
  local build_dir="/tmp/pg_cron-${PG_CRON_VERSION}-build"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  tar -xzf "$tgz" -C "$build_dir" --strip-components=1
  (
    cd "$build_dir"
    run_with_heartbeat "pg_cron make" make PG_CONFIG="$PG_PREFIX/bin/pg_config"
    run_with_heartbeat "pg_cron make install" make PG_CONFIG="$PG_PREFIX/bin/pg_config" install
  )
}

install_pg_repack() {
  if [[ -x "$PG_PREFIX/bin/pg_repack" && -f "$PG_PREFIX/share/extension/pg_repack.control" ]]; then
    log "pg_repack already installed under $PG_PREFIX"
    return 0
  fi

  local tgz="$PROJECT_DIR/packages/pg_repack-${PG_REPACK_VERSION}.tar.gz"
  [[ -f "$tgz" ]] || die "missing $tgz; run scripts/download-package.sh first"
  [[ -x "$PG_PREFIX/bin/pg_config" ]] || die "missing $PG_PREFIX/bin/pg_config; install PostgreSQL first"

  log "build pg_repack $PG_REPACK_VERSION"
  local build_dir="/tmp/pg_repack-${PG_REPACK_VERSION}-build"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  tar -xzf "$tgz" -C "$build_dir" --strip-components=1
  (
    cd "$build_dir"
    run_with_heartbeat "pg_repack make" make PG_CONFIG="$PG_PREFIX/bin/pg_config"
    run_with_heartbeat "pg_repack make install" make PG_CONFIG="$PG_PREFIX/bin/pg_config" install
  )
  [[ -x "$PG_PREFIX/bin/pg_repack" ]] || die "pg_repack installation did not produce $PG_PREFIX/bin/pg_repack"
  [[ -f "$PG_PREFIX/share/extension/pg_repack.control" ]] || die "pg_repack installation did not produce its extension control file"
}

install_patroni() {
  cd "$PROJECT_DIR"

  if [[ -x "$PATRONI_VENV/bin/patroni" ]] && "$PATRONI_VENV/bin/patroni" --version 2>/dev/null | grep -q "$PATRONI_VERSION"; then
    log "Patroni $PATRONI_VERSION already installed"
    mkdir -p "$PATRONI_BIN_DIR"
    ln -sf "$PATRONI_VENV/bin/patroni" "$PATRONI_BIN"
    ln -sf "$PATRONI_VENV/bin/patronictl" "$PATRONICTL_BIN"
    return 0
  fi

  local wheel_dir selected_wheel_dir
  wheel_dir="$PROJECT_DIR/packages/python"
  selected_wheel_dir="$(select_python_package_dir || true)"
  [[ -n "$selected_wheel_dir" ]] && wheel_dir="$selected_wheel_dir"
  local offline_mode="${OFFLINE_INSTALL,,}"

  pip_install_virtualenv_online() {
    local -a virtualenv_args=(install --upgrade --user)
    pip_source_args
    if [[ -n "$PIP_SOURCE" ]]; then
      virtualenv_args+=("${PIP_SOURCE_ARGS[@]}")
    fi
    virtualenv_args+=(virtualenv)
    python3 -m pip "${virtualenv_args[@]}"
  }

  pip_install_virtualenv_local() {
    [[ -d "$wheel_dir" ]] && compgen -G "$wheel_dir/*" >/dev/null || return 1
    python3 -m pip install --user --no-index --find-links "$wheel_dir" virtualenv
  }

  log "install Patroni venv"
  if python3 -m venv "$PATRONI_VENV" >/dev/null 2>&1; then
    :
  else
    if [[ "$offline_mode" == "true" ]]; then
      pip_install_virtualenv_local || die "offline_install=true but packages/python has no virtualenv package"
    elif pip_install_virtualenv_online; then
      :
    elif [[ "$offline_mode" != "false" ]]; then
      log "pip online install for virtualenv failed; falling back to packages/python"
      pip_install_virtualenv_local || die "pip online install failed and packages/python has no virtualenv package"
    else
      die "pip online install for virtualenv failed"
    fi
    python3 -m virtualenv "$PATRONI_VENV"
  fi

  patroni_pip_install_online() {
    local -a pip_args=(--retries 10 --timeout 120)
    pip_source_args
    if [[ -n "$PIP_SOURCE" ]]; then
      pip_args+=("${PIP_SOURCE_ARGS[@]}")
    fi
    run_with_heartbeat "Patroni venv pip bootstrap online" env PIP_DEFAULT_TIMEOUT=120 "$PATRONI_VENV/bin/pip" install --upgrade "${pip_args[@]}" "pip<22" setuptools wheel
    run_with_heartbeat "Patroni pip install online" env PIP_DEFAULT_TIMEOUT=120 "$PATRONI_VENV/bin/pip" install "${pip_args[@]}" "patroni[etcd3]==${PATRONI_VERSION}" "psycopg2-binary==2.9.5" "ydiff==1.4.2" cdiff
  }

  patroni_pip_install_local() {
    [[ -d "$wheel_dir" ]] && compgen -G "$wheel_dir/*" >/dev/null || return 1
    local -a pip_args=(--retries 10 --timeout 120 --no-index --find-links "$wheel_dir")
    log "using packages/python local Python packages with pip --no-index"
    run_with_heartbeat "Patroni venv pip bootstrap local" env PIP_DEFAULT_TIMEOUT=120 "$PATRONI_VENV/bin/pip" install "${pip_args[@]}" --upgrade "pip<22" setuptools wheel
    run_with_heartbeat "Patroni pip install local" env PIP_DEFAULT_TIMEOUT=120 "$PATRONI_VENV/bin/pip" install "${pip_args[@]}" "patroni[etcd3]==${PATRONI_VERSION}" "psycopg2-binary==2.9.5" "ydiff==1.4.2" cdiff
  }

  if [[ "$offline_mode" == "true" ]]; then
    patroni_pip_install_local || die "offline_install=true but packages/python has no usable Python packages"
  elif patroni_pip_install_online; then
    :
  elif [[ "$offline_mode" != "false" ]]; then
    log "pip online install failed; falling back to packages/python"
    patroni_pip_install_local || die "pip online install failed and packages/python has no usable Python packages"
  else
    die "pip online install failed"
  fi

  mkdir -p "$PATRONI_BIN_DIR"
  ln -sf "$PATRONI_VENV/bin/patroni" "$PATRONI_BIN"
  ln -sf "$PATRONI_VENV/bin/patronictl" "$PATRONICTL_BIN"
}
write_etcd_config() {
  local initial_cluster
  initial_cluster="$(etcd_initial_cluster)"
  cat >"$ETCD_CONFIG_FILE" <<EOF
name: ${MY_ETCD_NAME}
data-dir: ${ETCD_DATA}/${MY_ETCD_NAME}
initial-advertise-peer-urls: http://${MY_IP}:${ETCD_PEER_PORT}
listen-peer-urls: http://${MY_IP}:${ETCD_PEER_PORT}
listen-client-urls: http://${MY_IP}:${ETCD_CLIENT_PORT},http://127.0.0.1:${ETCD_CLIENT_PORT}
advertise-client-urls: http://${MY_IP}:${ETCD_CLIENT_PORT}
initial-cluster-token: ${CLUSTER_NAME}
initial-cluster: ${initial_cluster}
initial-cluster-state: new
logger: zap
log-outputs: [stderr]
EOF

  cat >/etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd key-value store for PostgreSQL HA
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=${ETCD_BIN_DIR}/etcd --config-file ${ETCD_CONFIG_FILE}
Restart=on-failure
RestartSec=5
TimeoutStartSec=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

write_vip_callback() {
  cat >"$PATRONI_HOME/vip_callback.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ACTION="\${1:-}"
ROLE="\${2:-}"
VIP_ADDRESS="${VIP_ADDRESS}"
VIP_CIDR="${VIP_CIDR}"
VIP_DEVICE="${VIP_DEVICE}"
VIP_LABEL="${VIP_LABEL}"

[[ -n "\$VIP_ADDRESS" ]] || exit 0

has_vip() {
  /sbin/ip addr show dev "\$VIP_DEVICE" | grep -qw "\$VIP_ADDRESS"
}

add_vip() {
  if ! has_vip; then
    sudo /sbin/ip addr add "\${VIP_ADDRESS}/\${VIP_CIDR}" dev "\$VIP_DEVICE" label "\${VIP_DEVICE}:\${VIP_LABEL}"
    sudo /usr/sbin/arping -q -A -c 2 -I "\$VIP_DEVICE" "\$VIP_ADDRESS" || true
  fi
}

del_vip() {
  if has_vip; then
    sudo /sbin/ip addr del "\${VIP_ADDRESS}/\${VIP_CIDR}" dev "\$VIP_DEVICE" label "\${VIP_DEVICE}:\${VIP_LABEL}" || true
  fi
}

case "\$ACTION:\$ROLE" in
  on_start:master|on_start:primary|on_role_change:master|on_role_change:primary) add_vip ;;
  on_stop:master|on_stop:primary|on_role_change:replica|on_role_change:slave) del_vip ;;
esac
EOF
  chmod 0755 "$PATRONI_HOME/vip_callback.sh"
  chown "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PATRONI_HOME/vip_callback.sh"

  if [[ -n "$VIP_ADDRESS" ]]; then
    cat >/etc/sudoers.d/postgres-patroni-vip <<EOF
${POSTGRES_OS_USER} ALL=(root) NOPASSWD: /sbin/ip, /usr/sbin/arping
EOF
    chmod 0440 /etc/sudoers.d/postgres-patroni-vip
  fi
}

write_patroni_config() {
  local etcd_hosts
  etcd_hosts="$(etcd_hosts_yaml)"
  local tag_nofailover tag_noloadbalance tag_clonefrom tag_nosync
  tag_nofailover="$(node_tag_value "$MY_POSTGRESQL_NAME" nofailover)"
  tag_noloadbalance="$(node_tag_value "$MY_POSTGRESQL_NAME" noloadbalance)"
  tag_clonefrom="$(node_tag_value "$MY_POSTGRESQL_NAME" clonefrom)"
  tag_nosync="$(node_tag_value "$MY_POSTGRESQL_NAME" nosync)"
  cat >"$PATRONI_HOME/patroni.yml" <<EOF
scope: ${SCOPE}
namespace: /service/
name: ${MY_POSTGRESQL_NAME}

restapi:
  listen: ${MY_IP}:${PATRONI_PORT}
  connect_address: ${MY_IP}:${PATRONI_PORT}

etcd3:
  hosts:
${etcd_hosts}

bootstrap:
  dcs:
    ttl: ${PATRONI_TTL}
    loop_wait: ${PATRONI_LOOP_WAIT}
    retry_timeout: ${PATRONI_RETRY_TIMEOUT}
    maximum_lag_on_failover: ${PATRONI_MAXIMUM_LAG_ON_FAILOVER}
    synchronous_mode: ${SYNCHRONOUS_MODE}
    synchronous_mode_strict: ${SYNCHRONOUS_MODE_STRICT}
    synchronous_node_count: ${SYNCHRONOUS_NODE_COUNT}
    postgresql:
      use_pg_rewind: ${PATRONI_USE_PG_REWIND}
      use_slots: ${PATRONI_USE_SLOTS}
      parameters:
        listen_addresses: '${PGCONF_LISTEN_ADDRESSES}'
        port: ${POSTGRES_PORT}
        max_connections: ${PGCONF_MAX_CONNECTIONS}
        shared_buffers: ${PGCONF_SHARED_BUFFERS}
        effective_cache_size: ${PGCONF_EFFECTIVE_CACHE_SIZE}
        maintenance_work_mem: ${PGCONF_MAINTENANCE_WORK_MEM}
        max_worker_processes: ${PGCONF_MAX_WORKER_PROCESSES}
        max_parallel_workers: ${PGCONF_MAX_PARALLEL_WORKERS}
        max_parallel_workers_per_gather: ${PGCONF_MAX_PARALLEL_WORKERS_PER_GATHER}
        work_mem: ${PGCONF_WORK_MEM}
        wal_level: ${PGCONF_WAL_LEVEL}
        wal_log_hints: '${PGCONF_WAL_LOG_HINTS}'
        max_wal_senders: ${PGCONF_MAX_WAL_SENDERS}
        max_replication_slots: ${PGCONF_MAX_REPLICATION_SLOTS}
        wal_keep_size: ${PGCONF_WAL_KEEP_SIZE}
        max_wal_size: ${PGCONF_MAX_WAL_SIZE}
        checkpoint_completion_target: ${PGCONF_CHECKPOINT_COMPLETION_TARGET}
        hot_standby: '${PGCONF_HOT_STANDBY}'
        hot_standby_feedback: '${PGCONF_HOT_STANDBY_FEEDBACK}'
        password_encryption: ${PGCONF_PASSWORD_ENCRYPTION}
        shared_preload_libraries: '${PGCONF_SHARED_PRELOAD_LIBRARIES}'
        pg_stat_statements.max: ${PGCONF_PG_STAT_STATEMENTS_MAX}
        pg_stat_statements.track: ${PGCONF_PG_STAT_STATEMENTS_TRACK}
        cron.database_name: ${PGCONF_CRON_DATABASE_NAME}
        logging_collector: '${PGCONF_LOGGING_COLLECTOR}'
        log_directory: ${PGCONF_LOG_DIRECTORY}
        log_filename: ${PGCONF_LOG_FILENAME}
        log_line_prefix: '${PGCONF_LOG_LINE_PREFIX}'
        log_min_duration_statement: ${PGCONF_LOG_MIN_DURATION_STATEMENT}
        archive_mode: '${PGCONF_ARCHIVE_MODE}'
        archive_command: '${PGCONF_ARCHIVE_COMMAND}'
  initdb:
    - encoding: UTF8
    - locale: C
    - data-checksums
  pg_hba:
    - host all all 0.0.0.0/0 scram-sha-256
    - host replication ${REPLICATION_USER} 0.0.0.0/0 scram-sha-256
  users:
    ${REWIND_USER}:
      password: ${REWIND_PASS}
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:${POSTGRES_PORT}
  connect_address: ${MY_IP}:${POSTGRES_PORT}
  data_dir: ${PG_DATA}
  bin_dir: ${PG_PREFIX}/bin
  config_dir: ${PG_DATA}
  pgpass: /home/${POSTGRES_OS_USER}/.pgpass
  authentication:
    superuser:
      username: ${POSTGRES_SUPERUSER}
      password: ${POSTGRES_SUPERPASS}
    replication:
      username: ${REPLICATION_USER}
      password: ${REPLICATION_PASS}
    rewind:
      username: ${REWIND_USER}
      password: ${REWIND_PASS}
  callbacks:
    on_start: ${PATRONI_HOME}/vip_callback.sh
    on_stop: ${PATRONI_HOME}/vip_callback.sh
    on_role_change: ${PATRONI_HOME}/vip_callback.sh
  parameters:
    unix_socket_directories: '${PGCONF_UNIX_SOCKET_DIRECTORIES}'

tags:
  nofailover: ${tag_nofailover}
  noloadbalance: ${tag_noloadbalance}
  clonefrom: ${tag_clonefrom}
  nosync: ${tag_nosync}
EOF
  chown "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PATRONI_HOME"
  chmod 0755 "$PATRONI_HOME"
  chown "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PATRONI_HOME/patroni.yml"
  chmod 0600 "$PATRONI_HOME/patroni.yml"
}

configure_pg_probackup() {
  log "configure pg_probackup cron"
  mkdir -p "$PG_PROBACKUP_BACKUP_DIR" /var/log/pg_probackup
  chown -R "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PG_PROBACKUP_BACKUP_DIR" /var/log/pg_probackup

  mkdir -p "$(dirname "$PG_PROBACKUP_JOB_SCRIPT")"
  cat >"$PG_PROBACKUP_JOB_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PGHOME=${PG_PREFIX}
export PGDATA=${PG_DATA}
export PGPORT=${POSTGRES_PORT}
export PGDATABASE=${PGDATABASE}
export PGUSER=${PG_PROBACKUP_BACKUP_USER}
export PGHOST=/var/run/postgresql
export PATH=${PG_PREFIX}/bin:${PATRONI_VENV}/bin:${PATRONI_BIN_DIR}:${ETCD_BIN_DIR}:$(dirname "$PG_PROBACKUP_BINARY"):\$PATH
export LD_LIBRARY_PATH=${PG_PREFIX}/lib:\${LD_LIBRARY_PATH:-}

LOG_DIR=/var/log/pg_probackup
BACKUP_DIR=${PG_PROBACKUP_BACKUP_DIR}
INSTANCE=${PG_PROBACKUP_INSTANCE}
FULL_DAY=${PG_PROBACKUP_FULL_BACKUP_DAY}
INCREMENTAL_MODE=${PG_PROBACKUP_INCREMENTAL_MODE}
REQUESTED_MODE="\${1:-}"
BACKUP_USER=${PG_PROBACKUP_BACKUP_USER}
PG_PROBACKUP_BIN=${PG_PROBACKUP_BINARY}
BACKUP_HOST=${PG_PROBACKUP_BACKUP_HOST}
MEMBER_NAME=${MY_POSTGRESQL_NAME}

mkdir -p "\$LOG_DIR"
exec >>"\$LOG_DIR/pg_probackup-\$(date +%F).log" 2>&1

echo "[\$(date '+%F %T')] pg_probackup job start on \$(hostname)"
IS_LEADER=false
if ${PATRONICTL_BIN} -c ${PATRONI_HOME}/patroni.yml list 2>/dev/null | awk -v name="\$MEMBER_NAME" '\$1 == "|" && \$2 == name && \$6 == "Leader" {found=1} END {exit found ? 0 : 1}'; then
  IS_LEADER=true
fi
case "\$BACKUP_HOST" in
  full) ;;
  leader)
    [[ "\$IS_LEADER" == "true" ]] || { echo "[\$(date '+%F %T')] current node is not Patroni leader, skip backup"; exit 0; }
    ;;
  standby)
    [[ "\$IS_LEADER" != "true" ]] || { echo "[\$(date '+%F %T')] current node is Patroni leader, skip standby backup"; exit 0; }
    ;;
  *)
    [[ "\$BACKUP_HOST" == "\$MEMBER_NAME" ]] || { echo "[\$(date '+%F %T')] current node is not selected backup node \$BACKUP_HOST, skip backup"; exit 0; }
    ;;
esac

if [[ "\$REQUESTED_MODE" == "FULL" ]]; then
  BACKUP_MODE=FULL
elif [[ "\$(date +%w)" == "\$FULL_DAY" ]]; then
  BACKUP_MODE=FULL
else
  BACKUP_MODE=\$INCREMENTAL_MODE
fi

if ! "\$PG_PROBACKUP_BIN" show -B "\$BACKUP_DIR" --instance "\$INSTANCE" 2>/dev/null | grep -Eq '^[[:space:]]+[A-Z0-9]+[[:space:]]+(FULL|PAGE|DELTA|PTRACK)[[:space:]]'; then
  echo "[\$(date '+%F %T')] no valid previous backup found, switch to FULL backup"
  BACKUP_MODE=FULL
fi

echo "[\$(date '+%F %T')] run \$BACKUP_MODE backup"
"\$PG_PROBACKUP_BIN" backup -B "\$BACKUP_DIR" --instance "\$INSTANCE" -b "\$BACKUP_MODE" -U "\$BACKUP_USER" -d ${PGDATABASE} --stream --delete-expired --delete-wal
"\$PG_PROBACKUP_BIN" delete -B "\$BACKUP_DIR" --instance "\$INSTANCE" --delete-expired --delete-wal
echo "[\$(date '+%F %T')] pg_probackup job finished"
EOF
  chmod 0755 "$PG_PROBACKUP_JOB_SCRIPT"
  chown root:root "$PG_PROBACKUP_JOB_SCRIPT"

  local current_crontab backup_cron_line
  backup_cron_line="${PG_PROBACKUP_CRON_MINUTE} ${PG_PROBACKUP_CRON_HOUR} * * * ${PG_PROBACKUP_JOB_SCRIPT}"
  current_crontab="$(crontab -u "$POSTGRES_OS_USER" -l 2>/dev/null | grep -Fv "$PG_PROBACKUP_JOB_SCRIPT" || true)"
  if pg_probackup_cron_enabled_for_node "$MY_POSTGRESQL_NAME"; then
    {
      [[ -z "$current_crontab" ]] || printf '%s\n' "$current_crontab"
      printf '%s\n' "$backup_cron_line"
    } | crontab -u "$POSTGRES_OS_USER" -
  elif [[ -n "$current_crontab" ]]; then
    printf '%s\n' "$current_crontab" | crontab -u "$POSTGRES_OS_USER" -
  else
    crontab -u "$POSTGRES_OS_USER" -r 2>/dev/null || true
  fi
  rm -f /etc/cron.d/pg-probackup-ha
  systemctl enable --now crond >/dev/null 2>&1 || true
}

initialize_pg_probackup_instance() {
  log "initialize pg_probackup instance $PG_PROBACKUP_INSTANCE"
  [[ -x "$PG_PROBACKUP_BINARY" ]] || die "pg_probackup binary not found: $PG_PROBACKUP_BINARY"
  [[ -d "$PG_DATA" ]] || die "PostgreSQL data directory is not initialized: $PG_DATA"

  mkdir -p "$PG_PROBACKUP_BACKUP_DIR" /var/log/pg_probackup
  chown -R "$POSTGRES_OS_USER:$POSTGRES_OS_USER" "$PG_PROBACKUP_BACKUP_DIR" /var/log/pg_probackup

  if [[ ! -d "$PG_PROBACKUP_BACKUP_DIR/backups" ]]; then
    su - "$POSTGRES_OS_USER" -c "$PG_PROBACKUP_BINARY init -B '$PG_PROBACKUP_BACKUP_DIR'"
  fi
  if [[ ! -f "$PG_PROBACKUP_BACKUP_DIR/backups/${PG_PROBACKUP_INSTANCE}/pg_probackup.conf" ]]; then
    su - "$POSTGRES_OS_USER" -c "$PG_PROBACKUP_BINARY add-instance -B '$PG_PROBACKUP_BACKUP_DIR' --instance '$PG_PROBACKUP_INSTANCE' -D '$PG_DATA'"
  fi
  su - "$POSTGRES_OS_USER" -c "$PG_PROBACKUP_BINARY set-config -B '$PG_PROBACKUP_BACKUP_DIR' --instance '$PG_PROBACKUP_INSTANCE' --retention-redundancy='$PG_PROBACKUP_RETENTION_REDUNDANCY' --retention-window='$PG_PROBACKUP_RETENTION_WINDOW'"
  su - "$POSTGRES_OS_USER" -c "$PG_PROBACKUP_BINARY show -B '$PG_PROBACKUP_BACKUP_DIR' --instance '$PG_PROBACKUP_INSTANCE'"
}

write_systemd() {
  cat >/etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA manager
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${POSTGRES_OS_USER}
Group=${POSTGRES_OS_USER}
Environment=PATH=${PG_PREFIX}/bin:${PATRONI_VENV}/bin:${PATRONI_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=${PATRONI_BIN} ${PATRONI_HOME}/patroni.yml
Restart=on-failure
RestartSec=5
RuntimeDirectory=postgresql
RuntimeDirectoryMode=0775
TimeoutStopSec=600
LimitNOFILE=1024000
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
}

configure_profile() {
  local pg_home
  pg_home="$(getent passwd "$POSTGRES_OS_USER" | cut -d: -f6)"
  [[ -n "$pg_home" ]] || pg_home="/home/${POSTGRES_OS_USER}"
  cat >/etc/profile.d/postgresql17.sh <<EOF
if [ "\$(id -un 2>/dev/null)" = "${POSTGRES_OS_USER}" ] && [ -f ${pg_home}/.pgev ]; then
  source ${pg_home}/.pgev
fi
EOF
}

start_services() {
  systemctl daemon-reload
  if is_true "$IS_ETCD_NODE"; then systemctl enable etcd; fi
  if is_true "$IS_POSTGRESQL_NODE"; then systemctl enable patroni; fi
  if [[ "${SKIP_SERVICE_START:-0}" == "1" ]]; then
    log "service start skipped by SKIP_SERVICE_START=1"
    return 0
  fi
  if is_true "$IS_ETCD_NODE"; then
    systemctl start --no-block etcd
    sleep 3
  fi
  if is_true "$IS_POSTGRESQL_NODE"; then systemctl start patroni; fi
}

main() {
  if is_true "$IS_POSTGRESQL_NODE"; then require_database_passwords; fi
  install_prereqs
  configure_os
  configure_firewall
  create_users_dirs
  reconcile_node_roles
  if is_true "$IS_ETCD_NODE"; then
    install_etcd
    write_etcd_config
  fi
  if is_true "$IS_POSTGRESQL_NODE"; then
    write_postgres_env
    install_postgres
    install_pg_cron
    install_pg_repack
    install_pg_probackup
    install_patroni
    write_vip_callback
    write_patroni_config
    configure_pg_probackup
    write_systemd
    configure_profile
  fi
  start_services
  if is_true "$IS_POSTGRESQL_NODE" && [[ "${SKIP_SERVICE_START:-0}" != "1" ]]; then
    initialize_pg_probackup_instance
  fi
  log "node $MY_NAME ($MY_IP) installed"
}

if [[ "${1:-}" == "--init-pg-probackup" ]]; then
  is_true "$IS_POSTGRESQL_NODE" || die "current node $MY_IP has no PostgreSQL role"
  initialize_pg_probackup_instance
  exit 0
fi

main "$@"

#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config
LOCAL_IP="$(current_ip)"

[[ "$(id -u)" -eq 0 ]] || die "run as root"

ssh_base=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
scp_base=(scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
if [[ -n "${SSH_KEY:-}" ]]; then
  ssh_base+=(-i "$SSH_KEY")
  scp_base+=(-i "$SSH_KEY")
fi

if [[ -n "${SSH_PASSWORD:-}" && -z "${SSH_KEY:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    log "sshpass 未安装，使用 yum/dnf 安装以支持密码方式分发项目"
    pkg_install sshpass
  fi
  ssh_base=(sshpass -p "$SSH_PASSWORD" "${ssh_base[@]}")
  scp_base=(sshpass -p "$SSH_PASSWORD" "${scp_base[@]}")
fi

run_remote() {
  local ip="$1"
  shift
  "${ssh_base[@]}" "${SSH_USER}@${ip}" "$@"
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
  run_remote "$ip" "mkdir -p '$INSTALL_ROOT'"
  tar -C "$PROJECT_DIR" -czf - . | "${ssh_base[@]}" "${SSH_USER}@${ip}" "tar -C '$INSTALL_ROOT' -xzf -"
}

main() {
  local ip remote_project_dir

  for ip in $(all_node_ips); do
    copy_project "$ip"
  done

  for ip in $(all_node_ips); do
    remote_project_dir="$(node_project_dir "$ip")"
    log "install node $ip"
    run_remote "$ip" "cd '$remote_project_dir' && SKIP_SERVICE_START=1 bash scripts/node-install.sh"
  done

  for ip in $(all_node_ips); do
    log "enable systemd units on $ip"
    run_remote "$ip" "systemctl daemon-reload && systemctl enable etcd.service patroni.service"
  done

  for ip in $(all_node_ips); do
    log "start etcd on $ip"
    run_remote "$ip" "systemctl reset-failed etcd.service || true; systemctl start --no-block etcd.service"
  done

  log "wait for etcd health"
  run_remote "$(primary_ip)" "for i in {1..60}; do env -u ETCDCTL_ENDPOINTS etcdctl --endpoints=$(etcd_client_endpoints) endpoint health && exit 0; sleep 2; done; systemctl status etcd.service --no-pager; exit 1"

  for ip in $(all_node_ips); do
    log "start patroni on $ip"
    run_remote "$ip" "systemctl reset-failed patroni.service || true; systemctl start patroni.service"
  done

  log "wait for Patroni cluster"
  run_remote "$(primary_ip)" "for i in {1..90}; do patronictl -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'Leader' && patronictl -c '$PATRONI_HOME/patroni.yml' list 2>/dev/null | grep -q 'streaming' && exit 0; sleep 2; done; journalctl -u patroni.service -n 120 --no-pager; exit 1"

  for ip in $(all_node_ips); do
    log "verify systemd services on $ip"
    run_remote "$ip" "systemctl is-enabled etcd.service patroni.service && systemctl is-active etcd.service patroni.service"
  done

  log "cluster deployment commands finished"
  log "check with: su - postgres -c 'patronictl -c /etc/patroni/patroni.yml list'"
}

main "$@"

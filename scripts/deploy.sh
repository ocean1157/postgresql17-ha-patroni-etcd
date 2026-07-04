#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config

[[ "$(id -u)" -eq 0 ]] || die "run as root"

ssh_base=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
scp_base=(scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY:-}" ]]; then
  ssh_base+=(-i "$SSH_KEY")
  scp_base+=(-i "$SSH_KEY")
fi

if [[ -n "${SSH_PASSWORD:-}" && -z "${SSH_KEY:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    log "sshpass not found; trying to install it for password-based bootstrap"
    pkg_install sshpass
  fi
  ssh_base=(sshpass -p "$SSH_PASSWORD" "${ssh_base[@]}")
  scp_base=(sshpass -p "$SSH_PASSWORD" "${scp_base[@]}")
fi

run_remote() {
  local ip="$1"
  "${ssh_base[@]}" "${SSH_USER}@${ip}" "$@"
}

copy_project() {
  local ip="$1"
  log "copy project to $ip:$INSTALL_ROOT"
  run_remote "$ip" "mkdir -p '$INSTALL_ROOT'"
  tar -C "$PROJECT_DIR" -czf - . | "${ssh_base[@]}" "${SSH_USER}@${ip}" "tar -C '$INSTALL_ROOT' -xzf -"
}

main() {
  local ip
  for ip in $(all_node_ips); do
    copy_project "$ip"
  done

  for ip in $(all_node_ips); do
    log "install node $ip"
    run_remote "$ip" "cd '$INSTALL_ROOT' && SKIP_SERVICE_START=1 bash scripts/node-install.sh"
  done

  for ip in $(all_node_ips); do
    log "start etcd on $ip"
    run_remote "$ip" "systemctl daemon-reload && systemctl enable etcd patroni && systemctl start --no-block etcd"
  done

  log "wait for etcd health"
  run_remote "$(primary_ip)" "for i in {1..60}; do etcdctl --endpoints=$(etcd_client_endpoints) endpoint health && exit 0; sleep 2; done; exit 1"

  for ip in $(all_node_ips); do
    log "start patroni on $ip"
    run_remote "$ip" "systemctl start patroni"
  done

  log "cluster deployment commands finished"
  log "check with: su - postgres -c 'patronictl -c /etc/patroni/patroni.yml list'"
}

main "$@"

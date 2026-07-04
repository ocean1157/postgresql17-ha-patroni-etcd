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
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
}

node_name_by_ip() {
  local ip="$1" item name node_ip
  for item in "${CLUSTER_NODES[@]}"; do
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
  for item in "${CLUSTER_NODES[@]}"; do
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
  local item
  for item in "${CLUSTER_NODES[@]}"; do
    printf '%s\n' "${item#*:}"
  done
}

etcd_initial_cluster() {
  local item name node_ip parts=()
  for item in "${CLUSTER_NODES[@]}"; do
    name="${item%%:*}"
    node_ip="${item#*:}"
    parts+=("${name}=http://${node_ip}:${ETCD_PEER_PORT}")
  done
  local IFS=,
  printf '%s\n' "${parts[*]}"
}

etcd_hosts_yaml() {
  local item node_ip
  for item in "${CLUSTER_NODES[@]}"; do
    node_ip="${item#*:}"
    printf '    - %s:%s\n' "$node_ip" "$ETCD_CLIENT_PORT"
  done
}

etcd_client_endpoints() {
  local item node_ip parts=()
  for item in "${CLUSTER_NODES[@]}"; do
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
  local ip
  for item in "${CLUSTER_NODES[@]}"; do
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

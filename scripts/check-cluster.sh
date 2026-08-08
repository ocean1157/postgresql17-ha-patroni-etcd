#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config

MODE=basic
PGBENCH_SECONDS=100
PGBENCH_DATABASE="pgbench_acceptance_$$"
PGBENCH_CREATED=false
ENDPOINTS="$(etcd_client_endpoints)"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/check-cluster.sh
  bash scripts/check-cluster.sh --full

The default mode performs read-only health, connection and firewall checks.
--full additionally runs pgbench for 100 seconds, a Patroni switchover, and a
rolling Patroni service restart (replicas first, leader last).
EOF
}

while (($#)); do
  case "$1" in
    --full) MODE=full ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown check-cluster option: $1" ;;
  esac
  shift
done

ssh_base=(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ -n "$SSH_KEY" ]]; then
  ssh_base+=(-i "$SSH_KEY")
elif [[ -n "$SSH_PASSWORD" ]]; then
  command -v sshpass >/dev/null 2>&1 || die "sshpass is required for password-based remote checks"
  ssh_base=(sshpass -p "$SSH_PASSWORD" "${ssh_base[@]}")
else
  ssh_base+=(-o BatchMode=yes)
fi

run_remote() {
  local ip="$1"
  shift
  "${ssh_base[@]}" "${SSH_USER}@${ip}" "$@"
}

psql_primary() {
  local leader_ip
  read -r _ leader_ip <<<"$(leader_row)"
  [[ -n "$leader_ip" ]] || die "cannot determine current Patroni Leader IP"
  PGPASSWORD="$POSTGRES_SUPERPASS" "$PG_PREFIX/bin/psql" -X -v ON_ERROR_STOP=1 \
    -h "$leader_ip" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" -d "$PGDATABASE" "$@"
}

leader_row() {
  "$PATRONICTL_BIN" -c "$PATRONI_HOME/patroni.yml" list 2>/dev/null |
    awk '$1 == "|" && $6 == "Leader" {print $2, $4; exit}'
}

replica_rows() {
  "$PATRONICTL_BIN" -c "$PATRONI_HOME/patroni.yml" list 2>/dev/null |
    awk '$1 == "|" && $6 == "Replica" && $8 == "streaming" {print $2, $4}'
}

wait_for_cluster() {
  local expected_replicas=$(( ${#PG_NODES[@]} - 1 )) output leaders replicas attempt
  for attempt in $(seq 1 120); do
    output="$($PATRONICTL_BIN -c "$PATRONI_HOME/patroni.yml" list 2>/dev/null || true)"
    leaders="$(awk '$1 == "|" && $6 == "Leader" {count++} END {print count+0}' <<<"$output")"
    replicas="$(awk '$1 == "|" && $6 == "Replica" && $8 == "streaming" {count++} END {print count+0}' <<<"$output")"
    if [[ "$leaders" -eq 1 && "$replicas" -eq "$expected_replicas" ]]; then
      return 0
    fi
    sleep 2
  done
  "$PATRONICTL_BIN" -c "$PATRONI_HOME/patroni.yml" list || true
  die "Patroni cluster did not recover to one Leader and $expected_replicas streaming Replica(s)"
}

check_firewall_node() {
  local ip="$1" port
  local -a ports=("$POSTGRES_PORT" "$PATRONI_PORT" "$ETCD_CLIENT_PORT" "$ETCD_PEER_PORT")
  for port in "${ports[@]}"; do
    run_remote "$ip" "firewall-cmd --quiet --query-port='${port}/tcp' && firewall-cmd --quiet --permanent --query-port='${port}/tcp'" \
      || die "firewall port ${port}/tcp is not active and permanent on $ip"
    printf 'OK %-15s %s/tcp active+permanent\n' "$ip" "$port"
  done
}

cleanup_pgbench() {
  if [[ "$PGBENCH_CREATED" == true ]]; then
    local leader_ip leader_info
    leader_info="$(leader_row || true)"
    leader_ip="${leader_info#* }"
    [[ -n "$leader_info" && -n "$leader_ip" ]] || return 0
    PGPASSWORD="$POSTGRES_SUPERPASS" "$PG_PREFIX/bin/dropdb" --if-exists \
      -h "$leader_ip" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" "$PGBENCH_DATABASE" >/dev/null 2>&1 || true
  fi
}
trap cleanup_pgbench EXIT

echo "== etcd endpoint health =="
env -u ETCDCTL_ENDPOINTS -u ETCDCTL_API "$ETCD_BIN_DIR/etcdctl" --endpoints="$ENDPOINTS" endpoint health

echo
echo "== Patroni cluster health =="
wait_for_cluster
"$PATRONICTL_BIN" -c "$PATRONI_HOME/patroni.yml" list

echo
echo "== PostgreSQL connection tests =="
for item in "${PG_NODES[@]}"; do
  node_name="${item%%:*}"
  node_ip="${item#*:}"
  PGPASSWORD="$POSTGRES_SUPERPASS" "$PG_PREFIX/bin/psql" -XAt -v ON_ERROR_STOP=1 \
    -h "$node_ip" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" -d "$PGDATABASE" \
    -c "select '$node_name', inet_server_addr(), pg_is_in_recovery();"
done

echo
echo "== firewalld active and permanent ports =="
while IFS= read -r node_ip; do
  check_firewall_node "$node_ip"
done < <(all_node_ips)

echo
echo "== replication status =="
psql_primary -c "select application_name, client_addr, state, sync_state from pg_stat_replication order by application_name;"

if [[ "$MODE" != full ]]; then
  echo
  echo "Basic checks passed. Run 'bash scripts/check-cluster.sh --full' for pgbench, switchover and rolling restart tests."
  exit 0
fi

echo
echo "== pgbench initialize and ${PGBENCH_SECONDS}s workload =="
read -r _ pgbench_leader_ip <<<"$(leader_row)"
PGPASSWORD="$POSTGRES_SUPERPASS" "$PG_PREFIX/bin/createdb" \
  -h "$pgbench_leader_ip" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" "$PGBENCH_DATABASE"
PGBENCH_CREATED=true
PGPASSWORD="$POSTGRES_SUPERPASS" "$PG_PREFIX/bin/pgbench" -i \
  -h "$pgbench_leader_ip" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" "$PGBENCH_DATABASE"
PGPASSWORD="$POSTGRES_SUPERPASS" "$PG_PREFIX/bin/pgbench" -T "$PGBENCH_SECONDS" \
  -h "$pgbench_leader_ip" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" "$PGBENCH_DATABASE"
cleanup_pgbench
PGBENCH_CREATED=false

echo
echo "== Patroni switchover =="
read -r old_leader old_leader_ip <<<"$(leader_row)"
read -r candidate candidate_ip <<<"$(replica_rows | head -n1)"
[[ -n "${old_leader:-}" && -n "${candidate:-}" ]] || die "switchover requires a Leader and a streaming Replica"
"$PATRONICTL_BIN" -c "$PATRONI_HOME/patroni.yml" switchover "$SCOPE" \
  --leader "$old_leader" --candidate "$candidate" --force
wait_for_cluster
read -r new_leader new_leader_ip <<<"$(leader_row)"
[[ "$new_leader" == "$candidate" ]] || die "switchover failed: expected leader=$candidate actual=$new_leader"
echo "OK leader changed: $old_leader -> $new_leader"

echo
echo "== rolling Patroni restart: replicas first, leader last =="
while read -r member member_ip; do
  [[ -n "$member" ]] || continue
  echo "restart Replica $member ($member_ip)"
  run_remote "$member_ip" "systemctl restart patroni.service"
  wait_for_cluster
done < <(replica_rows)

read -r current_leader current_leader_ip <<<"$(leader_row)"
echo "restart Leader $current_leader ($current_leader_ip)"
run_remote "$current_leader_ip" "systemctl restart patroni.service"
wait_for_cluster

echo
"$PATRONICTL_BIN" -c "$PATRONI_HOME/patroni.yml" list
psql_primary -c "select now(), inet_server_addr(), pg_is_in_recovery();"
echo "Full acceptance checks passed."

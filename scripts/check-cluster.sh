#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config

ENDPOINTS=""
for ip in $(all_node_ips); do
  ENDPOINTS="${ENDPOINTS},http://${ip}:${ETCD_CLIENT_PORT}"
done
ENDPOINTS="${ENDPOINTS#,}"

echo "== etcd endpoint health =="
ETCDCTL_API=3 etcdctl --endpoints="$ENDPOINTS" endpoint health || true

echo
echo "== patroni cluster =="
patronictl -c "$PATRONI_HOME/patroni.yml" list || true

echo
echo "== postgres version =="
PGPASSWORD="$POSTGRES_SUPERPASS" psql -h "$(primary_ip)" -p "$POSTGRES_PORT" -U "$POSTGRES_SUPERUSER" -d postgres -c "select version();" || true

#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config

mkdir -p "$PROJECT_DIR/packages/wheels"

ARCH="$(detect_arch)"
PG_TGZ="$PROJECT_DIR/packages/postgresql-${POSTGRES_VERSION}.tar.gz"
ETCD_TGZ="$PROJECT_DIR/packages/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"

download() {
  local url="$1" output="$2"
  if [[ -f "$output" ]]; then
    log "exists: $output"
    return 0
  fi
  log "download: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  else
    die "curl or wget is required"
  fi
}

download "https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}/postgresql-${POSTGRES_VERSION}.tar.gz" "$PG_TGZ"
download "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz" "$ETCD_TGZ"

log "packages are ready under $PROJECT_DIR/packages"

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
PG_PROBACKUP_TGZ="$PROJECT_DIR/packages/pg_probackup-${PG_PROBACKUP_VERSION}.tar.gz"
RPM_DIR="$(rpm_package_dir)"

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
download "https://github.com/postgrespro/pg_probackup/archive/refs/tags/${PG_PROBACKUP_VERSION}.tar.gz" "$PG_PROBACKUP_TGZ"

download_python_wheels() {
  log "download Python wheels to $PROJECT_DIR/packages/wheels"
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip download \
      --retries 10 \
      --timeout 120 \
      --dest "$PROJECT_DIR/packages/wheels" \
      "pip<22" \
      wheel \
      "patroni[etcd3]==${PATRONI_VERSION}" \
      "psycopg2-binary==2.9.5" \
      "ydiff==1.4.2" \
      cdiff
  else
    log "python3 not found; skip Python wheels download"
  fi
}

download_rpms() {
  if ! command -v rpm >/dev/null 2>&1; then
    log "rpm command not found; skip RPM dependency download"
    return 0
  fi

  mkdir -p "$RPM_DIR"
  mapfile -t prereq_pkgs < <(rpm_prereq_packages)
  log "download RPM dependencies to $RPM_DIR"

  if command -v dnf >/dev/null 2>&1; then
    if ! command -v dnf-plugins-core >/dev/null 2>&1; then
      dnf install -y dnf-plugins-core || true
    fi
    if dnf download --help >/dev/null 2>&1; then
      dnf download --resolve --alldeps --destdir "$RPM_DIR" "${prereq_pkgs[@]}"
      return 0
    fi
  fi

  if command -v yumdownloader >/dev/null 2>&1; then
    yumdownloader --resolve --destdir="$RPM_DIR" "${prereq_pkgs[@]}"
    return 0
  fi

  if command -v yum >/dev/null 2>&1; then
    log "yumdownloader not found; install yum-utils first"
    yum install -y yum-utils
    yumdownloader --resolve --destdir="$RPM_DIR" "${prereq_pkgs[@]}"
    return 0
  fi

  log "no supported RPM downloader found; skip RPM dependency download"
}

download_python_wheels
download_rpms

log "packages are ready under $PROJECT_DIR/packages"

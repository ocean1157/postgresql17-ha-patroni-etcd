#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config

ARCH="$(detect_arch)"
PACKAGE_DIR="$PROJECT_DIR/packages"
RPM_DIR="$PACKAGE_DIR/rpm"
PYTHON_DIR="$PACKAGE_DIR/python"
mkdir -p "$RPM_DIR" "$PYTHON_DIR"

download() {
  local url="$1" output="$2"
  [[ ! -f "$output" ]] || { log "already exists: $output"; return; }
  log "download: $url"
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 5 "$url" -o "$output.part"
  elif command -v wget >/dev/null 2>&1; then wget -O "$output.part" "$url"
  else die "curl or wget is required"; fi
  mv "$output.part" "$output"
}

prepare_repo_options() {
  DOWNLOAD_REPO_OPTS=()
  [[ -n "$YUM_SOURCE" ]] || return
  if [[ "$YUM_SOURCE" == *.repo || "$YUM_SOURCE" == *.repo\?* ]]; then
    local repo_file="$PACKAGE_DIR/.download-source.repo"
    if is_url "$YUM_SOURCE"; then download "$YUM_SOURCE" "$repo_file"; else cp -f "$YUM_SOURCE" "$repo_file"; fi
    DOWNLOAD_REPO_OPTS=(--setopt="reposdir=$PACKAGE_DIR")
  elif is_url "$YUM_SOURCE" || [[ "$YUM_SOURCE" == /* ]]; then
    DOWNLOAD_REPO_OPTS=(--repofrompath="cluster-source,$YUM_SOURCE" --enablerepo=cluster-source)
  else
    local id ids
    IFS=',' read -ra ids <<< "$YUM_SOURCE"
    for id in "${ids[@]}"; do DOWNLOAD_REPO_OPTS+=(--enablerepo="$(trim "$id")"); done
  fi
  if [[ -n "$YUM_DISABLE_REPOS" ]]; then
    local id ids
    IFS=',' read -ra ids <<< "$YUM_DISABLE_REPOS"
    for id in "${ids[@]}"; do DOWNLOAD_REPO_OPTS+=(--disablerepo="$(trim "$id")"); done
  fi
}

download_rpms() {
  local -a pkgs
  # shellcheck disable=SC2207
  pkgs=($(rpm_prereq_packages))
  prepare_repo_options
  if command -v dnf >/dev/null 2>&1; then
    dnf "${DOWNLOAD_REPO_OPTS[@]}" install -y dnf-plugins-core
    dnf "${DOWNLOAD_REPO_OPTS[@]}" download --resolve --alldeps --destdir "$RPM_DIR" "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum "${DOWNLOAD_REPO_OPTS[@]}" install -y yum-utils
    # repotrack recursively downloads dependencies, including dependencies already installed on this preparation host.
    repotrack "${DOWNLOAD_REPO_OPTS[@]}" -a "$(uname -m)" -p "$RPM_DIR" "${pkgs[@]}"
  else
    die "RPM packages must be prepared on an online host with yum/dnf and the same OS major version, architecture, and Python version as the target nodes"
  fi
}

download_python() {
  local -a source_args=()
  pip_source_args
  source_args=("${PIP_SOURCE_ARGS[@]}")
  python3 -m pip download --dest "$PYTHON_DIR" "${source_args[@]}" \
    "pip<22" setuptools wheel virtualenv "patroni[etcd3]==${PATRONI_VERSION}" \
    "psycopg2-binary==2.9.5" "ydiff==1.4.2" cdiff
}

download_sources() {
  download "https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}/postgresql-${POSTGRES_VERSION}.tar.gz" "$PACKAGE_DIR/postgresql-${POSTGRES_VERSION}.tar.gz"
  download "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz" "$PACKAGE_DIR/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
  download "https://github.com/postgrespro/pg_probackup/archive/refs/tags/${PG_PROBACKUP_VERSION}.tar.gz" "$PACKAGE_DIR/pg_probackup-${PG_PROBACKUP_VERSION}.tar.gz"
  download "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" "$PACKAGE_DIR/pg_cron-${PG_CRON_VERSION}.tar.gz"
}

write_manifest() {
  cat > "$PACKAGE_DIR/OFFLINE-ENVIRONMENT.txt" <<EOF
created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
os=$(source /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-unknown}")
arch=$(uname -m)
python=$(python3 -c 'import platform; print(platform.python_version())')
postgresql=$POSTGRES_VERSION
patroni=$PATRONI_VERSION
EOF
  (cd "$PACKAGE_DIR" && find . -type f ! -name SHA256SUMS ! -name .download-source.repo -print0 | sort -z | xargs -0 sha256sum) > "$PACKAGE_DIR/SHA256SUMS"
}

main() {
  download_sources
  download_rpms
  download_python
  rm -f "$PACKAGE_DIR/.download-source.repo"
  write_manifest
  log "offline packages prepared in $PACKAGE_DIR; package this directory and verify with: sha256sum -c packages/SHA256SUMS"
}
main "$@"

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
DOWNLOAD_REPO_DIR="$PACKAGE_DIR/.download-repos"
declare -a DOWNLOAD_REPO_OPTS=()
mkdir -p "$RPM_DIR" "$PYTHON_DIR"

download() {
  local url="$1" output="$2"
  [[ ! -f "$output" ]] || { log "already exists: $output"; return; }
  log "download: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 "$url" -o "$output.part"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output.part" "$url"
  else
    die "curl or wget is required"
  fi
  mv "$output.part" "$output"
}

count_files() {
  local dir="$1" pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

require_files() {
  local dir="$1" pattern="$2" label="$3" count
  count="$(count_files "$dir" "$pattern")"
  [[ "$count" -gt 0 ]] || die "$label download produced no files in $dir"
  log "$label ready: $count files in $dir"
}

prepare_repo_options() {
  DOWNLOAD_REPO_OPTS=()
  [[ -n "$YUM_SOURCE" ]] || return 0
  if [[ "$YUM_SOURCE" == *.repo || "$YUM_SOURCE" == *.repo\?* ]]; then
    mkdir -p "$DOWNLOAD_REPO_DIR"
    local repo_file="$DOWNLOAD_REPO_DIR/cluster.repo"
    if is_url "$YUM_SOURCE"; then
      download "$YUM_SOURCE" "$repo_file"
    else
      cp -f "$YUM_SOURCE" "$repo_file"
    fi
    DOWNLOAD_REPO_OPTS=(--setopt="reposdir=$DOWNLOAD_REPO_DIR")
  elif is_url "$YUM_SOURCE" || [[ "$YUM_SOURCE" == /* ]]; then
    DOWNLOAD_REPO_OPTS=(--repofrompath="cluster-source,$YUM_SOURCE" --enablerepo=cluster-source)
  else
    local id ids
    IFS=',' read -ra ids <<< "$YUM_SOURCE"
    for id in "${ids[@]}"; do
      DOWNLOAD_REPO_OPTS+=(--enablerepo="$(trim "$id")")
    done
  fi
  if [[ -n "$YUM_DISABLE_REPOS" ]]; then
    local id ids
    IFS=',' read -ra ids <<< "$YUM_DISABLE_REPOS"
    for id in "${ids[@]}"; do
      DOWNLOAD_REPO_OPTS+=(--disablerepo="$(trim "$id")")
    done
  fi
}

run_repo_command() {
  local command_name="$1"
  shift
  if ((${#DOWNLOAD_REPO_OPTS[@]} > 0)); then
    "$command_name" "${DOWNLOAD_REPO_OPTS[@]}" "$@"
  else
    "$command_name" "$@"
  fi
}

download_rpms() {
  local -a pkgs
  # shellcheck disable=SC2207
  pkgs=($(rpm_prereq_packages))
  prepare_repo_options
  log "[2/4] download yum/dnf RPM packages into $RPM_DIR"
  log "RPM root packages: ${pkgs[*]}"

  if command -v dnf >/dev/null 2>&1; then
    if ! dnf download --help >/dev/null 2>&1; then
      log "dnf download plugin missing; installing dnf-plugins-core on this online preparation host"
      run_repo_command dnf install -y dnf-plugins-core
    fi
    run_repo_command dnf download --resolve --alldeps --destdir "$RPM_DIR" "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    log "install yum-utils on this online preparation host for repotrack"
    run_repo_command yum install -y yum-utils
    command -v repotrack >/dev/null 2>&1 || die "repotrack is required but was not found after installing yum-utils"
    run_repo_command repotrack -a "$(uname -m)" -p "$RPM_DIR" "${pkgs[@]}"
  else
    die "RPM packages must be prepared on an online host with yum/dnf and the same OS major version, architecture, and Python version as the target nodes"
  fi

  require_files "$RPM_DIR" "*.rpm" "RPM packages"
}

download_python() {
  local -a source_args=()
  log "[3/4] download pip packages into $PYTHON_DIR"
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -m pip --version >/dev/null 2>&1; then
    log "python3 or python3-pip missing; installing them on this online preparation host"
    prepare_repo_options
    if command -v dnf >/dev/null 2>&1; then
      run_repo_command dnf install -y python3 python3-pip
    elif command -v yum >/dev/null 2>&1; then
      run_repo_command yum install -y python3 python3-pip
    else
      die "python3 and python3-pip are required to download Python packages"
    fi
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  python3 -m pip --version >/dev/null 2>&1 || die "python3-pip is required"
  pip_source_args
  if [[ -n "${PIP_SOURCE:-}" ]]; then
    source_args=("${PIP_SOURCE_ARGS[@]}")
    log "upgrade local pip tooling on this preparation host"
    python3 -m pip install --upgrade --retries 10 --timeout 120 "${source_args[@]}" "pip<22" setuptools wheel
    rm -f "$PYTHON_DIR"/psycopg2-binary-*.tar.gz
    python3 -m pip download --dest "$PYTHON_DIR" --retries 10 --timeout 120 "${source_args[@]}" \
      --only-binary psycopg2-binary \
      "pip<22" setuptools wheel virtualenv "patroni[etcd3]==${PATRONI_VERSION}" \
      "psycopg2-binary==2.9.5" "ydiff==1.4.2" cdiff
  else
    log "upgrade local pip tooling on this preparation host"
    python3 -m pip install --upgrade --retries 10 --timeout 120 "pip<22" setuptools wheel
    rm -f "$PYTHON_DIR"/psycopg2-binary-*.tar.gz
    python3 -m pip download --dest "$PYTHON_DIR" --retries 10 --timeout 120 \
      --only-binary psycopg2-binary \
      "pip<22" setuptools wheel virtualenv "patroni[etcd3]==${PATRONI_VERSION}" \
      "psycopg2-binary==2.9.5" "ydiff==1.4.2" cdiff
  fi
  require_files "$PYTHON_DIR" "*" "Python packages"
}

download_sources() {
  log "[1/4] download PostgreSQL/etcd/pg_probackup/pg_cron packages into $PACKAGE_DIR"
  download "https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}/postgresql-${POSTGRES_VERSION}.tar.gz" "$PACKAGE_DIR/postgresql-${POSTGRES_VERSION}.tar.gz"
  download "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz" "$PACKAGE_DIR/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
  download "https://github.com/postgrespro/pg_probackup/archive/refs/tags/${PG_PROBACKUP_VERSION}.tar.gz" "$PACKAGE_DIR/pg_probackup-${PG_PROBACKUP_VERSION}.tar.gz"
  download "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" "$PACKAGE_DIR/pg_cron-${PG_CRON_VERSION}.tar.gz"
}

write_manifest() {
  log "[4/4] write checksum and environment manifest"
  cat > "$PACKAGE_DIR/OFFLINE-ENVIRONMENT.txt" <<EOF
created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
os=$(source /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-unknown}")
arch=$(uname -m)
python=$(python3 -c 'import platform; print(platform.python_version())')
postgresql=$POSTGRES_VERSION
patroni=$PATRONI_VERSION
rpm_files=$(count_files "$RPM_DIR" "*.rpm")
python_files=$(count_files "$PYTHON_DIR" "*")
EOF
  (cd "$PACKAGE_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) > "$PACKAGE_DIR/SHA256SUMS"
}

main() {
  download_sources
  download_rpms
  download_python
  rm -rf "$DOWNLOAD_REPO_DIR"
  write_manifest
  log "offline packages prepared in $PACKAGE_DIR; package this directory and verify with: cd packages && sha256sum -c SHA256SUMS"
}
main "$@"

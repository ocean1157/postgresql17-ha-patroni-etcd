#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$PROJECT_DIR/scripts/lib.sh"
load_config

ARCH="$(detect_arch)"
require_supported_rpm_os
OS_COMPAT="$(current_os_compat_id)"
RPM_ARCH="$(rpm_arch)"
PACKAGE_DIR="$PROJECT_DIR/packages"
RPM_DIR="$PACKAGE_DIR/rpm/$OS_COMPAT/$RPM_ARCH"
PYTHON_ROOT_DIR="$PACKAGE_DIR/python"
PYTHON_DIR="$PYTHON_ROOT_DIR"
DOWNLOAD_REPO_DIR="$PACKAGE_DIR/.download-repos"
declare -a DOWNLOAD_REPO_OPTS=()
mkdir -p "$RPM_DIR" "$PYTHON_ROOT_DIR"

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
  if [[ -z "$YUM_SOURCE" ]]; then
    :
  elif [[ "$YUM_SOURCE" == *.repo || "$YUM_SOURCE" == *.repo\?* ]]; then
    mkdir -p "$DOWNLOAD_REPO_DIR"
    local repo_file="$DOWNLOAD_REPO_DIR/cluster.repo"
    if is_url "$YUM_SOURCE"; then
      download "$YUM_SOURCE" "$repo_file"
    else
      cp -f "$YUM_SOURCE" "$repo_file"
    fi
    DOWNLOAD_REPO_OPTS=(--setopt="reposdir=$DOWNLOAD_REPO_DIR")
  elif is_url "$YUM_SOURCE" || [[ "$YUM_SOURCE" == /* ]]; then
    mkdir -p "$DOWNLOAD_REPO_DIR"
    local baseurl="$YUM_SOURCE"
    [[ "$YUM_SOURCE" == /* ]] && baseurl="file://$YUM_SOURCE"
    cat > "$DOWNLOAD_REPO_DIR/cluster-source.repo" <<EOF
[cluster-source]
name=cluster-source
baseurl=$baseurl
enabled=1
gpgcheck=0
EOF
    DOWNLOAD_REPO_OPTS=(--setopt="reposdir=$DOWNLOAD_REPO_DIR" --enablerepo=cluster-source)
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

ensure_createrepo() {
  if command -v createrepo_c >/dev/null 2>&1 || command -v createrepo >/dev/null 2>&1; then
    return 0
  fi
  log "createrepo not found; installing it on this online preparation host"
  local manager
  manager="$(rpm_package_manager)" || die "yum or dnf is required to install createrepo"
  if [[ "$manager" == "dnf" ]]; then
    run_repo_command dnf install -y createrepo_c || run_repo_command dnf install -y createrepo
  elif [[ "$manager" == "yum" ]]; then
    run_repo_command yum install -y createrepo || run_repo_command yum install -y createrepo_c
  else
    die "createrepo or createrepo_c is required to build packages/rpm metadata"
  fi
}

write_rpm_repo_metadata() {
  ensure_createrepo
  log "write RPM repository metadata into $RPM_DIR"
  if command -v createrepo_c >/dev/null 2>&1; then
    createrepo_c --update "$RPM_DIR"
  elif command -v createrepo >/dev/null 2>&1; then
    createrepo --update "$RPM_DIR"
  else
    die "createrepo or createrepo_c is required to build packages/rpm metadata"
  fi
  [[ -f "$RPM_DIR/repodata/repomd.xml" ]] || die "failed to create $RPM_DIR/repodata/repomd.xml"
}

verify_rpm_repo_installable() {
  local manager="$1"
  shift
  local -a packages=("$@")
  local repo_dir
  repo_dir="$(mktemp -d /tmp/pg-ha-rpm-closure.XXXXXX)"
  local install_root
  install_root="$(mktemp -d /tmp/pg-ha-rpm-installroot.XXXXXX)"
  local baseurl="file://$RPM_DIR"
  cat > "$repo_dir/pg-ha-local.repo" <<EOF
[pg-ha-local]
name=pg-ha-local
baseurl=$baseurl
enabled=1
gpgcheck=0
EOF

  log "verify local RPM repository in an empty installroot with online repositories disabled"
  if "$manager" \
      --installroot="$install_root" \
      --releasever="$(current_os_major)" \
      --setopt="reposdir=$repo_dir" \
      --disablerepo='*' \
      --enablerepo=pg-ha-local \
      --setopt=tsflags=test \
      --setopt=keepcache=0 \
      --nogpgcheck \
      install -y "${packages[@]}"; then
    rm -rf "$repo_dir" "$install_root"
    log "local RPM repository empty-installroot verification passed"
    return 0
  fi
  rm -rf "$repo_dir" "$install_root"
  die "local RPM repository cannot install the required packages into an empty root. The bundle has unresolved or missing dependencies; do not copy it offline"
}

download_rpms() {
  local manager
  local -a pkgs
  # shellcheck disable=SC2207
  pkgs=($(rpm_prereq_packages))
  if [[ -n "$SSH_PASSWORD" && -z "$SSH_KEY" ]]; then
    pkgs+=(sshpass)
  fi
  prepare_repo_options
  manager="$(rpm_package_manager)" || die "RPM packages must be prepared on an online host with yum/dnf"
  log "[2/4] download yum/dnf RPM packages into $RPM_DIR"
  log "OS compatibility: $(current_os_pretty), $OS_COMPAT, arch=$RPM_ARCH"
  log "RPM root packages: ${pkgs[*]}"

  if [[ "$manager" == "dnf" ]]; then
    if ! dnf download --help >/dev/null 2>&1; then
      log "dnf download plugin missing; installing dnf-plugins-core on this online preparation host"
      run_repo_command dnf install -y dnf-plugins-core
    fi
    run_repo_command dnf download --resolve --alldeps --destdir "$RPM_DIR" "${pkgs[@]}"
  elif [[ "$manager" == "yum" ]]; then
    log "install yum-utils on this online preparation host for repotrack"
    run_repo_command yum install -y yum-utils
    command -v repotrack >/dev/null 2>&1 || die "repotrack is required but was not found after installing yum-utils"
    run_repo_command repotrack -a "$(uname -m)" -p "$RPM_DIR" "${pkgs[@]}"
  else
    die "RPM packages must be prepared on an online host with yum/dnf and the same OS major version, architecture, and Python version as the target nodes"
  fi

  require_files "$RPM_DIR" "*.rpm" "RPM packages"
  write_rpm_repo_metadata
  verify_rpm_repo_installable "$manager" "${pkgs[@]}"
}

download_python() {
  local -a source_args=()
  local manager python_tag
  log "[3/4] download pip packages"
  if ! ensure_python3_command; then
    log "python3 or python3-pip missing; installing them on this online preparation host"
    prepare_repo_options
    # shellcheck disable=SC2207
    local -a python_pkgs=($(rpm_python_packages))
    manager="$(rpm_package_manager)" || die "python3 and python3-pip are required to download Python packages"
    if [[ "$manager" == "dnf" ]]; then
      run_repo_command dnf install -y "${python_pkgs[@]}"
    elif [[ "$manager" == "yum" ]]; then
      run_repo_command yum install -y "${python_pkgs[@]}"
    else
      die "python3 and python3-pip are required to download Python packages"
    fi
  fi
  ensure_python3_command || die "python3 and python3-pip are required"
  python_tag="$(current_python_tag)"
  PYTHON_DIR="$PYTHON_ROOT_DIR/$OS_COMPAT/$python_tag/$RPM_ARCH"
  mkdir -p "$PYTHON_DIR"
  log "download pip packages into $PYTHON_DIR"
  pip_source_args
  if [[ -n "$PIP_SOURCE" ]]; then
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
  log "[1/4] download PostgreSQL/etcd/pg_probackup/pg_cron/pg_repack packages into $PACKAGE_DIR"
  download "https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}/postgresql-${POSTGRES_VERSION}.tar.gz" "$PACKAGE_DIR/postgresql-${POSTGRES_VERSION}.tar.gz"
  download "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz" "$PACKAGE_DIR/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
  download "https://github.com/postgrespro/pg_probackup/archive/refs/tags/${PG_PROBACKUP_VERSION}.tar.gz" "$PACKAGE_DIR/pg_probackup-${PG_PROBACKUP_VERSION}.tar.gz"
  download "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" "$PACKAGE_DIR/pg_cron-${PG_CRON_VERSION}.tar.gz"
  download "https://github.com/reorg/pg_repack/archive/refs/tags/ver_${PG_REPACK_VERSION}.tar.gz" "$PACKAGE_DIR/pg_repack-${PG_REPACK_VERSION}.tar.gz"
}

write_environment_manifest() {
  local output="$1" rpm_count python_count rpm_rel python_rel
  mkdir -p "$(dirname "$output")"
  rpm_count="$(count_files "$RPM_DIR" "*.rpm")"
  python_count="$(count_files "$PYTHON_DIR" "*")"
  rpm_rel="${RPM_DIR#$PACKAGE_DIR/}"
  python_rel="${PYTHON_DIR#$PACKAGE_DIR/}"
  cat > "$output" <<EOF
created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
os=$(current_os_id_version)
os_pretty=$(current_os_pretty)
os_compat=$OS_COMPAT
os_major=$(current_os_major)
arch=$RPM_ARCH
python=$(python3 -c 'import platform; print(platform.python_version())')
python_tag=$(current_python_tag)
postgresql=$POSTGRES_VERSION
patroni=$PATRONI_VERSION
rpm_dir=$rpm_rel
python_dir=$python_rel
rpm_files=$rpm_count
python_files=$python_count
EOF
}

write_manifest() {
  log "[4/4] write checksum and environment manifest"
  write_environment_manifest "$PACKAGE_DIR/OFFLINE-ENVIRONMENT.txt"
  write_environment_manifest "$RPM_DIR/OFFLINE-ENVIRONMENT.txt"
  write_environment_manifest "$PYTHON_DIR/OFFLINE-ENVIRONMENT.txt"
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

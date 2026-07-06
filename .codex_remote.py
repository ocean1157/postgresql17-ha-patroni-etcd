import os
import sys
import time
import tarfile
import tempfile
from pathlib import Path

sys.path.insert(0, r"F:\SqlSugarPackageCrudTest\.codex_tmp_pydeps")
import paramiko

ROOT = Path(r"F:\SqlSugarPackageCrudTest\postgresql17-ha-patroni-etcd")
HOSTS = ["10.0.0.121", "10.0.0.122", "10.0.0.123"]
USER = "root"
PASSWORD = "123456"
REMOTE_DIR = f"/root/pg-ha-regression-{time.strftime('%Y%m%d%H%M%S')}"


def connect(host):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        host,
        username=USER,
        password=PASSWORD,
        timeout=15,
        banner_timeout=15,
        auth_timeout=15,
        look_for_keys=False,
        allow_agent=False,
    )
    return client


def run(client, command, timeout=None):
    print(f"\n$ {command}", flush=True)
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout, get_pty=True)
    channel = stdout.channel
    chunks = []
    last = time.time()
    while not channel.exit_status_ready():
        while channel.recv_ready():
            data = channel.recv(4096).decode("utf-8", "replace")
            print(data, end="", flush=True)
            chunks.append(data)
            last = time.time()
        if time.time() - last > 30:
            print(f"\n[local] still running: {command}", flush=True)
            last = time.time()
        time.sleep(0.5)
    while channel.recv_ready():
        data = channel.recv(4096).decode("utf-8", "replace")
        print(data, end="", flush=True)
        chunks.append(data)
    err = stderr.read().decode("utf-8", "replace")
    if err:
        print(err, end="", flush=True)
    rc = channel.recv_exit_status()
    print(f"\n[local] rc={rc}", flush=True)
    if rc != 0:
        raise RuntimeError(f"command failed rc={rc}: {command}")
    return "".join(chunks)


def make_archive():
    fd, archive = tempfile.mkstemp(suffix=".tar.gz")
    os.close(fd)
    skip_dirs = {".git", ".idea", ".codex_tmp_pydeps", "__pycache__"}
    skip_files = {".codex_remote.py"}
    with tarfile.open(archive, "w:gz") as tf:
        for path in ROOT.rglob("*"):
            rel = path.relative_to(ROOT)
            parts = set(rel.parts)
            if parts & skip_dirs or path.name in skip_files:
                continue
            tf.add(path, arcname=str(rel))
    return archive


def upload_project(client, archive):
    run(client, f"mkdir -p '{REMOTE_DIR}'")
    sftp = client.open_sftp()
    remote_archive = "/tmp/pg-ha-regression.tar.gz"
    print(f"upload {archive} -> {remote_archive}", flush=True)
    sftp.put(archive, remote_archive)
    sftp.close()
    run(client, f"tar -C '{REMOTE_DIR}' -xzf '{remote_archive}' && rm -f '{remote_archive}'")


def main():
    for host in HOSTS:
        with connect(host) as c:
            run(c, "hostname && ip -4 addr | grep -E '10\\.0\\.0\\.12[1-3]' || true")

    archive = make_archive()
    try:
        with connect(HOSTS[0]) as c:
            upload_project(c, archive)
            run(c, f"cd '{REMOTE_DIR}' && bash -n scripts/lib.sh scripts/node-install.sh scripts/download-packages.sh scripts/deploy.sh scripts/check-cluster.sh")
            run(c, f"cd '{REMOTE_DIR}' && bash scripts/deploy.sh", timeout=7200)
            run(c, "su - postgres -c 'patronictl -c /etc/patroni/patroni.yml list'", timeout=120)
            run(c, "etcdctl --endpoints=http://10.0.0.121:2379,http://10.0.0.122:2379,http://10.0.0.123:2379 endpoint health", timeout=120)
            run(c, "su - postgres -c \"psql -Atc \\\"show archive_command;\\\"\"", timeout=120)
            run(c, "su - postgres -c '/usr/local/bin/pg_probackup --version && cat /etc/cron.d/pg-probackup-ha'", timeout=120)
    finally:
        os.remove(archive)


if __name__ == "__main__":
    main()

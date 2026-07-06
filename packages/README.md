# Packages

该目录是安装器使用的离线安装包缓存目录。

默认 PostgreSQL 小版本见 `postgresql.version`，当前为 `17.10`。

执行 `scripts/download-packages.sh` 后，建议准备以下文件或目录：

- `postgresql-17.10.tar.gz`：PostgreSQL 源码包。
- `etcd-v3.6.12-linux-amd64.tar.gz`：etcd 二进制包，其他架构会使用对应文件名。
- `pg_probackup-2.5.16.tar.gz`：pg_probackup 源码包。
- `wheels/`：Patroni 和 Python 依赖的离线 wheel/sdist 包。
- `rpms/<系统-大版本-架构>/`：系统 rpm 依赖包，例如 `rpms/centos-7-x86_64/`。

部署到内网时，安装脚本会优先使用该目录中的离线包；缺少 rpm 依赖包时，
才会尝试通过 yum/dnf/apt 从系统仓库安装。

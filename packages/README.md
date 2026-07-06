# Packages

该目录只保存安装器需要的核心软件包：

- `postgresql-17.10.tar.gz`：PostgreSQL 源码包。
- `etcd-v3.6.12-linux-amd64.tar.gz`：etcd 二进制包，其他架构会使用对应文件名。
- `pg_probackup-2.5.16.tar.gz`：pg_probackup 源码包。

系统编译依赖统一在部署时通过 yum/dnf 安装，Patroni 及其 Python 依赖统一通过 pip 在线安装。执行 `scripts/download-packages.sh` 只会补齐上面三类核心软件包。

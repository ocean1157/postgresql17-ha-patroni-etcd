# Packages

该目录只保存安装器需要的核心软件包：

- `postgresql-17.10.tar.gz`：PostgreSQL 源码包。
- `etcd-v3.6.12-linux-amd64.tar.gz`：etcd 二进制包，其他架构会使用对应文件名。
- `pg_probackup-2.5.16.tar.gz`：pg_probackup 源码包。
- `pg_cron-1.6.7.tar.gz`：pg_cron 源码包。

执行 `scripts/download-package.sh`（也可使用兼容名 `download-packages.sh`）会准备一个可整体搬运和重新打包的离线目录：

- 根目录保存 PostgreSQL、etcd、pg_probackup、pg_cron 核心包；
- `rpm/` 保存编译和运行所需 RPM 及其递归依赖；
- `python/` 保存 Patroni 及其完整 Python 依赖；
- `SHA256SUMS` 用于搬运后校验，`OFFLINE-ENVIRONMENT.txt` 记录制包环境。

RPM 和 Python 包与操作系统版本、CPU 架构及 Python 版本有关。请在与离线目标机相同的发行版大版本、架构和 Python 版本的联网主机上运行下载脚本。离线安装时 yum/dnf 和 pip 会分别一次性解析整个依赖集合，不按文件名逐个安装，因此安装顺序不会破坏依赖关系。

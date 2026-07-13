# PostgreSQL 17 HA Installer

这是一个面向三节点生产部署的 PostgreSQL + Patroni + etcd 高可用安装项目。默认节点为 `10.0.0.121`、`10.0.0.122`、`10.0.0.123`，默认 PostgreSQL 版本为官方 17 系列当前最新小版本 `17.10`。

## 架构

- PostgreSQL 17.10: 三节点 Patroni 管理的一主两备流复制集群。
- Patroni 3.0.4: 负责 PostgreSQL 生命周期、主备选举、故障切换、复制槽和动态参数管理。该版本兼容 CentOS 7 默认可安装的 Python 3.6。
- etcd 3.6.12: 三节点 DCS 仲裁，使用 v3 API。
- pg_probackup 2.5.16: WAL 归档和定时备份。
- pg_cron 1.6.7: 数据库内定时任务扩展。
- VIP: 可选，主节点回调自动绑定/释放虚拟 IP。

## 目录

```text
config/                  集群配置，只需要改 cluster.env
docs/                    旧文档生产优化分析
packages/                离线安装包目录，默认包含 PostgreSQL 17.10 版本标识
scripts/                 下载、分发、节点安装、巡检脚本
systemd/                 systemd 模板
```

## 快速开始

1. 修改 [config/cluster.env](config/cluster.env)，确认节点 IP、主机名、VIP、网卡、密码或 SSH key。

   仓库中的 `cluster.env` 不保存真实密码。部署前必须在本地填写：
   - `[deploy] ssh_password` 或 `ssh_key`
   - `[postgresql.auth] superpass`
   - `[postgresql.auth] replication_pass`
   - `[postgresql.auth] rewind_pass`
2. 准备安装包：

```bash
cd postgresql17-ha-patroni-etcd
bash scripts/download-package.sh
```

3. 上传整个项目到任意一个节点，例如 `10.0.0.121`。
4. 在该节点用 root 执行：

```bash
cd /path/to/postgresql17-ha-patroni-etcd
bash scripts/deploy.sh
```

`deploy.sh` 会把项目分发到其他节点，并在三台机器上执行节点安装。若 `ssh_password` 非空且未配置免密 SSH，脚本会尝试安装/使用 `sshpass`。

部署过程会显式写入并启用 `etcd.service`、`patroni.service`，按如下顺序启动：

1. 所有节点完成软件安装和 systemd unit 写入。
2. 所有节点执行 `systemctl daemon-reload` 和 `systemctl enable`。
3. 非阻塞启动三节点 etcd，并等待 etcd endpoint health。
4. 启动三节点 Patroni，并等待 Patroni 集群出现 Leader 和 streaming Replica。
5. 校验每个节点 `etcd.service`、`patroni.service` 均为 enabled/active。

## 生产部署建议

- 不建议关闭防火墙和 SELinux。脚本仅提示端口要求，默认不关闭安全机制。
- 不使用 `trust` 复制认证。复制用户、管理用户默认采用 SCRAM-SHA-256。
- etcd 使用 v3 API，不启用旧文档中的 `enable-v2`。
- systemd 设置 `Restart=on-failure`、`LimitNOFILE` 和服务依赖，避免早期 `Restart=no` 导致进程异常后无人拉起。
- PostgreSQL 参数集中进入 Patroni `bootstrap.dcs.postgresql.parameters`，不要手工分别改每个节点。
- VIP sudo 权限最小化，只允许 `ip` 和 `arping`。
- 备份建议接入 pgBackRest 或企业备份平台；本项目只提供 HA 部署和基础巡检，不把裸 `find -exec rm -rf` 清理策略作为默认项。

更完整的优化分析见 [docs/production-review.md](docs/production-review.md)。

## 验证

```bash
su - postgres
patronictl -c /etc/patroni/patroni.yml list
psql -h <VIP或主节点IP> -p 5432 -U postgres -d postgres -c "select version();"
bash scripts/check-cluster.sh
```

## 安装包说明

[packages/postgresql.version](packages/postgresql.version) 固定为 `17.10`。`download-package.sh`（兼容名 `download-packages.sh`）会下载四类核心软件包、RPM 递归依赖和 Patroni 的 Python 依赖，并生成校验清单。请在与目标机相同的 OS 大版本、CPU 架构和 Python 版本的联网环境执行，然后整体打包 `packages/` 搬到离线环境。设置 `[repository] offline_install="true"` 后，RPM 安装会禁用全部仓库，Python 安装会强制 `--no-index`，部署过程不会访问 yum/pip 网络源。

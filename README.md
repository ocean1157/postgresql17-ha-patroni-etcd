# PostgreSQL 17 HA Installer

这是一个面向三节点生产部署的 PostgreSQL + Patroni + etcd 高可用安装项目。默认节点为 `10.0.0.121`、`10.0.0.122`、`10.0.0.123`，默认 PostgreSQL 版本为官方 17 系列当前最新小版本 `17.10`。

## 架构

- PostgreSQL 17.10: 三节点 Patroni 管理的一主两备流复制集群。
- Patroni: 负责 PostgreSQL 生命周期、主备选举、故障切换、复制槽和动态参数管理。
- etcd 3.6.12: 三节点 DCS 仲裁，使用 v3 API。
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
2. 准备安装包：

```bash
cd postgresql17-ha-patroni-etcd
bash scripts/download-packages.sh
```

3. 上传整个项目到任意一个节点，例如 `10.0.0.121`。
4. 在该节点用 root 执行：

```bash
cd /path/to/postgresql17-ha-patroni-etcd
bash scripts/deploy.sh
```

`deploy.sh` 会把项目分发到其他节点，并在三台机器上执行节点安装。若 `SSH_PASSWORD` 非空且未配置免密 SSH，脚本会尝试安装/使用 `sshpass`。

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

[packages/postgresql.version](packages/postgresql.version) 固定为 `17.10`。`download-packages.sh` 会把源码包下载为 `packages/postgresql-17.10.tar.gz`，同时下载 etcd Linux 包。Patroni 通过 Python venv + pip 安装，若生产环境不能访问外网，请提前把 Python wheels 放入 `packages/wheels/`。

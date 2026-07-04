# 旧版 PostgreSQL 高可用安装文档生产优化分析

旧文档覆盖了 Patroni + etcd + PostgreSQL 的核心链路，但更接近手工部署记录。用于生产交付时，建议把“逐节点命令清单”升级为可重复、可校验、可审计的一键部署工程。

## 主要问题

1. 版本偏旧。旧文档使用 PostgreSQL 14.7、Patroni 3.0.0、etcd 3.5.6。新项目默认 PostgreSQL 17.10，并使用 etcd v3 API。
2. 安全边界偏弱。旧文档多处建议关闭防火墙、关闭 SELinux、使用 `trust` 复制认证、给 postgres 用户 `NOPASSWD:ALL`。生产应开放最小端口、保留 SELinux 策略或明确例外、使用 SCRAM 密码认证、sudo 权限最小化。
3. 可重复性不足。旧文档需要在多节点分别编辑配置，容易出现缩进、IP、主机名、路径不一致。本项目使用一个 `config/cluster.env` 生成 etcd、Patroni、VIP 和 systemd 配置。
4. 服务恢复策略不足。旧文档中 etcd/Patroni systemd 示例使用 `Restart=no`，进程异常后不能自动恢复。生产建议 `Restart=on-failure`，并设置合理的 `RestartSec`、`LimitNOFILE`、`TimeoutStopSec`。
5. DCS 配置过时。旧文档启用 etcd v2。Patroni 新部署应使用 etcd3，避免 v2 兼容遗留面。
6. PostgreSQL 参数应集中管理。旧文档先手工初始化主库和备库，再接入 Patroni，容易与 Patroni 动态配置冲突。生产建议由 Patroni bootstrap 初始化，并把关键参数写入 DCS。
7. RPO/RTO 表述需要条件化。文档写 `RPO=0, RTO<=10S`，但这依赖同步复制、仲裁可用、网络延迟、客户端重连策略和 `ttl/loop_wait/retry_timeout`。默认不应无条件承诺。
8. 备份策略风险较高。旧文档用 `pg_basebackup` + cron，并通过 `find ... -exec rm -rf` 清理。生产建议使用 pgBackRest、pg_probackup 或企业备份平台，保留恢复演练、备份校验和 WAL 保留策略。
9. 运维检查不完整。旧文档有切换验证，但缺少部署前检查、幂等性、端口连通性、磁盘/时钟/locale/依赖检查、失败回滚说明。
10. 密码和密钥管理不规范。文档示例中密码直接出现在命令里。生产应使用配置文件权限、临时环境变量、密钥管理系统或交付后强制轮换。

## 本项目的优化

- 单一配置文件：节点、VIP、路径、端口、用户和认证信息都集中在 `config/cluster.env`。
- 一节点发起部署：`scripts/deploy.sh` 负责分发项目并在三节点执行安装。
- Patroni bootstrap：由 Patroni 初始化 PostgreSQL 集群，减少手工主备搭建步骤。
- SCRAM 认证：默认 `password_encryption=scram-sha-256`，pg_hba 不使用 `trust`。
- etcd3：配置 Patroni `etcd3`，不启用旧 etcd v2 API。
- systemd 恢复：etcd 和 Patroni 均设置自动失败重启。
- VIP 最小权限：只允许 postgres 用户执行 `ip`、`arping` 所需命令。
- 基础巡检：提供 `scripts/check-cluster.sh` 查看 etcd、Patroni、PostgreSQL 状态。

## 生产落地前仍需确认

- 操作系统发行版和架构：脚本优先适配 RHEL/CentOS/Rocky/Alma 类系统和 x86_64/arm64。
- 磁盘规划：数据、WAL、备份目录建议分盘或独立卷，确认 RAID/缓存/掉电保护。
- 网络规划：确认 5432、8008、2379、2380 和 VIP 网段互通。
- 时间同步：建议 chrony 指向统一 NTP，不建议手工改时间。
- 备份恢复：上线前完成一次全备、一次 PITR、一次主备切换和一次节点重建演练。
- 监控告警：接入 PostgreSQL exporter、Patroni REST、etcd metrics、磁盘和系统指标。

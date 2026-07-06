# Configuration Design

## 节点 tags 中文说明

`[node.pg01.tags]`、`[node.pg02.tags]`、`[node.pg03.tags]` 会直接写入
Patroni 配置的 `tags` 段，用来控制节点在故障切换、读流量、基础备份和同步复制中的角色。

```ini
[node.pg01.tags]
nofailover="false"
noloadbalance="false"
clonefrom="false"
nosync="false"
```

- `nofailover=false`：该节点允许在主库故障时被 Patroni 自动提升为新主库。
- `nofailover=true`：该节点禁止自动提升为主库，适合只做报表、延迟较大或容灾观察节点。
- `noloadbalance=false`：该节点允许承担读请求，后续如果接入 HAProxy/应用读写分离，可以把它纳入读池。
- `noloadbalance=true`：该节点不承担读流量，适合维护中、低性能或跨地域节点。
- `clonefrom=false`：该节点不是优先克隆源，新副本初始化时 Patroni 不会特别优先选它。
- `clonefrom=true`：该节点可作为优先克隆源，适合磁盘/网络条件更好的本地副本。
- `nosync=false`：该节点允许成为同步从库。要“始终保持一个同步从库”，本地候选副本通常保持这个值。
- `nosync=true`：该节点永远不作为同步从库，只做异步从库，适合跨机房、链路延迟高或不希望影响主库提交延迟的节点。

常见组合：

- 三节点同机房强一致：三个节点都设置 `nosync=false`，`synchronous_node_count=1`。
- 两本地节点加一个异地容灾节点：本地节点 `nosync=false`，异地节点 `nosync=true`，必要时再加 `nofailover=true`、`noloadbalance=true`。
- 维护某个副本：临时设置 `noloadbalance=true`；如果不希望它成为同步从库，再设置 `nosync=true`。

## 安装包设计

`scripts/download-packages.sh` 在有网络的机器上执行后，会准备这些内容：

- `packages/postgresql-*.tar.gz`：PostgreSQL 源码包。
- `packages/etcd-*-linux-*.tar.gz`：etcd 二进制包。
- `packages/pg_probackup-*.tar.gz`：pg_probackup 源码包。

系统编译依赖统一在部署时通过 yum/dnf 安装，Patroni、psycopg2、etcd 客户端等 Python 依赖统一通过 pip 在线安装。

## 安装耗时说明

安装慢通常不是 shell 本身造成的，主要耗时点是：

- PostgreSQL 源码编译，尤其是 `make -j$(nproc)` 和 contrib 编译。
- 首次安装系统编译依赖时，需要下载大量 rpm。
- 首次安装 Patroni 时，需要解析和下载 Python 依赖。

脚本现在对 PostgreSQL configure/make/install 和 pip install 增加了心跳日志，
长时间没有新输出时也会每 30 秒打印一次 still running，便于确认安装进程仍然存活。

`--with-python` 已作为默认编译选项放入 `[postgresql.install] configure_options`。
生产上如需额外启用 LZ4/ZSTD，请先准备 `lz4-devel`、`libzstd-devel` 等依赖，
再把 `--with-lz4`、`--with-zstd` 加入 `configure_options`。

## PostgreSQL Sections

`[postgresql]` describes the PostgreSQL instance identity and connection
surface:

- `version`
- `nodes`
- `port`
- `os_user`
- `database`

`[postgresql.install]` describes filesystem and installation layout only:

- `prefix`
- `data_dir`
- `wal_archive`
- `backup_dir`

`[postgresql.auth]` describes database users and passwords:

- `superuser` / `superpass`
- `replication_user` / `replication_pass`
- `rewind_user` / `rewind_pass`

`[postgresql.conf]` is the only PostgreSQL section rendered into Patroni
`bootstrap.dcs.postgresql.parameters`, meaning these values become managed
PostgreSQL configuration:

- memory and connection settings
- WAL and replication settings
- logging settings
- archive settings
- socket directory settings

This split keeps installation paths, credentials, and PostgreSQL GUCs visually
separate.

## Patroni Sync Modes

For the requirement "always keep one synchronous standby", use:

```ini
[patroni.sync]
synchronous_mode="true"
synchronous_mode_strict="true"
synchronous_node_count="1"
```

The tradeoff is intentional: if no eligible synchronous standby is available,
client writes wait until one returns. This gives stronger RPO behavior but can
reduce write availability during replica outages.

For higher write availability with graceful degradation, use:

```ini
[patroni.sync]
synchronous_mode="true"
synchronous_mode_strict="false"
synchronous_node_count="1"
```

In this mode Patroni keeps one synchronous standby when possible, but allows the
primary to continue accepting writes if no eligible synchronous standby exists.

For a fully asynchronous cluster:

```ini
[patroni.sync]
synchronous_mode="false"
synchronous_mode_strict="false"
synchronous_node_count="1"
```

## Node Tags

Each node has a `[node.<name>.tags]` section that maps to Patroni tags:

```ini
[node.pg03.tags]
nofailover="false"
noloadbalance="false"
clonefrom="false"
nosync="false"
```

Important tag meanings:

- `nosync=false`: this node can become a synchronous standby.
- `nosync=true`: this node is forced to stay asynchronous.
- `nofailover=true`: this node cannot be promoted to primary.
- `noloadbalance=true`: this node should not receive read traffic.
- `clonefrom=true`: this node can be preferred as a clone source.

Common scenarios:

1. Three local nodes, always one synchronous standby:
   - `[patroni.sync] synchronous_mode=true`
   - `[patroni.sync] synchronous_mode_strict=true`
   - `[patroni.sync] synchronous_node_count=1`
   - all local nodes `nosync=false`

2. Two local nodes plus one remote disaster recovery node:
   - local nodes `nosync=false`
   - remote DR node `nosync=true`
   - optionally remote DR node `nofailover=true` and `noloadbalance=true`

3. Require two synchronous standbys:
   - `synchronous_node_count=2`
   - at least two eligible replicas must have `nosync=false`
   - with `synchronous_mode_strict=true`, writes wait if fewer than two eligible
     synchronous standbys are available

4. Maintenance on one replica:
   - temporarily set that node `nosync=true`
   - optionally set `noloadbalance=true`
   - reload/redeploy Patroni config, or use Patroni dynamic config where
     applicable

For a new initialized cluster, values under `bootstrap.dcs` are written when the
cluster is bootstrapped. For an already-running cluster, DCS values should be
changed with `patronictl edit-config` or by reinitializing the DCS state.

## pg_probackup 备份策略

`[pg_probackup]` 单元控制备份目录、实例名、命令路径、保留策略和计划任务时间。当前默认使用 2.5.16，这是 pg_probackup GitHub Release 页面标记的 Latest 版本。

- `retention_redundancy="4"`：保留 4 个可用全量备份链。
- `retention_window="30"`：尽量保留 30 天恢复窗口。
- `cron_hour="1"`、`cron_minute="30"`：每天凌晨 1:30 运行。
- `full_backup_day="0"`：周日做全量备份，0 代表周日。
- `incremental_mode="PAGE"`：非全量日做 PAGE 增量备份。

备份脚本只会在当前 Patroni Leader 上执行，Replica 节点会自动跳过。首次运行如果没有发现有效历史备份，即使当天不是周日，也会自动切换为 FULL，避免第一次就执行增量失败。PostgreSQL 的 `archive_command` 使用 `pg_probackup archive-push` 归档 WAL。

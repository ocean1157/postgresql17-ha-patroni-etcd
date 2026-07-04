# 安装测试记录

测试时间：2026-07-04

测试节点：

- `10.0.0.121` / `pg01` / CentOS 7 / x86_64
- `10.0.0.122` / `pg02` / CentOS 7 / x86_64
- `10.0.0.123` / `pg03` / CentOS 7 / x86_64

## 测试结果

三节点 PostgreSQL 17.10 + Patroni 3.0.4 + etcd 3.6.12 安装成功。

Patroni 集群状态：

```text
+ Cluster: pg17-ha ---+---------+-----------+----+-----------+
| Member | Host       | Role    | State     | TL | Lag in MB |
+--------+------------+---------+-----------+----+-----------+
| pg01   | 10.0.0.121 | Leader  | running   |  1 |           |
| pg02   | 10.0.0.122 | Replica | streaming |  1 |         0 |
| pg03   | 10.0.0.123 | Replica | streaming |  1 |         0 |
+--------+------------+---------+-----------+----+-----------+
```

数据库版本验证：

```text
PostgreSQL 17.10 on x86_64-pc-linux-gnu, compiled by gcc (GCC) 4.8.5 20150623 (Red Hat 4.8.5-44), 64-bit
```

## 试装中发现并修复的问题

1. CentOS 7 缺少编译依赖：补充 `libicu-devel`、`bison`、`flex`。
2. CentOS 7 默认没有 Python3：安装 `python3`、`python3-devel`、`python3-pip`。
3. 新版 Patroni/Psycopg 不兼容 Python 3.6：将 Patroni 固定为 `3.0.4`，使用 `psycopg2-binary==2.9.5`。
4. `ydiff 1.5` 与 Patroni 3.0.4 的 `patronictl` 不兼容：固定 `ydiff==1.4.2` 并安装 `cdiff` fallback。
5. `/var/run/postgresql` 权限不足：创建目录、调整属主，并在 patroni systemd 中加入 `RuntimeDirectory=postgresql`。
6. CentOS 7 不支持 `C.UTF-8` locale：将 initdb locale 调整为 `C`。
7. Patroni 失败回滚需要重命名 `/pgdata/pg17`，父目录权限不足：将 `$(dirname "$PG_DATA")` 归属给 postgres。
8. 三节点 etcd 顺序启动时第一台可能等待 quorum 导致 systemd 超时：部署脚本改为 `systemctl start --no-block etcd`，并等待 endpoint health 后启动 Patroni。
9. CentOS 7 OpenSSH 不支持 `StrictHostKeyChecking=accept-new`：改为兼容老版本 OpenSSH 的 `StrictHostKeyChecking=no`。
10. `deploy.sh` 的 `run_remote()` 未 `shift` 掉 IP 参数，导致远端命令前多出节点 IP：已修复参数处理。
11. 从 bootstrap 节点执行部署时，不应 SSH 复制项目给自己：已跳过本机自复制，避免源/目标目录相同带来的覆盖风险。

## systemd 回归验证

在三台初始化后的节点上，从 `10.0.0.121` 上传项目并执行：

```bash
cd /opt/pg-ha-installer
bash scripts/deploy.sh
```

执行结果：`deploy.sh` 返回 `0`。

三节点 systemd 状态：

```text
10.0.0.121 etcd.service    enabled active
10.0.0.121 patroni.service enabled active
10.0.0.122 etcd.service    enabled active
10.0.0.122 patroni.service enabled active
10.0.0.123 etcd.service    enabled active
10.0.0.123 patroni.service enabled active
```

etcd 健康检查：

```text
http://10.0.0.121:2379 is healthy
http://10.0.0.122:2379 is healthy
http://10.0.0.123:2379 is healthy
```

最终 Patroni 状态：

```text
+ Cluster: pg17-ha ---+---------+-----------+----+-----------+
| Member | Host       | Role    | State     | TL | Lag in MB |
+--------+------------+---------+-----------+----+-----------+
| pg01   | 10.0.0.121 | Leader  | running   |  1 |           |
| pg02   | 10.0.0.122 | Replica | streaming |  1 |         0 |
| pg03   | 10.0.0.123 | Replica | streaming |  1 |         0 |
+--------+------------+---------+-----------+----+-----------+
```

复制状态：

```text
 client_addr |   state   | sync_state
-------------+-----------+------------
 10.0.0.122  | streaming | async
 10.0.0.123  | streaming | async
```

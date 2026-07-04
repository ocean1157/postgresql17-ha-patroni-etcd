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

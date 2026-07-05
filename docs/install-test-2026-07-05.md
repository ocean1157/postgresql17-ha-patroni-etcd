# Install Regression - 2026-07-05

## Scope

- Nodes: 10.0.0.121, 10.0.0.122, 10.0.0.123
- OS: CentOS Linux 7.9
- PostgreSQL: 17.10
- etcd: 3.6.12
- Patroni: 3.0.4
- VIP: 10.0.0.124/24 on ens33

## Fixes Validated

- `config/cluster.env` now uses INI-style sections: `[cluster]`, `[deploy]`, `[os]`, `[etcd]`, `[postgresql]`, `[patroni]`, `[vip]`, and `[node.*]`.
- The installer maps sectioned settings to runtime variables and supports empty per-node overrides as inheritance from global settings.
- The installer writes `/home/postgres/.pgev` and only sources it for the `postgres` OS user from `/etc/profile.d/postgresql17.sh`.
- OS baseline configuration is applied:
  - timezone `Asia/Shanghai`
  - chrony enabled
  - Transparent Huge Pages disabled with systemd
  - sysctl baseline in `/etc/sysctl.d/99-postgresql-ha.conf`
  - postgres limits in `/etc/security/limits.d/99-postgresql-ha.conf`
- `etcdctl` checks unset inherited `ETCDCTL_ENDPOINTS` before using explicit `--endpoints`, avoiding etcd 3.6 flag/env conflicts.
- PostgreSQL now listens on `0.0.0.0:5432` while Patroni `connect_address` remains node-specific, allowing VIP traffic.

## Regression Result

`scripts/deploy.sh` completed successfully from 10.0.0.121.

Service state on all nodes:

```text
etcd.service: enabled / active
patroni.service: enabled / active
```

etcd health:

```text
http://10.0.0.121:2379 is healthy
http://10.0.0.122:2379 is healthy
http://10.0.0.123:2379 is healthy
```

Patroni cluster after rolling restart:

```text
| pg01 | 10.0.0.121 | Replica | streaming | TL 2 | Lag 0 |
| pg02 | 10.0.0.122 | Leader  | running   | TL 2 |       |
| pg03 | 10.0.0.123 | Replica | streaming | TL 2 | Lag 0 |
```

VIP validation:

```text
10.0.0.124 is bound only on 10.0.0.122 ens33:pgvip
psql -h 10.0.0.124 returned pg_is_in_recovery = false
PostgreSQL version: 17.10
```

Environment validation:

```text
/home/postgres/.pgev exports PGHOME, PGDATA, PGPORT, PGDATABASE, PGUSER,
PGHOST, PATRONI_CONFIG, ETCDCTL_ENDPOINTS, PATH, and LD_LIBRARY_PATH.
```

OS validation:

```text
timezone: Asia/Shanghai
disable-thp.service: enabled
transparent_hugepage/enabled: always madvise [never]
vm.swappiness = 10
net.core.somaxconn = 4096
fs.file-max = 76724600
postgres nofile limit = 102400
```

## Issues Found During Regression

- The default VIP device was `eth0`, but the test VMs use `ens33`; `config/cluster.env` was updated.
- A global profile script initially leaked `ETCDCTL_ENDPOINTS` into root shells, causing etcd 3.6 `etcdctl --endpoints` to fail with a flag/env conflict; the profile is now postgres-user-only and checks use `env -u ETCDCTL_ENDPOINTS`.
- VIP was bound but PostgreSQL only listened on the node IP; Patroni now generates `postgresql.listen: 0.0.0.0:5432`.

## Sync Standby Regression

The configuration was further split into `[postgresql]`, `[postgresql.install]`,
`[postgresql.auth]`, `[postgresql.conf]`, `[patroni.dcs]`, `[patroni.sync]`,
and `[node.*.tags]`.

Strict one-sync-standby configuration:

```text
synchronous_mode: true
synchronous_mode_strict: true
synchronous_node_count: 1
```

Patroni result:

```text
| pg01 | 10.0.0.121 | Leader       | running   | TL 1 |       |
| pg02 | 10.0.0.122 | Replica      | streaming | TL 1 | Lag 0 |
| pg03 | 10.0.0.123 | Sync Standby | streaming | TL 1 | Lag 0 |
```

PostgreSQL replication state on the leader:

```text
synchronous_standby_names = pg03
pg02 | async | streaming
pg03 | sync  | streaming
```

VIP validation still passed:

```text
10.0.0.124 | pg_is_in_recovery = false
```

# Configuration Design

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

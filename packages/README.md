# Packages

This directory is the offline package cache used by the installer.

Default PostgreSQL major/minor: see `postgresql.version` (`17.10`).

Expected files after running `scripts/download-packages.sh`:

- `postgresql-17.10.tar.gz`
- `etcd-v3.6.12-linux-amd64.tar.gz` or the matching architecture package
- optional Python wheelhouse under `wheels/` for offline Patroni installation

The tarballs are intentionally not required for reading the project, but the
installer will prefer local files from this directory when present.

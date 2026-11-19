# Back up and restore a coordinator database

With Python 3.11 or later, run the following from the deployed Tachi revision. Supply the actual database path and a new destination in a private directory on a filesystem that supports hard links.

```sh
umask 077
mkdir -p backups
python3 -m tachi.snapshot state/coordinator.sqlite backups/coordinator-001.sqlite
```

The SQLite online backup API reads a consistent snapshot that includes committed changes in the write-ahead log. The command checks the copy's integrity, sets owner-only permissions and refuses to replace an existing file. Store snapshots with the same access controls as the live database. Keep the source commit and artifact storage backup together with the snapshot. Multiple database files or separate artifact stores require stopping dispatch and writes while capturing the complete set. Provider-owned remote histories and secret-store credentials have their own recovery procedures.

Restore into a **new, disconnected data directory** while the coordinator and workers are stopped. For example:

```sh
umask 077
mkdir -m 700 recovered
python3 -m tachi.snapshot backups/coordinator-001.sqlite recovered/coordinator.sqlite
```

Start verification with synthetic data. An older snapshot can contain a previously valid pairing, grant or queued effect that changed after the backup. Before external dispatch, re-establish current authority and reconcile previously submitted work with the host or provider. Revoke restored access where later changes cannot be verified. Keep the previous data directory intact until the recovered instance has passed verification. End-to-end deployment, restart with native work and authorization reconciliation remain tracked in [issue 11](https://github.com/Section9Labs/tachi/issues/11).

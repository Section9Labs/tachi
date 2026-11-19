# Deploy and recover the Swift coordinator on Linux

## Install the standalone service

On a fresh Ubuntu 24.04 amd64 host, download the `tachi-coordinator-linux-amd64` artifact from the successful **Swift service** workflow for your chosen source commit. Unzip the Actions download to get the tarball. The archive contains the coordinator, the accounts CLI and a systemd unit. Both binaries include the Swift runtime.

```sh
sudo apt-get update
sudo apt-get install -y libsqlite3-0 libssl3t64 libcurl4t64 ca-certificates sqlite3
stage=$(mktemp -d)
tar xzf tachi-coordinator-linux-amd64.tar.gz -C "$stage"
sudo useradd --system --user-group --home-dir /var/lib/tachi --no-create-home --shell /usr/sbin/nologin tachi
sudo install -m 0755 "$stage/tachi-coordinator" "$stage/tachi-accounts" /usr/local/bin/
sudo install -m 0644 "$stage/tachi-coordinator.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tachi-coordinator.service
curl --fail http://127.0.0.1:8743/v1/status
```

systemd creates the private state directory on first start. To pair a person, mint a single-use invitation as the service user, transfer it privately to its recipient within five minutes, then remove the invitation file. Remote devices connect through an HTTPS reverse proxy to the loopback listener.

```sh
ticket_dir=$(sudo -u tachi mktemp -d /var/lib/tachi/invite.XXXXXXXX)
sudo -u tachi /usr/local/bin/tachi-accounts invite-client --db /var/lib/tachi/coordinator.sqlite \
  --human-id example-user --scope sessions:read --scope messages:send --scope teams:manage \
  --out "$ticket_dir/client.invitation"
```

Before upgrading, save an online SQLite backup and the installed source revision in protected off-host storage. The following creates a private local snapshot and checks it.

```sh
backup_dir=$(sudo -u tachi mktemp -d /var/lib/tachi/backup.XXXXXXXX)
sudo -u tachi sqlite3 -readonly /var/lib/tachi/coordinator.sqlite ".backup '$backup_dir/coordinator.sqlite'"
sudo -u tachi sqlite3 -readonly "$backup_dir/coordinator.sqlite" 'PRAGMA integrity_check;'
```

For an upgrade, stop the unit, install both executables and the unit from the new archive, run `systemctl daemon-reload`, then start it. Verify an existing client's workspace through the same HTTPS origin. To rehearse a restore, use a fresh isolated host, install the pinned binaries, and install the checked snapshot as `/var/lib/tachi/coordinator.sqlite` (owner and group `tachi`, mode 0600) in a new mode-0700 state directory before the first service start. Reconcile grants and external submissions before connecting providers.

## Run in Docker

Build the image from the source revision you intend to run. Record the revision with each backup. A named volume preserves client bindings, teams and pending messages when the container is replaced. The service listens on host loopback. To pair a remote Apple device, configure an HTTPS reverse proxy on your host and ensure its logs omit credentials and request bodies.

```sh
image="tachi-service:$(git rev-parse --short HEAD)"
docker build -t "$image" .
docker volume create tachi-state
docker run -d --name tachi --restart unless-stopped \
  -p 127.0.0.1:8743:8743 -v tachi-state:/var/lib/tachi "$image" \
  --host 0.0.0.0 --port 8743 --db /var/lib/tachi/coordinator.sqlite --reference-teams
curl --fail http://127.0.0.1:8743/v1/status
```

The optional `--reference-teams` flag enables synthetic assistants. To pair a client, create a short-lived invitation for its human identity. Deliver the invitation privately, then remove the copies. It can be redeemed once.

```sh
umask 077
private=$(mktemp -d)
docker exec tachi tachi-accounts invite-client --db /var/lib/tachi/coordinator.sqlite \
  --human-id example-user --scope sessions:read --scope messages:send --scope teams:manage \
  --out /tmp/first.invitation
docker cp tachi:/tmp/first.invitation "$private/first.invitation"
docker exec tachi rm /tmp/first.invitation
```

## Diagnose stuck work

Run the installed coordinator as a local operator with read access to the service database.

```sh
sudo -u tachi /usr/local/bin/tachi-coordinator diagnostics --db /var/lib/tachi/coordinator.sqlite
```

The command prints one JSON object with `runs` and `deliveries`. Each contains coordinator-wide counts under fixed state names, including zeros. Unrecognized states contribute to `other`. A paused run can explain pending work. A blocked delivery needs a prerequisite resolved, while an uncertain delivery needs reconciliation before an operator considers a retry.

Both counts come from one read-only SQLite transaction, including committed changes in a live WAL. The command exits after printing the snapshot. On failure it writes a generic error to stderr and exits with a nonzero status. Operators can compare successive snapshots to see whether the backlog is changing.

## Back up a running instance

The SQLite online backup includes committed WAL transactions. Both temporary directories below are private and newly created. The resulting snapshot contains sensitive account and team state. Preserve it and the recorded image revision on protected storage off the host.

```sh
umask 077
backup=$(mktemp -d)
stage=$(docker exec tachi mktemp -d)
docker exec -w "$stage" tachi sqlite3 -readonly /var/lib/tachi/coordinator.sqlite '.backup snapshot.sqlite'
docker cp "tachi:$stage/snapshot.sqlite" "$backup/coordinator.sqlite"
docker exec tachi rm "$stage/snapshot.sqlite"
docker exec tachi rmdir "$stage"
docker inspect --format '{{.Config.Image}} {{.Image}}' tachi > "$backup/image.txt"
```

## Restore or rehearse an upgrade

Choose a **new, unused volume name** for each rehearsal. The original instance and volume stay available. The following command restores into an empty volume and checks SQLite integrity. Choose the candidate image for an upgrade rehearsal. The helper has no network access.

```sh
recovered=$(docker volume create)
docker run --rm -i --network none -v "$recovered:/var/lib/tachi" --entrypoint sh "$image" -ec '
  cd /var/lib/tachi
  umask 077
  test -z "$(ls -A)"
  cat > snapshot.sqlite
  test -s snapshot.sqlite
  test "$(sqlite3 -readonly snapshot.sqlite "PRAGMA integrity_check")" = ok
  sqlite3 -readonly snapshot.sqlite ".backup coordinator.sqlite"
  rm snapshot.sqlite
' < "$backup/coordinator.sqlite"
```

Start verification in isolation with external workers disabled. A restored snapshot can contain a subsequently revoked grant or a task the provider already executed. Reconcile affected grants and remote work before resuming dispatch. Back up separate artifact stores and operator-managed secrets according to their own recovery procedures. Stop writes while capturing state that spans multiple stores.

For cutover, stop and rename the old container (for example, `docker stop tachi && docker rename tachi tachi-previous`), then start the verified image against the recovered volume using the deployment command above and the same HTTPS origin. Retain the old volume. If writes have occurred after cutover, reconcile them before switching back. CI exercises a live backup, authenticates on the restored service, resumes one paused reference task and checks that resending the original ID consumes one turn.

## Legacy Python snapshot utility

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

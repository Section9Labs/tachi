# Workspace data retention and recovery

This guide covers human workspaces on the Swift coordinator. Artifact deletion requires a build that includes [the authored-artifact deletion route](https://github.com/Section9Labs/tachi/pull/105).

## What stays in the live workspace

**Messages.** The coordinator stores room messages and direct messages in SQLite, including their text and sender. A current member with `sessions:read` can see room history. Each participant in a direct exchange can read it while their own membership generation matches the one recorded on the message. Removing a member ends access. Rejoining restores room history and starts a new generation for private exchanges. Removing a member or revoking a client leaves stored messages in place. There is currently no message deletion route or automatic message expiry.

**Artifacts.** SQLite holds the uploaded bytes in base64, their digest and metadata, including audience, uploader and any source message or task reference. Room and direct artifacts follow the same read rules as messages. The upload limits are 1 MiB per artifact, 256 live artifacts and 64 MiB of decoded content per workspace. At capacity, additional uploads that exceed a limit fail. Older items stay available until explicitly deleted.

**Delete an upload.** Send an empty-body `DELETE /v1/workspaces/{workspace_id}/artifacts/{artifact_id}` with a paired bearer scoped to `messages:send`. The client must belong to the original author in the membership generation that uploaded it. A sibling client of that author can delete it. Workspace ownership and receipt of a direct artifact confer no deletion authority.

A successful `200 {"deleted":true}` removes the live artifact row and releases its quota. Subsequent downloads return 404, and lists and exports omit it. The same transaction reserves the pair of workspace ID and artifact ID. The reservation holds no content, filename, author or timestamp and has no automatic expiry. Repeated deletion and otherwise valid uploads reusing that ID in the same workspace return 404. A fresh upload needs a fresh ID. Source messages, tasks and delivery records retain their state. Deletion does not replay provider work or guarantee forensic erasure of SQLite pages, journals or storage media.

## Copies, reports and logs

| Copy | Contents and lifetime |
| --- | --- |
| Workspace export | `GET /v1/workspaces/{workspace_id}/export` with `sessions:read` returns the caller's visible messages and verified artifact bytes in one snapshot. Up to 100 visible messages, 16 visible artifacts and 4 MiB of decoded artifact content can be returned together. Exceeding any limit gives 413 with no partial export. Pagination is unavailable. |
| Saved export or download | A file saved to a device, shared folder or another backup is a separate copy. The person or system holding it controls its retention. Deletion or membership revocation changes future coordinator access. It cannot recall a saved copy. |
| Operator diagnostics | `tachi-coordinator diagnostics --db PATH` prints coordinator-wide run and delivery counts under fixed state names. Unknown states count toward `other`. It reads committed SQLite state, including a live WAL, and writes the report to stdout. It contains no item IDs, content, credentials, paths, destinations or provider metadata. A redirected or collected report follows the destination's retention policy. |
| Service and proxy logs | The service announces its listening address at startup. The local diagnostic command uses fixed error text. Host journals, container logging drivers and reverse proxies can retain their own output. Configure access, rotation and expiry there. Keep authorization headers, invitations, request and response bodies, credential-bearing URLs and private identifiers out of logs. Artifact deletion does not edit those logs. |

Tachi currently has no scheduled workspace purge, age-based retention setting, or automatic expiry for saved copies and backups. The deployment operator chooses backup and log retention. A workspace export contains one member's visible data and cannot restore the coordinator.

## Restoring a backup after a deletion

1. **Identify the snapshot.** A SQLite online backup captures committed database state at the time of the snapshot, including committed WAL changes. Record the source revision and backup time. Protect a full snapshot as sensitive data across all users. It includes private history, artifact content, stored account and grant state, and queued work. Separately stored credentials, operator configuration and provider-side histories have their own recovery procedures.
2. **Restore in isolation.** Preserve the current database and the original backup. Restore a copy into a new private directory or empty volume. Check SQLite integrity and use the recorded compatible service revision for inspection. Keep client ingress closed and external workers and dispatch disabled. Use a deletion-capable coordinator to verify or reapply a deletion. See the [Linux backup and restore procedure](sqlite-recovery.md#restore-or-rehearse-an-upgrade).
3. **Reconcile later changes.** A backup taken after a committed deletion carries the reserved ID and omits the live artifact. A backup taken between upload and deletion restores the artifact and lacks the reservation. A backup taken before upload has neither. Tachi does not merge subsequent deletions or revocations into a restored snapshot. Prefer a verified newer snapshot that includes them. If a stale snapshot must be used and the artifact is present, an independently verified author with the original live membership generation can repeat the requested deletion through the supported route. Never treat credentials or membership restored from that snapshot as proof of current authority.
4. **Verify before cutover.** Confirm required reservations against trusted current records, and check that deleted content is absent from authorized downloads, lists and exports. A download returning 404 alone cannot establish that the ID was reserved. Reconcile later client, membership and grant revocations and check uncertain or submitted work against host or provider evidence before enabling dispatch. If a required reservation or authorization change cannot be verified or restored through supported operations, keep the copy isolated and obtain a suitable recovery source. There is no operator API to reserve an absent artifact ID retroactively.

On a restored database with the deletion schema, an operator can check a **known** reservation through a read-only SQLite connection. Bind the two lowercase UUIDs from the authorized deletion record. A result of 1 confirms the reservation in that copy. This check does not enumerate anyone's content.

```sql
SELECT EXISTS (
    SELECT 1 FROM rt_deleted_workspace_artifact
    WHERE team = 'workspace/' || :workspace_id AND artifact = :artifact_id
) AS reserved;
```

Keep superseded snapshots out of the active restore set and apply the backup store's access and disposal policy to them. SQLite integrity checks verify database structure. Reconciliation establishes whether the restored data and permissions are current.

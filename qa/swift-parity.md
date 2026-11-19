# Swift coordinator parity

Run from the repository root with Python 3.11 or later as the HTTP client. Each stage starts an ephemeral loopback listener. Pairing and team tests create credentials in a private temporary directory and remove the test database on exit. The default candidate is the Swift service.

| Stage | Command | Evidence |
| --- | --- | --- |
| Bootstrap | `python3 qa/swift_service_parity.py status` | Runs the existing exact status probe against `swift run tachi-coordinator --port 0` and verifies the v1 unknown-route response. |
| Pairing | `python3 qa/swift_service_parity.py pairing --legacy-root /path/to/previous-checkout` | Runs the existing client-pairing checks with the Swift operator CLI. Then runs a cutover and restart using an existing Python coordinator database. |
| Reference teams | `python3 qa/swift_service_parity.py reference-teams` | Runs the existing sibling-client, cross-human isolation and pending-work revocation check against the opt-in Swift reference-team service. Assistant work in this stage is synthetic. |

Use `--service-root` to build and run a candidate from a separate checkout while retaining this QA driver. `--legacy-root` selects the historical Python source used to produce the database. For reproducible pairing evidence use a checkout or source archive of the original [pairing revision](https://github.com/Section9Labs/tachi/commit/10ee2490090156d521392401199ce475695ac030) and record both revisions. The default producer is the working directory. Add `--python-control` to any stage to validate the oracle using Python on the candidate side. Record that run separately from Swift results.

The cutover test first creates two legacy clients of the same human, revokes one, and leaves an unredeemed invitation for a second human. After the old server exits, the candidate opens that exact SQLite file. It must resolve the surviving bearer with its original client ID and scopes, reject the revoked bearer and consumed invitation, and redeem the pending invitation. The candidate operator revokes the original surviving client. A second candidate process must still reject both revoked bearers and the re-used invitation, and resolve the new client with its original identity and scopes. No schema or fixture rows are constructed by the test.

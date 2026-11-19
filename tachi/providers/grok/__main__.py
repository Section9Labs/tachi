"""Print a sanitized Grok Bot probe. Does not start a Bot and does not read history."""

from __future__ import annotations

import json
import sys

from tachi.providers.grok.connector import evidence, probe_client, published_release
from tachi.providers.grok.probe import ProbeError, utc_now


def main() -> int:
    now = utc_now()
    install = probe_client()
    release = None
    feed_error = None
    try:
        release = published_release()
    except ProbeError as exc:
        feed_error = str(exc)
    record = evidence(install, release, observed_at=now, checkpoint=None, feed_error=feed_error)
    json.dump(record, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

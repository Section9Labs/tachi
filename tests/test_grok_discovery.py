"""Discovery docs stay distinct, dated, and free of product mix-ups."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tachi.providers.grok.capabilities import CAPABILITIES, CONNECTOR_OPERATIONS
from tachi.providers.grok.connector import describe

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs" / "providers"
EVIDENCE = DOCS / "evidence" / "grok-bot.json"


class DiscoveryDocTests(unittest.TestCase):
    def test_matrices_name_different_products(self) -> None:
        grok = (DOCS / "grok.md").read_text()
        instinct = (DOCS / "instinct.md").read_text()
        zapia = (DOCS / "zapia.md").read_text()
        duet = (DOCS / "duet.md").read_text()
        self.assertIn("# Grok Bot", grok)
        self.assertIn("# Instinct", instinct)
        self.assertIn("# Zapia", zapia)
        self.assertIn("# Claude Duet", duet)
        self.assertNotIn("Claude Code", grok)
        self.assertNotIn("Claude Code", instinct)
        self.assertNotIn("Claude Code", zapia)
        self.assertIn("Claude Code", duet)
        self.assertIn("not Claude Code", duet)
        self.assertNotIn("provider_id: grok-bot", instinct)
        self.assertNotIn("provider_id: grok-bot", zapia)
        self.assertNotIn("provider_id: grok-bot", duet)

    def test_describe_matches_the_capability_table(self) -> None:
        surface = describe()
        self.assertEqual(surface["provider_id"], "grok-bot")
        self.assertEqual(surface["contract"], "v1")
        self.assertEqual(tuple(surface["operations"]), CONNECTOR_OPERATIONS)
        self.assertEqual(surface["capabilities"], list(CAPABILITIES))
        programmatic = {
            row["operation"]
            for row in surface["capabilities"]
            if row["programmatic"] == "yes"
        }
        self.assertEqual(programmatic, {"task.routine_webhook", "client.drift"})

    def test_published_evidence_is_sanitized(self) -> None:
        record = json.loads(EVIDENCE.read_text())
        text = json.dumps(record).lower()
        for token in ("bearer ", "authorization", "sk-", "/users/", "@", "api_key"):
            self.assertNotIn(token, text)
        self.assertEqual(record["provider_id"], "grok-bot")
        self.assertEqual(record["live_routine"], "not_sent")
        self.assertEqual(record["advertised_capabilities"], [])
        self.assertIn("installed_client", record)
        self.assertIn("release_feed", record)
        self.assertIsNone(record["quota_checkpoint"])


if __name__ == "__main__":
    unittest.main()

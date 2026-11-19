import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tachi.providers.dot.discovery import inspect_documents


ISSUER = {
    "issuer": "https://auth.openai.com",
    "scopes_supported": ["openid", "profile"],
    "code_challenge_methods_supported": ["S256"],
}


def schema(*methods):
    return {"oneOf": [{"properties": {"method": {"enum": [method]}}} for method in methods]}


class DotDiscoveryTests(unittest.TestCase):
    def test_public_declarations_do_not_attach_a_dot(self):
        report = inspect_documents(ISSUER, schema("thread/start", "account/login/start", "thread/start"))
        self.assertEqual(report, {
            "issuer_declares_openid": True,
            "issuer_declares_pkce_s256": True,
            "codex_method_count": 2,
            "codex_methods_present": ["account/login/start", "thread/start"],
            "dot_named_method_count": 0,
            "verified_dot_capabilities": [],
        })

    def test_future_names_are_counted_without_publishing_values_or_granting_access(self):
        issuer = dict(ISSUER, scopes_supported=["synthetic.scope"], code_challenge_methods_supported=[])
        report = inspect_documents(issuer, schema("synthetic/dot/example", "example/custom"))
        self.assertEqual(report["dot_named_method_count"], 1)
        self.assertFalse(report["issuer_declares_openid"])
        self.assertFalse(report["issuer_declares_pkce_s256"])
        self.assertEqual(report["verified_dot_capabilities"], [])
        self.assertNotIn("example", json.dumps(report))
        self.assertNotIn("synthetic", json.dumps(report))

    def test_unknown_input_formats_cannot_yield_a_negative_discovery(self):
        for document in (None, {}, {"oneOf": []}, {"oneOf": [{}]}, schema(""), schema(42)):
            with self.subTest(document=document), self.assertRaises(ValueError):
                inspect_documents(ISSUER, document)
        for issuer in ({}, dict(ISSUER, issuer="https://example.invalid"), dict(ISSUER, scopes_supported="openid")):
            with self.subTest(issuer=issuer), self.assertRaises(ValueError):
                inspect_documents(issuer, schema("initialize"))

    def test_cli_reads_local_files_and_reports_parse_errors_without_input_content(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "issuer.json"
            requests = Path(directory) / "schema.json"
            metadata.write_text(json.dumps(ISSUER))
            requests.write_text(json.dumps(schema("initialize")))
            command = [sys.executable, "-m", "tachi.providers.dot.discovery", metadata, requests]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout)["codex_method_count"], 1)
            requests.write_text("synthetic-invalid-json")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("synthetic-invalid-json", result.stderr)
            self.assertNotIn(directory, result.stderr)

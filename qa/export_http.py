"""Compare a complete human workspace export with each authorized HTTP projection."""

import base64
import hashlib

from artifact_http import ArtifactLab, MIB, new_id, upload


class WorkspaceExportCheck(ArtifactLab):
    owner_id = "synthetic-owner"
    author_id = "synthetic-author"
    reader_id = "synthetic-reader"

    def participants(self):
        scopes = ("sessions:read", "messages:send")
        self.owner = self.pair(self.owner_id, "owner", *scopes, "teams:manage")
        self.author = self.pair(self.author_id, "author", *scopes)
        self.reader = self.pair(self.reader_id, "reader", *scopes)
        self.workspace_path = self.workspace(self.owner)
        self.export = self.workspace_path + "/export"
        self.join(self.workspace_path, self.owner, self.author_id, self.author)
        self.join(self.workspace_path, self.owner, self.reader_id, self.reader)

    def message(self, text, direct=False):
        body = {"message_id": new_id(), "text": text}
        if direct:
            body["recipient_id"] = self.reader_id
        self.request("POST", self.workspace_path + "/messages", 201, token=self.author, payload=body)
        return body["message_id"]

    def document(self, data, direct=False):
        body = upload(data, fixture=True)
        if direct:
            body.update(audience="direct", recipient_id=self.reader_id)
        return self.check_upload(self.workspace_path, self.author, self.author_id, body, data)["artifact_id"]

    def complete(self, token, message_ids, documents):
        report = self.request("GET", self.export, 200, token=token)
        self.assertEqual(set(report), {"workspace_id", "messages", "artifacts"})
        self.assertEqual(report["workspace_id"], self.workspace_path.rsplit("/", 1)[1])
        history = self.request("GET", self.workspace_path + "/messages", 200, token=token)["messages"]
        self.assertEqual(report["messages"], history)
        self.assertEqual([row["message_id"] for row in history], message_ids)
        collection = self.workspace_path + "/artifacts"
        listing = self.request("GET", collection, 200, token=token)["artifacts"]
        self.assertEqual([row["artifact_id"] for row in listing], list(documents))
        self.assertEqual(len(report["artifacts"]), len(listing))
        for exported, meta in zip(report["artifacts"], listing):
            identifier = meta["artifact_id"]
            detail = self.request("GET", collection + "/" + identifier, 200, token=token)
            self.assertTrue(exported == detail, "Exported document differs from the authorized item GET")
            encoded = exported.pop("content_base64")
            self.assertEqual(exported, meta)
            self.assertTrue(base64.b64decode(encoded, validate=True) == documents[identifier], "Export bytes differ")
            self.assertEqual(meta["sha256"], hashlib.sha256(documents[identifier]).hexdigest())

    def limited(self, token):
        self.assertTrue(self.request("GET", self.export, 413, token=token) == {"error": "export_limit"},
                        "Unexpected limit response or partial export")

    def test_generation_scoped_export_and_credentials(self):
        with self.coordinator():
            self.participants()
            self.request("GET", self.export, 401)
            foreign = self.pair("synthetic-neighbor", "foreign", "sessions:read")
            self.request("GET", self.export, 404, token=foreign)
            sender = self.pair(self.reader_id, "sender", "messages:send")
            self.request("GET", self.export, 403, token=sender)
            sibling = self.pair(self.reader_id, "sibling", "sessions:read")
            client = self.request("GET", "/v1/client/me", 200, token=sibling)["clientID"]
            self.operator("revoke-client", self.reader_id, "--client-id", client)
            self.request("GET", self.export, 401, token=sibling)
            room, private = self.message("Public sample"), self.message("Private sample", direct=True)
            sample, note = b"Room\x00\xff", b"Reviewer\r\n"
            shared, direct = self.document(sample), self.document(note, direct=True)
            self.complete(self.owner, [room], {shared: sample})
            self.complete(self.reader, [room, private], {shared: sample, direct: note})
            self.request("POST", self.workspace_path + "/revocations", 200, token=self.owner,
                         payload={"recipient_id": self.reader_id})
            self.request("GET", self.export, 404, token=self.reader)

        with self.coordinator():
            self.join(self.workspace_path, self.owner, self.reader_id, self.reader)
            new_message = self.message("Fresh private sample", direct=True)
            fresh = self.document(b"New", direct=True)
            self.complete(self.reader, [room, new_message], {shared: sample, fresh: b"New"})
            self.complete(self.author, [room, private, new_message], {shared: sample, direct: note, fresh: b"New"})
            self.complete(self.owner, [room], {shared: sample})

    def test_message_limit_counts_visible_rows(self):
        with self.coordinator():
            self.participants()
            public = [self.message(f"Sample {i}") for i in range(100)]
            self.message("Private overflow", direct=True)
            self.complete(self.owner, public, {})
            self.limited(self.reader)
            self.message("Room overflow")
            self.limited(self.owner)

    def test_document_limit_counts_visible_items(self):
        with self.coordinator():
            self.participants()
            public = {self.document(b""): b"" for _ in range(16)}
            self.document(b"", direct=True)
            self.complete(self.owner, [], public)
            self.limited(self.reader)
            self.document(b"")
            self.limited(self.owner)

    def test_byte_limit_counts_visible_decoded_bytes(self):
        with self.coordinator():
            self.participants()
            public = {}
            for i in range(4):
                data = bytes([255 - i]) * MIB
                public[self.document(data)] = data
            self.document(b"X", direct=True)
            self.complete(self.owner, [], public)
            self.limited(self.reader)
            self.document(b"Y")
            self.limited(self.owner)

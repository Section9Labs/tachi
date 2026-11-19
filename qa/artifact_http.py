"""Verify immutable workspace uploads and membership-scoped retrieval over HTTP."""

import base64
from contextlib import closing
import hashlib
import uuid

from http_lab import CoordinatorLab


MIB = 1_048_576


def new_id():
    return str(uuid.uuid4())


def upload(data, **fields):
    return {"artifact_id": new_id(), "name": "sample.txt", "content_type": "text/plain",
            "content_base64": base64.b64encode(data).decode("ascii"), "audience": "room", **fields}


class ArtifactHTTPCheck(CoordinatorLab):
    def coordinator(self):
        return self.serve(self.service_command, "--db", self.database, cwd=self.service_root)

    def workspace(self, owner):
        workspace_id = new_id()
        self.request("POST", "/v1/workspaces", 201, token=owner, payload={"workspace_id": workspace_id})
        return "/v1/workspaces/" + workspace_id

    def join(self, path, owner, human, token):
        invitation = self.request("POST", path + "/invitations", 201, token=owner, payload={"recipient_id": human})
        self.request("POST", path + "/redeem", 200, token=token, payload=invitation)

    def store(self, workspace, token, body, status=201, *, escape_slashes=False):
        return self.request("POST", workspace + "/artifacts", status, token=token,
                            payload=body, escape_slashes=escape_slashes)

    def check_upload(self, workspace, token, author, body, data, *, escape_slashes=False):
        meta = {"artifact_id": body["artifact_id"], "name": body["name"], "content_type": body["content_type"],
                "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "audience": body["audience"],
                "recipient_id": body.get("recipient_id"), "author_id": author,
                "origin": "synthetic_fixture" if body.get("fixture") else "human_upload",
                "source_message_id": body.get("source_message_id"), "source_task_id": body.get("source_task_id")}
        self.assertTrue(self.store(workspace, token, body, escape_slashes=escape_slashes) == meta,
                        "upload returned unexpected metadata")
        return meta

    def check_content(self, workspace, token, meta, data):
        read = self.request("GET", workspace + "/artifacts/" + meta["artifact_id"], 200, token=token)
        encoded = read.pop("content_base64")
        self.assertTrue(read == meta, "metadata changed on retrieval")
        self.assertTrue(base64.b64decode(encoded, validate=True) == data, "retrieved bytes differ")
        self.assertTrue(encoded == base64.b64encode(data).decode("ascii"), "noncanonical response base64")

    def catalogue(self, workspace, token, expected):
        rows = self.request("GET", workspace + "/artifacts", 200, token=token)
        self.assertTrue(rows == {"artifacts": expected}, "unexpected artifact metadata, audience or order")

    def test_scoped_documents_survive_restart_and_rejoin(self):
        editor, reviewer, owner_id = "synthetic-editor", "synthetic-reviewer", "synthetic-owner"
        scopes = ("messages:send", "sessions:read")
        with self.coordinator():
            owner = self.pair(owner_id, "owner", *scopes, "teams:manage")
            author = self.pair(editor, "editor", *scopes)
            reader = self.pair(reviewer, "reviewer", *scopes)
            send_only = self.pair(editor, "send-only", "messages:send")
            read_only = self.pair(reviewer, "read-only", "sessions:read")
            workspace = self.workspace(owner)
            other = self.workspace(owner)
            self.join(workspace, owner, editor, author)
            self.join(workspace, owner, reviewer, reader)
            source = new_id()
            self.request("POST", workspace + "/messages", 201, token=author,
                         payload={"message_id": source, "text": "Please verify the sample.", "recipient_id": reviewer})
            sample = b"morning,56\r\nafternoon,39\r\n"
            shared = upload(sample, fixture=True)
            room = self.check_upload(workspace, author, editor, shared, sample)
            note = "Revisión — 95 checked in.\n".encode()
            direct = upload(note, fixture=True, audience="direct", recipient_id=reviewer, source_message_id=source)
            dm = self.check_upload(workspace, author, editor, direct, note)
            self.store(workspace, read_only, upload(note), 403)
            self.store(workspace, send_only, dict(direct, artifact_id=new_id()), 403)
            self.store(workspace, author, upload(note, source_message_id=source), 403)
            self.store(workspace, author, dict(direct, artifact_id=new_id(), recipient_id=owner_id), 403)
            self.store(workspace, owner, upload(note, source_message_id=source), 404)
            self.store(other, owner, upload(note, source_message_id=source), 404)
            self.store(workspace, owner, upload(note, artifact_id=dm["artifact_id"]), 404)
            self.request("GET", workspace + "/artifacts/" + dm["artifact_id"], 404, token=owner)
            self.request("GET", other + "/artifacts/" + room["artifact_id"], 404, token=owner)
            self.request("GET", other + "/artifacts", 404, token=author)
            self.check_upload(other, owner, owner_id, dict(shared, artifact_id=dm["artifact_id"]), sample)
            reviewed = upload(b"Reviewed.", fixture=True)
            own = self.check_upload(workspace, reader, reviewer, reviewed, b"Reviewed.")
            self.catalogue(workspace, owner, [room, own])
            self.catalogue(workspace, reader, [room, dm, own])
            self.check_content(workspace, reader, dm, note)

        with self.coordinator():
            self.check_content(workspace, reader, dm, note)
            self.check_content(workspace, author, room, sample)
            self.assertEqual(self.store(workspace, author, direct), dm)
            self.store(workspace, author, dict(direct, name="revised.txt"), 409)
            self.store(workspace, author, dict(direct, content_base64="WA=="), 409)
            self.request("POST", workspace + "/revocations", 200, token=owner, payload={"recipient_id": reviewer})
            self.request("GET", workspace + "/artifacts", 404, token=reader)
            self.join(workspace, owner, reviewer, reader)
            self.catalogue(workspace, read_only, [room, own])
            self.store(workspace, reader, reviewed, 409)
            self.check_content(workspace, reader, room, sample)
            self.request("GET", workspace + "/artifacts/" + dm["artifact_id"], 404, token=reader)
            self.store(workspace, reader, upload(note, artifact_id=dm["artifact_id"]), 404)
            self.store(workspace, author, dict(direct, artifact_id=new_id()), 403)
            self.check_content(workspace, author, dm, note)

    def test_trusted_room_task_source(self):
        from tachi.hosts import AccountStore
        from tachi.runtime import AdapterIdentity, Capability
        from tachi.runtime.queue import TeamQueue

        with self.coordinator():
            human = "synthetic-reviewer"
            token = self.pair(human, "reviewer", "sessions:read", "messages:send", "teams:manage")
            workspace = self.workspace(token)
            task = new_id()
            accounts = AccountStore(self.database)
            principal = accounts.authenticate(token)
            team = "workspace/" + workspace.rsplit("/", 1)[1]
            with closing(TeamQueue(self.database, accounts)) as queue:
                queue.add_assistant(team, principal, "lead", AdapterIdentity("reference", "fixture", "lead"), "sample")
                queue.create_run(team, principal, "sample", "assistant:lead", turn_limit=1)
                queue.post(team, principal, "sample", task, {"text": "fixture"}, capability=Capability.TASK)
            data = b"Fixture workpaper"
            meta = self.check_upload(workspace, token, human, upload(data, fixture=True, source_task_id=task), data)
            self.check_content(workspace, token, meta, data)
            self.store(workspace, token, upload(data, source_task_id=new_id()), 404)

    def test_decoded_byte_limit_and_replay_at_workspace_byte_quota(self):
        with self.coordinator():
            human = "synthetic-editor"
            token = self.pair(human, "editor", "sessions:read", "messages:send", "teams:manage")
            workspace = self.workspace(token)
            data = b"\xff" * MIB
            full = upload(data, name="sample.bin", content_type="application/octet-stream", fixture=True)
            meta = self.check_upload(workspace, token, human, full, data, escape_slashes=True)
            self.check_content(workspace, token, meta, data)
            self.store(workspace, token, upload(data + b"x", content_type="application/octet-stream"), 413)
        with self.coordinator():
            self.check_content(workspace, token, meta, data)
            for _ in range(63):
                self.store(workspace, token, dict(full, artifact_id=new_id()))
            self.assertEqual(self.store(workspace, token, full), meta)
            self.store(workspace, token, upload(b"x"), 413)

    def test_envelope_validation_and_replay_at_workspace_count_quota(self):
        with self.coordinator():
            human = "synthetic-editor"
            token = self.pair(human, "editor", "sessions:read", "messages:send", "teams:manage")
            workspace = self.workspace(token)
            empty = upload(b"", name="é" * 127 + "a", content_type="x/" + "z" * 125)
            meta = self.check_upload(workspace, token, human, empty, b"")
            self.check_content(workspace, token, meta, b"")
            for fields in ({"origin": "provider_result"}, {"author_id": human}, {"sha256": meta["sha256"]},
                           {"unknown": True}, {"content_base64": "YQ"}, {"content_base64": "YR=="},
                           {"name": "é" * 128}, {"name": ""}, {"name": "a/b"}, {"name": "a\\b"},
                           {"name": "a\nb"}, {"content_type": "x/" + "z" * 126},
                           {"content_type": "text/plain;charset=utf-8"}, {"content_type": "téxt/plain"},
                           {"audience": "direct"}, {"recipient_id": human},
                           {"source_task_id": new_id(), "source_message_id": new_id()}):
                self.store(workspace, token, dict(empty, artifact_id=new_id(), **fields), 400)
            self.catalogue(workspace, token, [meta])
            for _ in range(255):
                self.store(workspace, token, dict(empty, artifact_id=new_id()))
            self.assertEqual(self.store(workspace, token, empty), meta)
            self.store(workspace, token, dict(empty, artifact_id=new_id()), 413)

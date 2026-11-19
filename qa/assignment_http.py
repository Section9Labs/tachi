"""Workspace assignment acceptance through the shipping coordinator and a disposable webhook."""

from contextlib import closing
import json
import secrets
import sqlite3
from threading import Event
import time
import uuid

from solo_http import RoutineLab, routine_listener


class AssignmentHTTPCheck(RoutineLab):
    grantor = "synthetic-editor"
    sender = "synthetic-reviewer"
    alias = "sample-routine"
    path = "/fixture/workspace"
    scopes = ("sessions:read", "messages:send")
    consent = {"routine_id": alias, "allow_room_assignments": True}

    def start(self, options, *, staged=False):
        flags = ("--no-workspace-assignment-worker",) if staged else ()
        return self.serve(self.service_command, *options, *flags, cwd=self.service_root)

    def create_workspace(self):
        workspace_id = str(uuid.uuid4())
        self.request("POST", "/v1/workspaces", 201, token=self.owner, payload={"workspace_id": workspace_id})
        return "/v1/workspaces/" + workspace_id

    def join_sender(self, workspace):
        invitation = self.request("POST", workspace + "/invitations", 201, token=self.owner,
                                  payload={"recipient_id": self.sender})
        self.request("POST", workspace + "/redeem", 200, token=self.sibling, payload=invitation)

    def prepare(self):
        self.owner = self.pair(self.grantor, "grantor", *self.scopes, "teams:manage")
        self.owner_sibling = self.pair(self.grantor, "grantor-sibling", *self.scopes, "teams:manage")
        self.member = self.pair(self.sender, "sender", *self.scopes)
        self.sibling = self.pair(self.sender, "sender-sibling", *self.scopes)
        self.workspace = self.create_workspace()
        self.join_sender(self.workspace)
        self.bindings = self.workspace + "/assistants"
        self.assignments = self.workspace + "/assignments"
        self.request("GET", self.bindings, 401)
        self.request("POST", self.bindings, 403, token=self.member, payload=self.consent)
        for invalid in ({"routine_id": self.alias}, dict(self.consent, allow_room_assignments=False),
                        dict(self.consent, provider="grok-bot")):
            self.request("POST", self.bindings, 400, token=self.owner, payload=invalid)
        self.request("POST", self.bindings, 404, token=self.owner,
                     payload=dict(self.consent, routine_id="unavailable"))
        binding = self.request("POST", self.bindings, 201, token=self.owner, payload=self.consent)
        assistant = binding["assistant_id"]
        self.assertEqual(str(uuid.UUID(assistant)), assistant)
        self.assertTrue(binding == {"assistant_id": assistant, "provider": "grok-bot", "capabilities": ["task"],
                                    "native_session_observed": False}, "Unexpected public binding metadata")
        self.assertEqual(self.request("GET", self.bindings, 200, token=self.member), {"assistants": [binding]})
        self.binding = self.bindings + "/" + assistant
        self.body = {"assignment_id": str(uuid.uuid4()), "assistant_id": assistant, "text": "Count two sample rows."}
        self.detail = self.assignments + "/" + self.body["assignment_id"]

    def snapshot(self, state, body=None):
        return dict(body or self.body, author_id=self.sender, state=state, result=None, native_result_available=False)

    def settle(self, state, token, *, body=None, assignments=None):
        body = self.body if body is None else body
        detail = (assignments or self.assignments) + "/" + body["assignment_id"]
        deadline = time.monotonic() + 15
        while True:
            row = self.request("GET", detail, 200, token=token)
            if row == self.snapshot(state, body):
                return row
            self.assertIn(row, [self.snapshot("queued", body), self.snapshot("uncertain", body)])
            if time.monotonic() >= deadline:
                self.fail(f"Assignment did not reach {state}")
            time.sleep(0.05)

    def revoke_binding(self):
        self.assertEqual(self.request("POST", self.binding + "/revoke", 200, token=self.owner_sibling, payload={}),
                         {"revoked": True})

    def check_control(self, action, token, paused):
        method, payload = ("GET", None) if action == "dispatch" else ("POST", {})
        response = self.request(method, self.binding + "/" + action, 200, token=token, payload=payload)
        self.assertEqual(response, {"assistant_id": self.body["assistant_id"], "dispatch_paused": paused})
        self.assertIs(response["dispatch_paused"], paused)

    def check_events(self, kinds):
        with closing(sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True)) as db:
            events = db.execute("SELECT kind, payload FROM rt_event ORDER BY seq").fetchall()
        self.assertEqual([kind for kind, _ in events], kinds)
        if kinds == ["accepted"]:
            self.assertEqual(json.loads(events[0][1]), {"routine_accepted": True, "native_reply": False,
                                                       "native_session_observed": False})

    def observe_delivery(self, status, state):
        release_reply = Event()
        with routine_listener(self.path, status, hold_reply=release_reply) as (url, secret, observed, posted):
            options = self.service_options(self.grantor, self.alias, url, secret)
            with self.start(options, staged=True):
                self.prepare()
                foreign = self.pair("synthetic-neighbor", "foreign", *self.scopes)
                reader = self.pair(self.sender, "reader", "sessions:read")
                self.request("GET", self.assignments, 404, token=foreign)
                self.request("POST", self.assignments, 403, token=reader, payload=self.body)
                self.assertEqual(self.request("POST", self.assignments, 202, token=self.member, payload=self.body),
                                 self.snapshot("queued"))
                successor = dict(self.body, assignment_id=str(uuid.uuid4()), text="Count the next sample.")
                self.request("POST", self.assignments, 202, token=self.member, payload=successor)
                self.assertFalse(observed())

            expected_post = [(self.path, True, {"text": self.body["text"]})]
            with self.start(options):
                try:
                    self.assertTrue(posted.wait(15), "Routine did not receive the assignment")
                    self.check_control("pause", self.owner_sibling, True)
                    self.assertEqual(observed(), expected_post)
                finally:
                    release_reply.set()
                self.settle(state, self.owner_sibling)
            with self.start(options):
                self.check_control("dispatch", self.member, True)
                self.assertEqual(self.request("GET", self.detail, 200, token=self.sibling), self.snapshot(state))
                self.check_control("resume", self.owner, False)
                self.assertEqual(self.request("POST", self.assignments, 202, token=self.sibling, payload=self.body),
                                 self.snapshot(state))
                self.request("POST", self.assignments, 409, token=self.member, payload=dict(self.body, text="Changed"))
                rows = self.request("GET", self.assignments, 200, token=self.member)["assignments"]
                self.assertCountEqual(rows, [self.snapshot(state), self.snapshot("queued", successor)])
            self.check_events(["accepted"] if status == 200 else [])
            with self.start(options):
                self.revoke_binding()
                self.assertEqual(self.request("GET", self.detail, 200, token=self.sibling), self.snapshot(state))
            self.assertEqual(observed(), expected_post)

    def test_receipt_holds_lane_across_restart(self):
        self.observe_delivery(200, "active")

    def test_lost_response_holds_lane_across_restart(self):
        self.observe_delivery(None, "uncertain")

    def test_paused_binding_survives_restart_while_another_workspace_dispatches(self):
        with routine_listener(self.path, 200) as (url, secret, observed, _):
            options = self.service_options(self.grantor, self.alias, url, secret)
            with self.start(options):
                self.prepare()
                other = self.create_workspace()
                self.join_sender(other)
                binding = self.request("POST", other + "/assistants", 201, token=self.owner, payload=self.consent)
                self.assertNotEqual(binding["assistant_id"], self.body["assistant_id"])
                independent = {"assignment_id": str(uuid.uuid4()), "assistant_id": binding["assistant_id"],
                               "text": "Check the independent workspace."}
                eligible = dict(self.body, assignment_id=str(uuid.uuid4()), text="Check the eligible sample.")
                self.check_control("dispatch", self.sibling, False)
                self.check_control("pause", self.owner, True)
                self.check_control("pause", self.owner_sibling, True)
                for token, body in ((self.member, self.body), (self.sibling, eligible)):
                    self.assertEqual(self.request("POST", self.assignments, 202, token=token, payload=body),
                                     self.snapshot("queued", body))
                self.assertEqual(observed(), [])

            with self.start(options):
                self.check_control("dispatch", self.sibling, True)
                self.request("POST", other + "/assignments", 202, token=self.sibling, payload=independent)
                self.settle("active", self.sibling, body=independent, assignments=other + "/assignments")
                first_post = (self.path, True, {"text": independent["text"]})
                self.assertEqual(observed(), [first_post])
                self.assertCountEqual(self.request("GET", self.assignments, 200, token=self.owner)["assignments"],
                                      [self.snapshot("queued"), self.snapshot("queued", eligible)])
                origin = self.request("GET", "/v1/client/me", 200, token=self.member)["clientID"]
                self.operator("revoke-client", self.sender, "--client-id", origin)
                self.request("GET", self.binding + "/dispatch", 401, token=self.member)
                self.assertEqual(self.request("POST", self.assignments, 202, token=self.sibling, payload=self.body),
                                 self.snapshot("queued"))
                self.check_control("resume", self.owner_sibling, False)
                self.settle("denied", self.sibling)
                self.settle("active", self.sibling, body=eligible)
                self.check_control("resume", self.owner, False)
                expected = [first_post, (self.path, True, {"text": eligible["text"]})]
                self.assertEqual(observed(), expected)

            with self.start(options):
                self.check_control("dispatch", self.sibling, False)
                for body, state in ((self.body, "denied"), (eligible, "active")):
                    self.assertEqual(self.request("POST", self.assignments, 202, token=self.sibling, payload=body),
                                     self.snapshot(state, body))
                self.settle("active", self.sibling, body=independent, assignments=other + "/assignments")
            self.assertEqual(observed(), expected)

    def test_dispatch_control_authority_and_binding_scope(self):
        with routine_listener(self.path, 200) as (url, secret, observed, _):
            with self.start(self.service_options(self.grantor, self.alias, url, secret)):
                self.prepare()
                member = self.pair(self.sender, "scoped-member", *self.scopes, "teams:manage")
                reader = self.pair(self.grantor, "read-only-owner", "sessions:read")
                manager = self.pair(self.grantor, "manage-only-owner", "teams:manage")
                foreign = self.pair("synthetic-outsider", "outsider", *self.scopes, "teams:manage")
                other = self.create_workspace()
                mismatched = other + "/assistants/" + self.body["assistant_id"]
                unknown = self.bindings + "/" + str(uuid.uuid4())
                self.check_control("dispatch", reader, False)
                self.request("GET", self.binding + "/dispatch", 403, token=manager)
                for action, method, payload in (("dispatch", "GET", None), ("pause", "POST", {}), ("resume", "POST", {})):
                    self.request(method, self.binding + "/" + action, 401, payload=payload)
                    self.request(method, self.binding + "/" + action, 404, token=foreign, payload=payload)
                    for path in (mismatched, unknown):
                        self.request(method, path + "/" + action, 404, token=self.owner, payload=payload)
                for action, paused in (("pause", True), ("resume", False)):
                    for token in (member, reader):
                        self.request("POST", self.binding + "/" + action, 403, token=token, payload={})
                    self.request("POST", self.binding + "/" + action, 400, token=self.owner, payload={"force": True})
                    self.check_control("dispatch", member, not paused)
                    self.check_control(action, manager, paused)
                self.revoke_binding()
                self.request("GET", self.binding + "/dispatch", 404, token=reader)
                for action in ("pause", "resume"):
                    self.request("POST", self.binding + "/" + action, 404, token=manager, payload={})
            self.assertEqual(observed(), [])

    def test_observed_503_remains_failed_after_sibling_retry(self):
        with routine_listener(self.path, 503) as (url, secret, observed, posted):
            options = self.service_options(self.grantor, self.alias, url, secret)
            database = self.database.as_uri() + "?mode=ro"
            with self.start(options, staged=True):
                self.prepare()
                origin = self.request("GET", "/v1/client/me", 200, token=self.member)["clientID"]
                self.assertEqual(self.request("POST", self.assignments, 202, token=self.member, payload=self.body),
                                 self.snapshot("queued"))
            with closing(sqlite3.connect(database, uri=True)) as db:
                (request_id,) = db.execute("SELECT request FROM rt_delivery").fetchone()
            self.assertNotEqual(request_id, self.body["assignment_id"])

            with self.start(options):
                self.assertTrue(posted.wait(15), "Routine did not receive the assignment")
                self.settle("failed", self.member)
            with self.start(options):
                self.assertEqual(self.request("GET", self.detail, 200, token=self.sibling), self.snapshot("failed"))
                self.assertEqual(self.request("POST", self.assignments, 202, token=self.sibling, payload=self.body),
                                 self.snapshot("failed"))
                self.request("POST", self.assignments, 409, token=self.sibling, payload=dict(self.body, text="Changed"))

            self.assertEqual(observed(), [(self.path, True, {"text": self.body["text"]})])
            with closing(sqlite3.connect(database, uri=True)) as db:
                deliveries = db.execute("SELECT m.message, m.human, m.client, d.request, d.state "
                                        "FROM rt_message m JOIN rt_delivery d USING(team, message)").fetchall()
                events = db.execute("SELECT request, kind, payload FROM rt_event").fetchall()
            self.assertEqual(deliveries, [(self.body["assignment_id"], self.sender, origin, request_id, "failed")])
            self.assertEqual([(req, kind, json.loads(payload)) for req, kind, payload in events],
                             [(request_id, "failed", {"reason": "rejected", "status": 503})])

    def queued_denial(self, reason):
        with routine_listener(self.path, 200) as (url, secret, observed, _):
            options = self.service_options(self.grantor, self.alias, url, secret)
            with self.start(options, staged=True):
                self.prepare()
                self.assertEqual(self.request("POST", self.assignments, 202, token=self.member, payload=self.body),
                                 self.snapshot("queued"))
                if reason == "binding":
                    self.revoke_binding()
                elif reason == "membership":
                    self.request("POST", self.workspace + "/revocations", 200, token=self.owner,
                                 payload={"recipient_id": self.sender})
                    self.join_sender(self.workspace)
                elif reason == "rotation":
                    options = self.service_options(self.grantor, self.alias, url, secrets.token_urlsafe(32),
                                                   filename="rotated.json")
                elif reason == "removal":
                    options = ("--db", self.database)
                else:
                    principal, token = (self.grantor, self.owner) if reason == "grantor" else (self.sender, self.member)
                    client = self.request("GET", "/v1/client/me", 200, token=token)["clientID"]
                    self.operator("revoke-client", principal, "--client-id", client)
                    # A replay by a still-authorized member sibling must keep the original delivery authority.
                    self.assertEqual(self.request("POST", self.assignments, 202, token=self.sibling,
                                                  payload=self.body), self.snapshot("queued"))
                self.assertFalse(observed())
            with self.start(options):
                self.settle("denied", self.owner_sibling)
            self.assertFalse(observed(), "Stale assignment authority reached the routine")

    def test_binding_revoked_before_claim(self):
        self.queued_denial("binding")

    def test_sender_device_revoked_before_claim(self):
        self.queued_denial("sender")

    def test_grantor_device_revoked_before_claim(self):
        self.queued_denial("grantor")

    def test_sender_rejoins_before_claim(self):
        self.queued_denial("membership")

    def test_grant_rotated_before_claim(self):
        self.queued_denial("rotation")

    def test_grant_removed_before_claim(self):
        self.queued_denial("removal")

"""Check human ownership and per-client revocation over real reference-team HTTP."""

import time
import unittest

from http_lab import DisposableCoordinator


class ReferenceTeamCheck(DisposableCoordinator):
    server_options = ("--reference-teams",)

    def pair(self, human, label, scopes):
        invitation_file = self.directory / label
        scope_args = [arg for scope in scopes for arg in ("--scope", scope)]
        self.operator("invite-client", human, *scope_args, "--out", invitation_file)
        return self.request("POST", "/v1/client/pair", 201,
                            payload={"invitation": invitation_file.read_text().strip()})

    def test_shared_team_and_revoked_pending_turn(self):
        human = "synthetic-editor"
        scopes = ("teams:manage", "messages:send", "sessions:read")
        origin = self.pair(human, "origin", scopes)
        sibling = self.pair(human, "sibling", scopes)["token"]
        reader = self.pair(human, "reader", ("sessions:read",))["token"]
        other = self.pair("synthetic-neighbor", "other", scopes)["token"]
        teams = "/v1/reference-teams"
        summary = self.request("POST", teams, 200, token=origin["token"],
                               payload={"creationID": "hall", "turnLimit": 4})
        self.assertEqual(summary["mode"], "reference")
        self.assertEqual(summary["assistants"], ["lead", "peer"])
        team = teams + "/" + summary["teamID"]
        messages, run = team + "/messages", team + "/run"
        for token in (sibling, reader):
            self.assertEqual(self.request("GET", teams, 200, token=token)["teams"], [summary])
        self.assertEqual(self.request("GET", teams, 200, token=other)["teams"], [])
        self.request("GET", team, 404, token=other)

        paused = self.request("POST", run, 200, token=sibling, payload={"state": "paused"})
        self.assertEqual(paused["runState"], "paused")
        draft = {"messageID": "draft", "text": "Check the workshop count.", "audience": "lead"}
        edit = {"messageID": "edit", "text": "Show both counts.", "audience": "peer"}
        self.request("POST", messages, 403, token=reader, payload=draft)
        self.request("POST", messages, 200, token=origin["token"], payload=draft)
        self.request("POST", messages, 200, token=sibling, payload=edit)
        pending = self.request("GET", messages, 200, token=sibling)["messages"]
        self.assertEqual([(m["messageID"], m["deliveries"][0]["state"]) for m in pending],
                         [("draft", "queued"), ("edit", "queued")])

        self.operator("revoke-client", human, "--client-id", origin["clientID"])
        self.request("GET", team, 401, token=origin["token"])
        self.request("POST", run, 200, token=sibling, payload={"state": "running"})
        deadline = time.monotonic() + 10
        while True:
            rows = self.request("GET", messages, 200, token=sibling)["messages"]
            self.assertEqual([m["messageID"] for m in rows], ["draft", "edit"])
            deliveries = [m["deliveries"][0] for m in rows]
            states = [delivery["state"] for delivery in deliveries]
            if states == ["denied", "completed"]:
                break
            if time.monotonic() >= deadline:
                self.fail(f"reference deliveries did not settle as expected: {states}")
            time.sleep(0.05)
        self.assertIsNone(deliveries[0]["result"])
        self.assertEqual(deliveries[1]["assistant"], "peer")
        self.assertTrue(isinstance(deliveries[1]["result"], str) and deliveries[1]["result"])
        self.assertEqual(self.request("GET", messages, 200, token=reader)["messages"], rows)


if __name__ == "__main__":
    unittest.main()

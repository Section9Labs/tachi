"""Exercise two human memberships and room/DM history over authenticated HTTP."""

import uuid

from http_lab import CoordinatorLab


class WorkspaceHTTPCheck(CoordinatorLab):
    root = "/v1/workspaces"

    def post(self, token, message):
        body = {key: message[key] for key in ("message_id", "text")}
        if message["recipient_id"] is not None:
            body["recipient_id"] = message["recipient_id"]
        result = self.request("POST", self.messages, 201, token=token, payload=body)
        self.assertEqual(result, {"message_id": message["message_id"]})
        return body

    def history(self, token, rows):
        self.assertEqual(self.request("GET", self.messages, 200, token=token), {"messages": rows})

    @staticmethod
    def message(author, text, to=None):
        return {"message_id": str(uuid.uuid4()), "author_id": author, "recipient_id": to, "text": text}

    def test_revoked_member_rejoins_with_new_private_history(self):
        owner_id, member_id = "synthetic-editor", "synthetic-reviewer"
        scope = ("teams:manage", "messages:send", "sessions:read")
        workspace = {"workspace_id": str(uuid.uuid4())}
        path = self.root + "/" + workspace["workspace_id"]
        self.messages = path + "/messages"
        recipient = {"recipient_id": member_id}

        def catalogue(token, roles):
            self.assertEqual(self.request("GET", self.root, 200, token=token),
                             {"workspaces": [dict(workspace, role=role) for role in roles]})

        def invite():
            reply = self.request("POST", path + "/invitations", 201, token=owner, payload=recipient)
            self.assertTrue(set(reply) == {"invitation"} and isinstance(reply["invitation"], str)
                            and bool(reply["invitation"]), "missing workspace invitation")
            return reply

        def revoke():
            self.assertEqual(self.request("POST", path + "/revocations", 200, token=owner,
                                          payload=recipient), {"revoked": True})

        def redeem(token, invitation, status):
            reply = self.request("POST", path + "/redeem", status, token=token, payload=invitation)
            if status == 200:
                self.assertEqual(reply, dict(workspace, role="member"))

        options = ("--db", self.database)
        with self.serve(self.service_command, *options, cwd=self.service_root):
            owner = self.pair(owner_id, "owner", *scope)
            member = self.pair(member_id, "member", *scope)
            reader = self.pair(member_id, "read-only-sibling", "sessions:read")
            self.request("GET", self.root, 401, token="synthetic-invalid")
            for _ in range(2):
                self.assertEqual(self.request("POST", self.root, 201, token=owner, payload=workspace),
                                 dict(workspace, role="owner"))
            catalogue(owner, ["owner"])
            catalogue(member, [])
            self.request("GET", self.messages, 404, token=member)
            first_invite = invite()
            redeem(owner, first_invite, 403)
            redeem(member, first_invite, 200)
            redeem(member, first_invite, 403)
            catalogue(reader, ["member"])
            self.request("POST", path + "/invitations", 403, token=member,
                         payload={"recipient_id": owner_id})
            room = self.message(owner_id, "Workshop draft is ready.")
            room_body = self.post(owner, room)
            self.post(owner, room)
            self.request("POST", self.messages, 409, token=owner, payload=dict(room_body, text="Changed."))
            self.request("POST", self.messages, 403, token=reader,
                         payload={"message_id": str(uuid.uuid4()), "text": "Read-only draft."})
            old_out = self.message(owner_id, "Please check the draft count.", member_id)
            old_in = self.message(member_id, "Checking the draft.", owner_id)
            self.post(owner, old_out)
            self.post(member, old_in)
            self.history(reader, [room, old_out, old_in])
            self.history(owner, [room, old_out, old_in])
            revoke()
            catalogue(member, [])
            self.request("GET", self.messages, 404, token=reader)
            self.request("POST", self.messages, 404, token=member,
                         payload={"message_id": str(uuid.uuid4()), "text": "Removed member."})
            later = self.message(owner_id, "Revised workshop brief.")
            self.post(owner, later)
            withdrawn = invite()
            revoke()
            redeem(member, withdrawn, 403)
            self.history(owner, [room, old_out, old_in, later])
            fresh = invite()

        with self.serve(self.service_command, *options, cwd=self.service_root):
            catalogue(reader, [])
            redeem(member, fresh, 200)
            catalogue(member, ["member"])
            self.history(member, [room, later])
            self.history(reader, [room, later])
            new_out = self.message(owner_id, "Check the revised brief.", member_id)
            new_in = self.message(member_id, "Checked the revised brief.", owner_id)
            self.post(owner, new_out)
            self.post(member, new_in)
            self.history(reader, [room, later, new_out, new_in])

        with self.serve(self.service_command, *options, cwd=self.service_root):
            catalogue(member, ["member"])
            self.history(member, [room, later, new_out, new_in])
            self.history(owner, [room, old_out, old_in, later, new_out, new_in])

    def test_owner_cannot_read_other_members_dm(self):
        owner_id = "synthetic-owner"
        first_id, second_id = "synthetic-reader", "synthetic-editor"
        with self.serve(self.service_command, "--db", self.database, cwd=self.service_root):
            owner = self.pair(owner_id, "owner", "sessions:read", "messages:send", "teams:manage")
            workspace = {"workspace_id": str(uuid.uuid4())}
            self.request("POST", self.root, 201, token=owner, payload=workspace)
            path = self.root + "/" + workspace["workspace_id"]
            self.messages = path + "/messages"
            members = []
            for human in (first_id, second_id):
                token = self.pair(human, human, "sessions:read", "messages:send")
                invitation = self.request("POST", path + "/invitations", 201, token=owner,
                                          payload={"recipient_id": human})
                joined = self.request("POST", path + "/redeem", 200, token=token, payload=invitation)
                self.assertEqual(joined, dict(workspace, role="member"))
                members.append(token)

            first, second = members
            room = self.message(owner_id, "Editorial room is open.")
            private = self.message(first_id, "Review the sample count.", second_id)
            self.post(owner, room)
            self.post(first, private)
            self.history(first, [room, private])
            self.history(second, [room, private])
            self.history(owner, [room])

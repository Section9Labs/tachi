import Foundation

public struct TeamMembership: Sendable {
    public let role: String
    public let membershipID: String
}

extension AccountStore {
    static let teamSchema = """
        CREATE TABLE IF NOT EXISTS account_team_members (
            team_id TEXT NOT NULL, human_id TEXT NOT NULL, membership_id TEXT UNIQUE NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('owner','member')), PRIMARY KEY(team_id,human_id)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS account_team_owner ON account_team_members(team_id) WHERE role='owner';
        CREATE TABLE IF NOT EXISTS account_team_invitations (
            digest BLOB PRIMARY KEY NOT NULL, team_id TEXT NOT NULL, recipient_id TEXT NOT NULL,
            issuer_client TEXT NOT NULL REFERENCES account_clients(client_id) ON DELETE CASCADE,
            issuer_membership TEXT NOT NULL REFERENCES account_team_members(membership_id) ON DELETE CASCADE,
            expires_at REAL NOT NULL, UNIQUE(team_id,recipient_id)
        );
        """

    public func createTeam(humanID: String, clientID: String, teamID: String) throws {
        try identifier(teamID)
        try Database(path).write { db in
            guard try clientScopes(db, humanID, clientID).contains("teams:manage") else { throw AccountsError.denied }
            try requireChange(db.run("""
                INSERT INTO account_team_members (team_id,human_id,membership_id,role)
                SELECT ?,?,?,'owner' WHERE NOT EXISTS (SELECT 1 FROM account_team_members WHERE team_id=?)
                """, [.text(teamID), .text(humanID), .text(newID()), .text(teamID)]))
        }
    }

    public func teamMembership(teamID: String, humanID: String) throws -> TeamMembership? {
        try identifier(teamID)
        try identifier(humanID)
        guard let row = try Database(path).rows("""
            SELECT role, membership_id FROM account_team_members WHERE team_id=? AND human_id=?
            """, [.text(teamID), .text(humanID)]).first else { return nil }
        return try TeamMembership(role: row[0].string(), membershipID: row[1].string())
    }

    public func teamRole(teamID: String, humanID: String) throws -> String? {
        try teamMembership(teamID: teamID, humanID: humanID)?.role
    }

    private func authorized(_ db: Database, humanID: String, clientID: String, teamID: String,
                            scope: String, membershipID: String? = nil) throws -> TeamMembership {
        try identifier(humanID)
        try identifier(clientID)
        try identifier(teamID)
        guard let row = try db.rows("""
            SELECT m.role,m.membership_id,c.scopes FROM account_team_members m JOIN account_clients c USING (human_id)
            WHERE m.human_id=? AND c.client_id=? AND m.team_id=?
            """, [.text(humanID), .text(clientID), .text(teamID)]).first,
              try Self.scopes(row[2]).contains(scope) else { throw AccountsError.denied }
        let member = try TeamMembership(role: row[0].string(), membershipID: row[1].string())
        guard member.role == "owner" || (member.role == "member" && scope != "teams:manage") else {
            throw AccountsError.denied
        }
        if let membershipID, !membershipID.utf8.elementsEqual(member.membershipID.utf8) { throw AccountsError.denied }
        return member
    }

    public func authorizeMembership(humanID: String, clientID: String, teamID: String, scope: String,
                                    membershipID: String? = nil) throws -> TeamMembership {
        try authorized(Database(path), humanID: humanID, clientID: clientID, teamID: teamID,
                       scope: scope, membershipID: membershipID)
    }

    public func authorizeTeam(humanID: String, clientID: String, teamID: String, scope: String) throws -> String {
        try authorizeMembership(humanID: humanID, clientID: clientID, teamID: teamID, scope: scope).role
    }

    public func inviteMember(humanID: String, clientID: String, teamID: String, recipientID: String) throws -> String {
        try identifier(recipientID)
        return try Database(path).write { db in
            let owner = try authorized(db, humanID: humanID, clientID: clientID, teamID: teamID, scope: "teams:manage")
            let now = clock()
            try db.run("DELETE FROM account_team_invitations WHERE expires_at <= ?", [.number(now)])
            let invitation = newSecret()
            try requireChange(db.run("""
                INSERT INTO account_team_invitations (digest,team_id,recipient_id,issuer_client,issuer_membership,expires_at)
                SELECT ?,?,?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM account_team_members WHERE team_id=? AND human_id=?)
                ON CONFLICT(team_id,recipient_id) DO UPDATE SET digest=excluded.digest, issuer_client=excluded.issuer_client,
                    issuer_membership=excluded.issuer_membership, expires_at=excluded.expires_at
                """, [try digest(invitation), .text(teamID), .text(recipientID), .text(clientID),
                      .text(owner.membershipID), .number(now + 300), .text(teamID), .text(recipientID)]))
            return invitation
        }
    }

    public func acceptInvitation(humanID: String, clientID: String, invitation: String) throws -> TeamMembership {
        let key = try digest(invitation)
        return try Database(path).write { db in
            _ = try clientScopes(db, humanID, clientID)
            let member = TeamMembership(role: "member", membershipID: newID())
            try requireChange(db.run("""
                INSERT INTO account_team_members (team_id,human_id,membership_id,role)
                SELECT team_id,recipient_id,?,'member' FROM account_team_invitations
                WHERE digest=? AND recipient_id=? AND expires_at>?
                """, [.text(member.membershipID), key, .text(humanID), .number(clock())]))
            try db.run("DELETE FROM account_team_invitations WHERE digest=?", [key])
            return member
        }
    }

    public func revokeMember(humanID: String, clientID: String, teamID: String, recipientID: String) throws {
        try identifier(recipientID)
        try Database(path).write { db in
            _ = try authorized(db, humanID: humanID, clientID: clientID, teamID: teamID, scope: "teams:manage")
            let ids: [Value] = [.text(teamID), .text(recipientID)]
            let invites = try db.run("DELETE FROM account_team_invitations WHERE team_id=? AND recipient_id=?", ids)
            let members = try db.run("DELETE FROM account_team_members WHERE team_id=? AND human_id=? AND role='member'", ids)
            guard invites > 0 || members > 0 else { throw AccountsError.denied }
        }
    }
}

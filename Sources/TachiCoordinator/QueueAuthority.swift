import TachiAccounts
import TachiRuntime

/// Keep operational storage failures distinguishable from a revoked grant.
private func checkingAccountPolicy<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch AccountsError.denied { throw QueueError.denied }
}

struct CoordinatorAuthority: QueueAuthority {
    let accounts: AccountStore

    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        try checkingAccountPolicy {
            try accounts.authorizeMembership(humanID: principal.humanID, clientID: principal.clientID,
                                            teamID: team, scope: scope, membershipID: membershipID).membershipID
        }
    }

    func membershipID(team: String, humanID: String) throws -> String? {
        try checkingAccountPolicy { try accounts.teamMembership(teamID: team, humanID: humanID)?.membershipID }
    }
}

extension HostWorker {
    init(store: HostStore, session: HostSession) {
        self.init(hostID: session.hostID) { scope in
            try checkingAccountPolicy {
                try store.authorize(ownerID: scope.ownerID, session: session, grantID: scope.grantID,
                                    folderID: scope.folderID, action: scope.action, relativePath: scope.relativePath)
            }
        }
    }
}

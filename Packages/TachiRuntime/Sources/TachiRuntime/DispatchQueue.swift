import Foundation

extension TeamQueue {
    private func claim(team: String?, host: String?, referenceOnly: Bool, workspaceOnly: Bool) throws -> Row? {
        // Keep reference workers away from native bindings, even within a shared SQLite database.
        let referenceFilter = referenceOnly ? """
            AND m.run='assignment' AND a.provider='tachi-reference' AND a.account=d.team
            AND a.assistant IN ('lead','peer') AND a.member='assistant:' || a.assistant
            AND EXISTS (SELECT 1 FROM rt_reference_team t WHERE t.team=d.team AND t.ready=1)
            """ : ""
        // A workspace routine can be claimed only by the worker that rechecks its separate owner grant.
        let bindingFilter = !workspaceOnly ? """
            AND NOT EXISTS (SELECT 1 FROM rt_workspace_binding b WHERE b.team=d.team AND b.member=d.target)
            """ : """
            AND EXISTS (SELECT 1 FROM rt_workspace_binding b WHERE b.team=d.team AND b.member=d.target
                        AND b.binding=m.run AND b.enabled=1)
            """
        let select = """
            SELECT d.request,d.target,m.*,a.provider,a.account,a.assistant,a.session
            FROM rt_delivery d JOIN rt_message m USING(team,message)
            JOIN rt_assistant a ON a.team=d.team AND a.member=d.target
            JOIN rt_run r ON r.team=m.team AND r.run=m.run
            WHERE d.state='queued' AND d.host IS ? AND (? IS NULL OR d.team=?)
            \(referenceFilter)
            \(bindingFilter)
            AND (d.host IS NULL OR a.provider<>'tachi-folder')
            AND r.state='running' AND r.turns<r.turn_limit AND NOT EXISTS (
                SELECT 1 FROM rt_delivery prev WHERE prev.team=d.team AND prev.target=d.target
                AND prev.seq<d.seq AND prev.state IN ('queued','uncertain','active','blocked')
            ) ORDER BY d.seq LIMIT 1
            """
        let arguments = [host, team, team]
        // Idle workers (including a lane held by a receipt) need no SQLite writer lock.
        if workspaceOnly, try db.query(select, arguments).isEmpty { return nil }
        return try db.transaction {
            guard let row = try db.query(select, arguments).first else { return nil }
            // Persist ambiguity before leaving SQLite. A process exit from here on cannot authorize replay.
            try db.query("UPDATE rt_delivery SET state='uncertain',reason=NULL WHERE request=?", [row.required("request")])
            try db.query("UPDATE rt_run SET turns=turns+1 WHERE team=? AND run=?", [row.required("team"), row.required("run")])
            return row
        }
    }

    private func notSubmitted(_ row: Row, state: String, reason: String) throws -> String {
        try db.transaction {
            let team = try row.required("team"), run = try row.required("run"), request = try row.required("request")
            let next = try runInfo(team, run).state.terminal ? "cancelled" : state
            try db.query("UPDATE rt_delivery SET state=?,reason=? WHERE request=? AND state='uncertain'", [next, reason, request])
            try db.query("UPDATE rt_run SET turns=turns-1 WHERE team=? AND run=? AND changes()=1", [team, run])
            return request
        }
    }

    public func dispatchOne(registry: AdapterRegistry, teamID: String? = nil, host: HostWorker? = nil) async throws -> String? {
        try await dispatchOne(registry: registry, teamID: teamID, host: host, referenceOnly: false)
    }

    public func dispatchWorkspaceAssignment(registry: AdapterRegistry,
                                            lookup: @escaping WorkspaceRoutineLookup) async throws -> String? {
        try await dispatchOne(registry: registry, teamID: nil, host: nil, referenceOnly: false, lookup: lookup)
    }

    func dispatchOne(registry: AdapterRegistry, teamID: String?, host: HostWorker?, referenceOnly: Bool,
                     lookup: WorkspaceRoutineLookup? = nil) async throws -> String? {
        guard let row = try claim(team: teamID, host: host?.hostID, referenceOnly: referenceOnly, workspaceOnly: lookup != nil) else { return nil }
        let identity = try row.nativeIdentity(), requestID = try row.required("request")
        guard let capability = try Capability(rawValue: row.required("capability")) else { throw QueueError.corruptStore }
        let origin = try QueuePrincipal(humanID: row.required("human"), clientID: row.required("client"))
        let capabilities: Set<Capability>?
        do { capabilities = try await registry.capabilities(for: identity) }
        catch RuntimeError.unknownIdentity { capabilities = nil }
        if let lookup {
            // Accounts and binding revocation use this database. Check both principals and the destination
            // in one transaction after registry preflight, immediately before the irreversible submission.
            let denial: String? = try db.transaction {
                do { try authorize(origin, row.required("team"), "messages:send", generation: row.required("membership")) }
                catch QueueError.denied { return "origin_denied" }
                guard let binding = try db.query("SELECT * FROM rt_workspace_binding WHERE binding=?", [row.required("run")]).first
                else { return "grant_denied" }
                do {
                    return try checkGrant(binding, lookup: lookup).identity == identity ? nil : "grant_denied"
                } catch QueueError.denied { return "grant_denied" }
            }
            if let denial { return try notSubmitted(row, state: "denied", reason: denial) }
        } else {
            do { try authorize(origin, row.required("team"), "messages:send", generation: row.required("membership")) }
            catch QueueError.denied { return try notSubmitted(row, state: "denied", reason: "origin_denied") }
        }
        guard let capabilities else { return try notSubmitted(row, state: "blocked", reason: "adapter_unavailable") }
        guard capabilities.contains(capability) else { return try notSubmitted(row, state: "blocked", reason: "unsupported_capability") }
        var payload = try decodeJSON(JSONObject.self, row.required("payload"))
        if let host {
            let scope = try decodeJSON(HostScope.self, row.required("scope"))
            guard sameID(host.hostID, scope.hostID) else { throw QueueError.corruptStore }
            do { try host.authorize(scope) }
            catch QueueError.denied { return try notSubmitted(row, state: "blocked", reason: "host_denied") }
            payload["_tachi_host_scope"] = .object(scope.object)
        }
        let request = try DispatchRequest(identity: identity, sessionID: row.required("session"),
                                          requestID: requestID, capability: capability, payload: payload)
        let events: [AdapterEvent]
        do { events = try await registry.dispatch(request) }
        catch RuntimeError.dispatchUncertain { return requestID }
        catch RuntimeError.identityChanged { return try notSubmitted(row, state: "blocked", reason: "adapter_unavailable") }
        if lookup != nil {
            // This connector observes only receipt or rejection. Unexpected output leaves the claim uncertain.
            guard events.count == 1, let receipt = events.first, receipt.kind == .failed ||
                    (receipt.kind == .accepted && receipt.payload == ["routine_accepted": .bool(true),
                     "native_reply": .bool(false), "native_session_observed": .bool(false)]) else { return requestID }
        }
        do { try db.transaction { for event in events { try recordEvent(event) } } }
        catch QueueError.conflict { return requestID } // Whole inconsistent batch rolls back.
        return requestID
    }

    public func retryBlocked(team: String, principal: QueuePrincipal, requestID: String) throws {
        try db.transaction {
            try authorize(principal, team, "teams:manage")
            try db.query("UPDATE rt_delivery SET state='queued' WHERE team=? AND request=? AND state='blocked'", [team, requestID])
            guard try db.query("SELECT changes() AS n").first?["n"] == "1" else { throw QueueError.conflict }
        }
    }

    /// Trusted connector entry point for independently authenticated, correlated callbacks.
    public func record(_ event: AdapterEvent) throws {
        try db.transaction {
            guard try db.query("""
                SELECT 1 FROM rt_delivery d JOIN rt_workspace_binding b ON b.team=d.team AND b.member=d.target
                WHERE d.request=?
                """, [event.requestID]).isEmpty else { throw QueueError.denied }
            try recordEvent(event)
        }
    }

    func recordEvent(_ event: AdapterEvent) throws {
        guard let row = try db.query("""
            SELECT d.state,a.provider,a.account,a.assistant,a.session FROM rt_delivery d
            JOIN rt_assistant a ON a.team=d.team AND a.member=d.target WHERE d.request=?
            """, [event.requestID]).first, try row.nativeIdentity() == event.identity,
              try sameID(row.required("session"), event.sessionID) else { throw QueueError.conflict }
        if let prior = try db.query("SELECT kind,payload FROM rt_event WHERE request=? AND event=?",
                                    [event.requestID, event.eventID]).first {
            guard prior["kind"] == event.kind.rawValue,
                  try decodeJSON(JSONObject.self, prior.required("payload")) == event.payload else { throw QueueError.conflict }
            return
        }
        let state = try row.required("state")
        guard !["queued", "blocked", "denied"].contains(state) else { throw QueueError.conflict }
        if state == "cancelled", try db.query("SELECT 1 FROM rt_event WHERE request=? LIMIT 1", [event.requestID]).isEmpty {
            throw QueueError.conflict
        }
        let terminal: Set<String> = ["completed", "cancelled", "failed"]
        let newKind = event.kind.rawValue
        if terminal.contains(state), terminal.contains(newKind), state != newKind { throw QueueError.conflict }
        try db.query("INSERT INTO rt_event(request,event,kind,payload) VALUES(?,?,?,?)",
                     [event.requestID, event.eventID, newKind, encodeJSON(event.payload)])
        if !terminal.contains(state) {
            try db.query("UPDATE rt_delivery SET state=? WHERE request=?", [terminal.contains(newKind) ? newKind : "active", event.requestID])
        }
    }
}

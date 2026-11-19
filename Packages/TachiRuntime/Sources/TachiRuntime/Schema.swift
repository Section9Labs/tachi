// Compatible with the original coordinator SQLite database.
let runtimeSchema = """
CREATE TABLE IF NOT EXISTS rt_assistant (
    team TEXT NOT NULL, member TEXT NOT NULL,
    provider TEXT NOT NULL, account TEXT NOT NULL, assistant TEXT NOT NULL, session TEXT NOT NULL,
    PRIMARY KEY(team, member), UNIQUE(provider, account, assistant, session)
);
CREATE TABLE IF NOT EXISTS rt_run (
    team TEXT NOT NULL, run TEXT NOT NULL, lead TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'running', turns INTEGER NOT NULL DEFAULT 0,
    turn_limit INTEGER NOT NULL, PRIMARY KEY(team, run),
    FOREIGN KEY(team, lead) REFERENCES rt_assistant(team, member)
);
CREATE TABLE IF NOT EXISTS rt_message (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL,
    run TEXT NOT NULL, author TEXT NOT NULL, direct_to TEXT, mentions TEXT NOT NULL,
    reply_to TEXT, capability TEXT NOT NULL, payload TEXT NOT NULL, scope TEXT,
    human TEXT NOT NULL, client TEXT NOT NULL, membership TEXT NOT NULL, recipient_membership TEXT,
    parent_request TEXT, parent_event TEXT,
    UNIQUE(team, message), FOREIGN KEY(team, run) REFERENCES rt_run(team, run),
    FOREIGN KEY(team, reply_to) REFERENCES rt_message(team, message)
);
CREATE TABLE IF NOT EXISTS rt_delivery (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL, target TEXT NOT NULL,
    request TEXT NOT NULL UNIQUE, host TEXT, state TEXT NOT NULL DEFAULT 'queued', reason TEXT,
    UNIQUE(team, message, target),
    FOREIGN KEY(team, message) REFERENCES rt_message(team, message),
    FOREIGN KEY(team, target) REFERENCES rt_assistant(team, member)
);
CREATE INDEX IF NOT EXISTS rt_session_work ON rt_delivery(team, target, seq);
CREATE INDEX IF NOT EXISTS rt_ready ON rt_delivery(state, host, seq);
CREATE TABLE IF NOT EXISTS rt_event (
    seq INTEGER PRIMARY KEY, request TEXT NOT NULL REFERENCES rt_delivery(request),
    event TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(request, event)
);
CREATE TABLE IF NOT EXISTS rt_workspace_binding (
    team TEXT NOT NULL, member TEXT NOT NULL, binding TEXT NOT NULL UNIQUE,
    routine TEXT NOT NULL, credential_generation TEXT NOT NULL,
    grantor TEXT NOT NULL, client TEXT NOT NULL, membership TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), PRIMARY KEY(team,member),
    FOREIGN KEY(team,member) REFERENCES rt_assistant(team,member)
);
CREATE UNIQUE INDEX IF NOT EXISTS rt_workspace_enabled ON rt_workspace_binding(team) WHERE enabled=1;
"""

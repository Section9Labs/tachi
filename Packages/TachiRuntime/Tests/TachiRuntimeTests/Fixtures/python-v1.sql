-- Synthetic SQL dump produced by the Python TeamQueue migrated from #9.
BEGIN TRANSACTION;
CREATE TABLE rt_assistant (
    team TEXT NOT NULL, member TEXT NOT NULL,
    provider TEXT NOT NULL, account TEXT NOT NULL, assistant TEXT NOT NULL, session TEXT NOT NULL,
    PRIMARY KEY(team, member), UNIQUE(provider, account, assistant, session)
);
INSERT INTO "rt_assistant" VALUES('team','assistant:lead','fixture','account','lead','session-lead');
INSERT INTO "rt_assistant" VALUES('team','assistant:peer','fixture','account','peer','session-peer');
CREATE TABLE rt_delivery (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL, target TEXT NOT NULL,
    request TEXT NOT NULL UNIQUE, host TEXT, state TEXT NOT NULL DEFAULT 'queued', reason TEXT,
    UNIQUE(team, message, target),
    FOREIGN KEY(team, message) REFERENCES rt_message(team, message),
    FOREIGN KEY(team, target) REFERENCES rt_assistant(team, member)
);
INSERT INTO "rt_delivery" VALUES(1,'team','legacy','assistant:peer','18fa68fc628b43f1adb46a13ec8be59b',NULL,'completed',NULL);
INSERT INTO "rt_delivery" VALUES(2,'team','legacy','assistant:lead','394625b74db145c78ca5c0e8c4a467e5',NULL,'uncertain',NULL);
INSERT INTO "rt_delivery" VALUES(3,'team','pending','assistant:peer','2f52e9aeac174f8c8236bdbd14e39b05',NULL,'queued',NULL);
CREATE TABLE rt_event (
    seq INTEGER PRIMARY KEY, request TEXT NOT NULL REFERENCES rt_delivery(request),
    event TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(request, event)
);
INSERT INTO "rt_event" VALUES(1,'18fa68fc628b43f1adb46a13ec8be59b','result','completed','{"operation":"message"}');
CREATE TABLE rt_message (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL,
    run TEXT NOT NULL, author TEXT NOT NULL, direct_to TEXT, mentions TEXT NOT NULL,
    reply_to TEXT, capability TEXT NOT NULL, payload TEXT NOT NULL, scope TEXT,
    human TEXT NOT NULL, client TEXT NOT NULL, membership TEXT NOT NULL, recipient_membership TEXT,
    parent_request TEXT, parent_event TEXT,
    UNIQUE(team, message), FOREIGN KEY(team, run) REFERENCES rt_run(team, run),
    FOREIGN KEY(team, reply_to) REFERENCES rt_message(team, message)
);
INSERT INTO "rt_message" VALUES(1,'team','legacy','run','human:owner',NULL,'["assistant:lead", "assistant:peer"]',NULL,'message','{"text":"caf\u00e9 / brief"}',NULL,'owner','client','owner-1',NULL,NULL,NULL);
INSERT INTO "rt_message" VALUES(2,'team','pending','run','human:owner','assistant:peer','[]','legacy','message','{"text":"next"}',NULL,'owner','client','owner-1',NULL,NULL,NULL);
CREATE TABLE rt_run (
    team TEXT NOT NULL, run TEXT NOT NULL, lead TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'running', turns INTEGER NOT NULL DEFAULT 0,
    turn_limit INTEGER NOT NULL, PRIMARY KEY(team, run),
    FOREIGN KEY(team, lead) REFERENCES rt_assistant(team, member)
);
INSERT INTO "rt_run" VALUES('team','run','assistant:lead','paused',2,7);
CREATE INDEX rt_session_work ON rt_delivery(team, target, seq);
CREATE INDEX rt_ready ON rt_delivery(state, host, seq);
COMMIT;

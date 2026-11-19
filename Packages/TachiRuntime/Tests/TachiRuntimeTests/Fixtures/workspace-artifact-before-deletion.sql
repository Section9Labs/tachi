-- Artifact table schema from f836c41, before upload IDs could be retired.
CREATE TABLE IF NOT EXISTS rt_workspace_artifact (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, artifact TEXT NOT NULL,
    name TEXT NOT NULL, content_type TEXT NOT NULL, size_bytes INTEGER NOT NULL CHECK(size_bytes BETWEEN 0 AND 1048576),
    sha256 TEXT NOT NULL, content_base64 TEXT NOT NULL, origin TEXT NOT NULL,
    author TEXT NOT NULL, author_client TEXT NOT NULL, author_membership TEXT NOT NULL,
    recipient TEXT, recipient_membership TEXT, source_message TEXT, source_task TEXT,
    UNIQUE(team,artifact), CHECK ((recipient IS NULL) = (recipient_membership IS NULL)),
    CHECK (source_message IS NULL OR source_task IS NULL)
);

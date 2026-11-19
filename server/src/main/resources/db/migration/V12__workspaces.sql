-- Workspaces (Work, Personal, ...): every record can belong to one, and a client that
-- picks a workspace only sees its records. A deleted workspace keeps its row (with
-- deleted_at) so syncing clients see the delete; its records keep pointing at it.
CREATE TABLE workspaces (
    id         bigserial PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision   bigint NOT NULL DEFAULT nextval('revision_seq')
);
CREATE UNIQUE INDEX workspaces_live_name ON workspaces (user_id, lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX workspaces_revision ON workspaces (user_id, revision);

ALTER TABLE records ADD COLUMN workspace_id bigint REFERENCES workspaces (id);
CREATE INDEX records_workspace ON records (user_id, workspace_id, start_at);

-- Everything logged so far was work: one "Work" workspace per user who has records.
INSERT INTO workspaces (user_id, name)
SELECT DISTINCT user_id, 'Work' FROM records;

UPDATE records r
SET workspace_id = w.id, updated_at = now(), revision = nextval('revision_seq')
FROM workspaces w
WHERE w.user_id = r.user_id;

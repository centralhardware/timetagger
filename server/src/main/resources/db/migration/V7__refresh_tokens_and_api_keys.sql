-- Short-lived JWT access tokens are stateless; what can be revoked lives here.
-- Every token that was issued under the per-user seeds stops working.
ALTER TABLE users DROP COLUMN web_token_seed, DROP COLUMN api_token_seed;

-- One row per refresh token, stored as its SHA-256. A login starts a family;
-- each refresh retires its token and issues the next one in the same family.
CREATE TABLE refresh_tokens (
    id          bigserial PRIMARY KEY,
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    family_id   uuid NOT NULL,
    token_hash  text NOT NULL UNIQUE,
    user_agent  text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,
    revoked_at  timestamptz
);
CREATE INDEX refresh_tokens_family ON refresh_tokens (family_id);
CREATE INDEX refresh_tokens_user ON refresh_tokens (user_id);

-- Long-lived keys for scripts, each named and revocable on its own.
CREATE TABLE api_keys (
    id           bigserial PRIMARY KEY,
    user_id      bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name         text NOT NULL,
    key_hash     text NOT NULL UNIQUE,
    -- The first characters of the key, so a list can tell keys apart.
    prefix       text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    revoked_at   timestamptz
);
CREATE INDEX api_keys_user ON api_keys (user_id);

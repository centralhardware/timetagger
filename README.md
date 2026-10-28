# TimeTagger

*Tag your time, get the insight.* A time tracker with a native macOS menu bar app
and a small self-hosted API server.

This fork has two parts:

* **`macos/TimeTaggerBar`**: the client, a SwiftUI menu bar app (macOS 13+, Apple Silicon).
  It has the running timer and today's total in the menu bar, start/stop/switch/resume, local and work
  time zones, a history browser, an editable report with Copy table, and it pauses the
  running task while the Mac sleeps. Download the DMG from
  [Releases](https://github.com/centralhardware/timetagger/releases).
* **`server`**: the API server, in Kotlin with [Ktor](https://ktor.io). It stores everything in
  PostgreSQL, including the login credentials, and serves a REST API at `<prefix>api/v1/`.

The web app is gone: the menu bar app is the client.


## Run the server

```
cd server
./gradlew installDist
export TIMETAGGER_DB_URI='postgresql://user:pass@localhost:5432/timetagger'
export TIMETAGGER_JWT_KEY='a-long-random-secret'
build/install/timetagger/bin/timetagger
```

Pending Flyway migrations are applied on startup. A database from the Python server is adopted as
version 4 and converted to the v1 schema by V5. Manage logins with:

```
timetagger user-add <username> <password>
timetagger user-list
timetagger user-remove <username>
```

Or use the Docker image `ghcr.io/centralhardware/timetagger` with
[deploy/docker-compose.yml](deploy/docker-compose.yml).


## Server layout

`server/src/main/kotlin/timetagger/`:

* `routes/`: mounted in `Application.kt` (`sessionRoutes`, `tokenRoutes`, `recordRoutes`,
  `settingRoutes`, `syncRoutes`)
* `service/`: `RecordService`, `SettingService` (validation, newest edit wins) and `SyncService`
  (changes since a revision)
* `auth/`: tokens (`JwtCodec`, `TokenService`) and passwords. Ktor's `basic` provider checks the
  login and its `jwt` provider the bearer token; only the revocation (seed) check is ours
* `db/`: the connection pool (`Database`), Flyway migrations in `resources/db/migration`, and one
  [kotliquery](https://github.com/seratch/kotliquery) repository per table
* `model/`: the `@Serializable` records, settings, inputs and responses
* errors are `ApiException`s, which `StatusPages` turns into JSON error responses

Tables: `users`, `records` (one row per record, `stop_at` NULL while running, `deleted_at` for
deletes), `record_tags`, `settings`; every write takes a new value from `revision_seq`.


## Configuration

Set with `TIMETAGGER_<NAME>` environment variables or `--<name>=<value>` arguments:

| Name | Default | |
|---|---|---|
| `bind` | `127.0.0.1:8080` | address and port |
| `db_uri` | (required) | `postgresql://user:pass@host:5432/db` |
| `jwt_key` | ephemeral | token signing secret; without it sessions end on restart |
| `log_level` | `info` | |
| `path_prefix` | `/timetagger/` | |


## API (v1)

Served at `<prefix>api/v1/`. JSON in and out, times in ISO-8601. Errors are
`{"error": "<code>", "message": "..."}` with 401, 403, 404, 405, 409 or 422.
Everything except `version` and `sessions` needs `Authorization: Bearer <token>`.

| | |
|---|---|
| `POST sessions` | HTTP Basic login → `{token, expiresAt}`, a web token valid for 14 days |
| `POST tokens` | (web token) → a long-lived API token |
| `DELETE tokens/{web\|api}` | revokes every token of that kind |
| `GET me` | the signed-in user |
| `GET records?from=&to=[&tag=a&tag=b][&running=][&deleted=]` | records overlapping the range |
| `POST records` | creates a record → 201 with its numeric `id` |
| `GET / PUT / DELETE records/{id}` | one record; DELETE marks it deleted |
| `POST records/batch` | `{records: [...]}` in one transaction; entries with an `id` update, others create |
| `GET settings`, `GET / PUT settings/{key}` | `{value}` is any JSON |
| `GET changes?since=<revision>` | everything written after that revision, deletes included |
| `GET version`, `GET <prefix>status` | |

A record is `{id, start, stop, description, tags, deletedAt, revision}`; it is
running while `stop` is null. A write may carry the `revision` it was based on: if the
record has changed since, it gets 409 with the stored record in `current`. Without one
it overwrites.


## License

GPL-3.0, see [LICENSE](LICENSE). Based on [TimeTagger](https://github.com/almarklein/timetagger) by Almar Klein.

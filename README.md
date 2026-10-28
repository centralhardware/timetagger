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
  PostgreSQL, including the login credentials, and speaks the TimeTagger v2 API at
  `<prefix>api/v2/`. Tokens, password hashes and the database schema are compatible with the
  earlier Python server, so an existing database keeps working.

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
version 4. Manage logins with:

```
timetagger user-add <username> <password>
timetagger user-list
timetagger user-remove <username>
```

Or use the Docker image `ghcr.io/centralhardware/timetagger` with
[deploy/docker-compose.yml](deploy/docker-compose.yml).


## Server layout

`server/src/main/kotlin/timetagger/`:

* `routes/`: one file per area, mounted in `Application.kt` (`loginRoutes`, `tokenRoutes`,
  `recordRoutes`, `settingRoutes`, `syncRoutes`)
* `service/SyncService`: reads and writes records and settings and applies the sync rules
  (newest `mt` wins, strictly increasing server times, reset handling)
* `auth/`: tokens (`JwtCodec`, `TokenService`) and passwords. Ktor's `basic` provider checks the
  login and its `jwt` provider checks the `authtoken` header; only the seed/expiry check is ours
* `db/`: the connection pool (`Database`), Flyway migrations in `resources/db/migration`, and one
  [kotliquery](https://github.com/seratch/kotliquery) repository per table
* `model/`: the `@Serializable` items and responses, and the lenient item parser
* errors are `ApiException`s, which `StatusPages` turns into plain-text responses


## Configuration

Set with `TIMETAGGER_<NAME>` environment variables or `--<name>=<value>` arguments:

| Name | Default | |
|---|---|---|
| `bind` | `127.0.0.1:8080` | address and port |
| `db_uri` | (required) | `postgresql://user:pass@host:5432/db` |
| `jwt_key` | ephemeral | token signing secret; without it sessions end on restart |
| `log_level` | `info` | |
| `path_prefix` | `/timetagger/` | |


## API

All endpoints except `login` need an `authtoken` header.

* `POST login` with HTTP Basic credentials → `{"token"}`, a web token valid for 14 days.
* `GET webtoken`, `GET apitoken` (`?reset=1` revokes earlier tokens): need a web token.
* `GET records?timerange=<t1>-<t2>[&running=][&hidden=][&tag=a,b]`, `PUT records`
* `GET settings`, `PUT settings`, `GET updates?since=<ts>`, `PUT forcereset`, `GET version`
* `GET <prefix>status` → `ok`


## License

GPL-3.0, see [LICENSE](LICENSE). Based on [TimeTagger](https://github.com/almarklein/timetagger) by Almar Klein.

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
./gradlew fatJar
export TIMETAGGER_DB_URI='postgresql://user:pass@localhost:5432/timetagger'
export TIMETAGGER_JWT_KEY='a-long-random-secret'
java -jar build/libs/timetagger.jar
```

Pending migrations are applied on startup. Manage logins with:

```
java -jar timetagger.jar user-add <username> <password>
java -jar timetagger.jar user-list
java -jar timetagger.jar user-remove <username>
```

Or use the Docker image `ghcr.io/centralhardware/timetagger` with
[deploy/docker-compose.yml](deploy/docker-compose.yml).


## Server layout

`server/src/main/kotlin/timetagger/`:

* `routes/`: one file per resource, mounted in `Application.kt` (`loginRoutes`, `tokenRoutes`,
  `recordRoutes`, `settingRoutes`, `syncRoutes`)
* `service/SyncService`: reads and writes records and settings and applies the sync rules
  (newest `mt` wins, strictly increasing server times, reset handling)
* `auth/`: tokens (`JwtCodec`, `TokenService`), passwords, login methods, and the `authtoken`
  header as a Ktor authentication provider
* `db/`: the connection pool and migrations (`Database`) and one repository per table
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
| `proxy_auth_enabled` | `false` | trust a username header from a reverse proxy |
| `proxy_auth_trusted` | `127.0.0.1` | trusted proxy IPs/CIDRs, comma separated |
| `proxy_auth_header` | `X-Remote-User` | |
| `path_prefix` | `/timetagger/` | |


## API

All endpoints except `bootstrap_authentication` need an `authtoken` header.

* `POST bootstrap_authentication`: base64 JSON `{"method": "usernamepassword", "username", "password"}`
  (or `localhost` / `proxy`) → `{"token"}`, a web token valid for 14 days.
* `GET webtoken`, `GET apitoken` (`?reset=1` revokes earlier tokens): need a web token.
* `GET records?timerange=<t1>-<t2>[&running=][&hidden=][&tag=a,b]`, `PUT records`
* `GET settings`, `PUT settings`, `GET updates?since=<ts>`, `PUT forcereset`, `GET version`
* `GET <prefix>status` → `ok`


## License

GPL-3.0, see [LICENSE](LICENSE). Based on [TimeTagger](https://github.com/almarklein/timetagger) by Almar Klein.

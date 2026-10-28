package timetagger.db

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import timetagger.model.Record
import timetagger.model.Setting
import java.sql.Connection
import java.sql.ResultSet

/** Filters for listing records; see [RecordRepository.find]. */
data class RecordQuery(
    val t1: Long,
    val t2: Long,
    /** Each tag must appear in the description as "#tag". */
    val tags: List<String> = emptyList(),
    val running: Boolean? = null,
    val hidden: Boolean? = null,
)

/** Every row is scoped to a user via the "user" column. */
class RecordRepository {
    private val cols = "\"key\", modified_time, start_time, stop_time, description, deleted, server_time"

    private fun ResultSet.record() = Record(
        key = getString(1), mt = getLong(2), t1 = getLong(3), t2 = getLong(4),
        ds = getString(5) ?: "", deleted = getInt(6), st = doubleOrNull(7),
    )

    /** Records overlapping [t1, t2], plus running records that started before t2. */
    fun find(conn: Connection, user: String, q: RecordQuery): List<Record> {
        val where = mutableListOf("(stop_time >= ? AND start_time <= ?) OR (start_time = stop_time AND start_time <= ?)")
        val params = mutableListOf<Any?>(user, q.t1, q.t2, q.t2)
        for (tag in q.tags) {
            val esc = tag.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            where += "description LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\'"
            params.addAll(listOf("%#$esc %", "%#$esc"))
        }
        q.running?.let { where += if (it) "start_time = stop_time" else "start_time != stop_time" }
        q.hidden?.let { where += if (it) "deleted = 1" else "deleted = 0" }
        val sql = "SELECT $cols FROM records WHERE \"user\" = ? AND " + where.joinToString(" AND ") { "($it)" }
        return conn.query(sql, *params.toTypedArray()) { record() }
    }

    /** Records written at or after `since`; all of them when since is null. */
    fun changedSince(conn: Connection, user: String, since: Double?): List<Record> =
        if (since == null) conn.query("SELECT $cols FROM records WHERE \"user\" = ?", user) { record() }
        else conn.query("SELECT $cols FROM records WHERE \"user\" = ? AND server_time >= ?", user, since) { record() }

    fun get(conn: Connection, user: String, key: String): Record? =
        conn.queryOne("SELECT $cols FROM records WHERE \"user\" = ? AND \"key\" = ?", user, key) { record() }

    fun upsert(conn: Connection, user: String, r: Record) {
        conn.update(
            "INSERT INTO records (\"user\", \"key\", modified_time, start_time, stop_time, description, deleted, server_time) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (\"user\", \"key\") DO UPDATE SET " +
                "modified_time = EXCLUDED.modified_time, start_time = EXCLUDED.start_time, " +
                "stop_time = EXCLUDED.stop_time, description = EXCLUDED.description, " +
                "deleted = EXCLUDED.deleted, server_time = EXCLUDED.server_time",
            user, r.key, r.mt, r.t1, r.t2, r.ds, r.deleted, r.st,
        )
    }
}

class SettingRepository {
    private val cols = "\"key\", modified_time, value::text, server_time"

    private fun ResultSet.setting() = Setting(
        key = getString(1), mt = getLong(2), value = Json.parseToJsonElement(getString(3) ?: "null"), st = doubleOrNull(4),
    )

    fun all(conn: Connection, user: String): List<Setting> = changedSince(conn, user, null)

    fun changedSince(conn: Connection, user: String, since: Double?): List<Setting> =
        if (since == null) conn.query("SELECT $cols FROM settings WHERE \"user\" = ?", user) { setting() }
        else conn.query("SELECT $cols FROM settings WHERE \"user\" = ? AND server_time >= ?", user, since) { setting() }

    fun get(conn: Connection, user: String, key: String): Setting? =
        conn.queryOne("SELECT $cols FROM settings WHERE \"user\" = ? AND \"key\" = ?", user, key) { setting() }

    fun upsert(conn: Connection, user: String, s: Setting) {
        conn.update(
            "INSERT INTO settings (\"user\", \"key\", modified_time, value, server_time) VALUES (?, ?, ?, ?::jsonb, ?) " +
                "ON CONFLICT (\"user\", \"key\") DO UPDATE SET modified_time = EXCLUDED.modified_time, " +
                "value = EXCLUDED.value, server_time = EXCLUDED.server_time",
            user, s.key, s.mt, s.value.toString(), s.st,
        )
    }
}

/** Server-internal per-user values: token seeds and the reset time. */
class UserInfoRepository {
    fun get(conn: Connection, user: String, key: String): JsonElement? =
        conn.queryOne("SELECT value::text FROM userinfo WHERE \"user\" = ? AND \"key\" = ?", user, key) {
            getString(1)?.let(Json::parseToJsonElement)
        }

    fun put(conn: Connection, user: String, key: String, value: JsonElement, st: Double) {
        conn.update(
            "INSERT INTO userinfo (\"user\", \"key\", modified_time, value, server_time) VALUES (?, ?, ?, ?::jsonb, ?) " +
                "ON CONFLICT (\"user\", \"key\") DO UPDATE SET modified_time = EXCLUDED.modified_time, " +
                "value = EXCLUDED.value, server_time = EXCLUDED.server_time",
            user, key, st, value.toString(), st,
        )
    }

    /** The latest server time over all of the user's rows, or -1. */
    fun lastWrite(conn: Connection, user: String): Double =
        listOf("records", "settings", "userinfo").maxOf { table ->
            conn.queryOne("SELECT max(server_time) FROM $table WHERE \"user\" = ?", user) { doubleOrNull(1) } ?: -1.0
        }
}

/** Login credentials, bcrypt-hashed. */
class CredentialRepository {
    fun hash(conn: Connection, username: String): String? =
        conn.queryOne("SELECT pw_hash FROM credentials WHERE username = ?", username) { getString(1) }

    fun upsert(conn: Connection, username: String, hash: String, mt: Double) {
        conn.update(
            "INSERT INTO credentials (username, pw_hash, modified_time) VALUES (?, ?, ?) " +
                "ON CONFLICT (username) DO UPDATE SET pw_hash = EXCLUDED.pw_hash, modified_time = EXCLUDED.modified_time",
            username, hash, mt,
        )
    }

    fun delete(conn: Connection, username: String): Boolean =
        conn.update("DELETE FROM credentials WHERE username = ?", username) == 1

    fun usernames(conn: Connection): List<String> =
        conn.query("SELECT username FROM credentials ORDER BY username") { getString(1) }
}

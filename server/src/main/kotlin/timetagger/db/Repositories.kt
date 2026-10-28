package timetagger.db

import kotliquery.Row
import kotliquery.Session
import kotliquery.queryOf
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import timetagger.model.Record
import timetagger.model.Setting

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
    private val select =
        "SELECT \"key\", modified_time, start_time, stop_time, description, deleted, server_time FROM records"

    private fun record(row: Row) = Record(
        key = row.string("key"),
        mt = row.long("modified_time"),
        t1 = row.long("start_time"),
        t2 = row.long("stop_time"),
        ds = row.stringOrNull("description") ?: "",
        deleted = row.int("deleted"),
        st = row.doubleOrNull("server_time"),
    )

    /** Records overlapping [t1, t2], plus running records that started before t2. */
    fun find(session: Session, user: String, q: RecordQuery): List<Record> {
        val where = mutableListOf(
            "(stop_time >= :t1 AND start_time <= :t2) OR (start_time = stop_time AND start_time <= :t2)",
        )
        val params = mutableMapOf<String, Any?>("user" to user, "t1" to q.t1, "t2" to q.t2)
        q.tags.forEachIndexed { i, tag ->
            val esc = tag.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            where += "description LIKE :tagmid$i ESCAPE '\\' OR description LIKE :tagend$i ESCAPE '\\'"
            params["tagmid$i"] = "%#$esc %"
            params["tagend$i"] = "%#$esc"
        }
        q.running?.let { where += if (it) "start_time = stop_time" else "start_time != stop_time" }
        q.hidden?.let { where += if (it) "deleted = 1" else "deleted = 0" }
        val sql = "$select WHERE \"user\" = :user AND " + where.joinToString(" AND ") { "($it)" }
        return session.list(queryOf(sql, params), ::record)
    }

    /** Records written at or after `since`; all of them when since is null. */
    fun changedSince(session: Session, user: String, since: Double?): List<Record> =
        if (since == null) session.list(queryOf("$select WHERE \"user\" = ?", user), ::record)
        else session.list(queryOf("$select WHERE \"user\" = ? AND server_time >= ?", user, since), ::record)

    fun get(session: Session, user: String, key: String): Record? =
        session.single(queryOf("$select WHERE \"user\" = ? AND \"key\" = ?", user, key), ::record)

    fun upsert(session: Session, user: String, r: Record) {
        session.update(
            queryOf(
                """
                INSERT INTO records ("user", "key", modified_time, start_time, stop_time, description, deleted, server_time)
                VALUES (:user, :key, :mt, :t1, :t2, :ds, :deleted, :st)
                ON CONFLICT ("user", "key") DO UPDATE SET
                    modified_time = EXCLUDED.modified_time, start_time = EXCLUDED.start_time,
                    stop_time = EXCLUDED.stop_time, description = EXCLUDED.description,
                    deleted = EXCLUDED.deleted, server_time = EXCLUDED.server_time
                """,
                mapOf(
                    "user" to user, "key" to r.key, "mt" to r.mt, "t1" to r.t1, "t2" to r.t2,
                    "ds" to r.ds, "deleted" to r.deleted, "st" to r.st,
                ),
            ),
        )
    }
}

class SettingRepository {
    private val select = "SELECT \"key\", modified_time, value::text AS value, server_time FROM settings"

    private fun setting(row: Row) = Setting(
        key = row.string("key"),
        mt = row.long("modified_time"),
        value = Json.parseToJsonElement(row.stringOrNull("value") ?: "null"),
        st = row.doubleOrNull("server_time"),
    )

    fun all(session: Session, user: String): List<Setting> = changedSince(session, user, null)

    fun changedSince(session: Session, user: String, since: Double?): List<Setting> =
        if (since == null) session.list(queryOf("$select WHERE \"user\" = ?", user), ::setting)
        else session.list(queryOf("$select WHERE \"user\" = ? AND server_time >= ?", user, since), ::setting)

    fun get(session: Session, user: String, key: String): Setting? =
        session.single(queryOf("$select WHERE \"user\" = ? AND \"key\" = ?", user, key), ::setting)

    fun upsert(session: Session, user: String, s: Setting) {
        session.update(
            queryOf(
                """
                INSERT INTO settings ("user", "key", modified_time, value, server_time)
                VALUES (:user, :key, :mt, CAST(:value AS jsonb), :st)
                ON CONFLICT ("user", "key") DO UPDATE SET
                    modified_time = EXCLUDED.modified_time, value = EXCLUDED.value, server_time = EXCLUDED.server_time
                """,
                mapOf("user" to user, "key" to s.key, "mt" to s.mt, "value" to s.value.toString(), "st" to s.st),
            ),
        )
    }
}

/** Server-internal per-user values: token seeds and the reset time. */
class UserInfoRepository {
    fun get(session: Session, user: String, key: String): JsonElement? =
        session.single(queryOf("SELECT value::text AS value FROM userinfo WHERE \"user\" = ? AND \"key\" = ?", user, key)) {
            it.stringOrNull("value")?.let(Json::parseToJsonElement)
        }

    fun put(session: Session, user: String, key: String, value: JsonElement, st: Double) {
        session.update(
            queryOf(
                """
                INSERT INTO userinfo ("user", "key", modified_time, value, server_time)
                VALUES (:user, :key, :st, CAST(:value AS jsonb), :st)
                ON CONFLICT ("user", "key") DO UPDATE SET
                    modified_time = EXCLUDED.modified_time, value = EXCLUDED.value, server_time = EXCLUDED.server_time
                """,
                mapOf("user" to user, "key" to key, "value" to value.toString(), "st" to st),
            ),
        )
    }

    /** The latest server time over all of the user's rows, or -1. */
    fun lastWrite(session: Session, user: String): Double =
        session.single(
            queryOf(
                """
                SELECT greatest(
                    (SELECT max(server_time) FROM records WHERE "user" = :user),
                    (SELECT max(server_time) FROM settings WHERE "user" = :user),
                    (SELECT max(server_time) FROM userinfo WHERE "user" = :user)
                ) AS m
                """,
                mapOf("user" to user),
            ),
        ) { it.doubleOrNull("m") } ?: -1.0
}

/** Login credentials, bcrypt-hashed. */
class CredentialRepository {
    fun hash(session: Session, username: String): String? =
        session.single(queryOf("SELECT pw_hash FROM credentials WHERE username = ?", username)) { it.string("pw_hash") }

    fun upsert(session: Session, username: String, hash: String, mt: Double) {
        session.update(
            queryOf(
                """
                INSERT INTO credentials (username, pw_hash, modified_time) VALUES (?, ?, ?)
                ON CONFLICT (username) DO UPDATE SET pw_hash = EXCLUDED.pw_hash, modified_time = EXCLUDED.modified_time
                """,
                username, hash, mt,
            ),
        )
    }

    fun delete(session: Session, username: String): Boolean =
        session.update(queryOf("DELETE FROM credentials WHERE username = ?", username)) == 1

    fun usernames(session: Session): List<String> =
        session.list(queryOf("SELECT username FROM credentials ORDER BY username")) { it.string("username") }
}

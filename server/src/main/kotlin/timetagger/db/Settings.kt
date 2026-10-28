package timetagger.db

import kotliquery.Row
import kotliquery.Session
import kotliquery.queryOf
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import timetagger.model.Setting
import java.time.Instant

class SettingRepository {
    private val select = "SELECT \"key\", value::text AS value, modified_at, revision FROM settings"

    private fun setting(row: Row) = Setting(
        key = row.string("key"),
        value = Json.parseToJsonElement(row.string("value")),
        modifiedAt = row.instant("modified_at"),
        revision = row.long("revision"),
    )

    fun all(session: Session, userId: Long): List<Setting> =
        session.list(queryOf("$select WHERE user_id = ? ORDER BY \"key\"", userId), ::setting)

    fun get(session: Session, userId: Long, key: String): Setting? =
        session.single(queryOf("$select WHERE user_id = ? AND \"key\" = ?", userId, key), ::setting)

    fun changedSince(session: Session, userId: Long, revision: Long): List<Setting> =
        session.list(queryOf("$select WHERE user_id = ? AND revision > ? ORDER BY revision", userId, revision), ::setting)

    fun save(session: Session, userId: Long, key: String, value: JsonElement, modifiedAt: Instant): Setting {
        session.update(
            queryOf(
                """
                INSERT INTO settings (user_id, "key", value, modified_at) VALUES (:user, :key, CAST(:value AS jsonb), :modified)
                ON CONFLICT (user_id, "key") DO UPDATE SET
                    value = EXCLUDED.value, modified_at = EXCLUDED.modified_at, updated_at = now(), revision = nextval('revision_seq')
                """,
                mapOf("user" to userId, "key" to key, "value" to value.toString(), "modified" to modifiedAt),
            ),
        )
        return get(session, userId, key)!!
    }

    /** The highest revision the user has, so a client can resume from it. */
    fun latestRevision(session: Session, userId: Long): Long =
        session.single(
            queryOf(
                "SELECT greatest((SELECT max(revision) FROM records WHERE user_id = :user), " +
                    "(SELECT max(revision) FROM settings WHERE user_id = :user)) AS m",
                mapOf("user" to userId),
            ),
        ) { it.longOrNull("m") } ?: 0
}

package timetagger.db

import kotliquery.Row
import kotliquery.Session
import kotliquery.queryOf
import timetagger.model.Record
import timetagger.model.Tags
import java.time.Instant

/** Filters for GET /records. */
data class RecordFilter(
    val from: Instant,
    val to: Instant,
    /** Every tag must be on the record. */
    val tags: List<String> = emptyList(),
    val running: Boolean? = null,
    val deleted: Boolean = false,
)

class RecordRepository {
    private val select = """
        SELECT r.id, r.start_at, r.stop_at, r.description, r.deleted_at, r.revision,
               array(SELECT t.tag FROM record_tags t WHERE t.record_id = r.id ORDER BY t.tag) AS tags
        FROM records r
    """.trimIndent()

    private fun record(row: Row) = Record(
        id = row.long("id"),
        start = row.instant("start_at"),
        stop = row.instantOrNull("stop_at"),
        description = row.string("description"),
        tags = row.array<String>("tags").toList(),
        deletedAt = row.instantOrNull("deleted_at"),
        revision = row.long("revision"),
    )

    /** Records overlapping [from, to]; a running record counts as lasting until now. */
    fun find(session: Session, userId: Long, f: RecordFilter): List<Record> {
        val where = mutableListOf("r.user_id = :user", "r.start_at <= :to", "(r.stop_at IS NULL OR r.stop_at >= :from)")
        val params = mutableMapOf<String, Any?>("user" to userId, "from" to f.from, "to" to f.to)
        f.tags.forEachIndexed { i, tag ->
            where += "EXISTS (SELECT 1 FROM record_tags t WHERE t.record_id = r.id AND t.tag = :tag$i)"
            params["tag$i"] = tag.removePrefix("#").lowercase()
        }
        f.running?.let { where += if (it) "r.stop_at IS NULL" else "r.stop_at IS NOT NULL" }
        where += if (f.deleted) "r.deleted_at IS NOT NULL" else "r.deleted_at IS NULL"
        return session.list(queryOf("$select WHERE ${where.joinToString(" AND ")} ORDER BY r.start_at", params), ::record)
    }

    fun get(session: Session, userId: Long, id: Long): Record? =
        session.single(queryOf("$select WHERE r.user_id = ? AND r.id = ?", userId, id), ::record)

    fun changedSince(session: Session, userId: Long, revision: Long): List<Record> =
        session.list(queryOf("$select WHERE r.user_id = ? AND r.revision > ? ORDER BY r.revision", userId, revision), ::record)

    /** Creates the record (the database picks the id) with a new revision and its tags. */
    fun create(
        session: Session, userId: Long, start: Instant, stop: Instant?,
        description: String, deletedAt: Instant?,
    ): Record {
        val id = session.single(
            queryOf(
                """
                INSERT INTO records (user_id, start_at, stop_at, description, deleted_at)
                VALUES (:user, :start, :stop, :description, :deleted)
                RETURNING id
                """,
                mapOf(
                    "user" to userId, "start" to start, "stop" to stop,
                    "description" to description, "deleted" to deletedAt,
                ),
            ),
        ) { it.long("id") }!!
        return withTags(session, userId, id, description)
    }

    /** Replaces the record's fields, stamps a new revision and rewrites its tags. */
    fun update(
        session: Session, userId: Long, id: Long, start: Instant, stop: Instant?,
        description: String, deletedAt: Instant?,
    ): Record {
        session.update(
            queryOf(
                """
                UPDATE records SET start_at = :start, stop_at = :stop, description = :description,
                    deleted_at = :deleted, updated_at = now(), revision = nextval('revision_seq')
                WHERE user_id = :user AND id = :id
                """,
                mapOf(
                    "user" to userId, "id" to id, "start" to start, "stop" to stop,
                    "description" to description, "deleted" to deletedAt,
                ),
            ),
        )
        return withTags(session, userId, id, description)
    }

    private fun withTags(session: Session, userId: Long, id: Long, description: String): Record {
        session.update(queryOf("DELETE FROM record_tags WHERE record_id = ?", id))
        for (tag in Tags.of(description)) {
            session.update(queryOf("INSERT INTO record_tags (record_id, tag) VALUES (?, ?)", id, tag))
        }
        return get(session, userId, id)!!
    }
}

fun Row.instant(column: String): Instant = sqlTimestamp(column).toInstant()
fun Row.instantOrNull(column: String): Instant? = sqlTimestampOrNull(column)?.toInstant()

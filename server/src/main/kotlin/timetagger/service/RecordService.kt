package timetagger.service

import kotliquery.Session
import timetagger.Conflict
import timetagger.Invalid
import timetagger.NotFound
import timetagger.db.Database
import timetagger.db.RecordFilter
import timetagger.db.RecordRepository
import timetagger.model.Record
import timetagger.model.RecordInput
import java.time.Instant

private val KEY = Regex("[A-Za-z0-9_-]{1,64}")
private const val DESCRIPTION_MAX = 1000

class RecordService(private val db: Database, private val records: RecordRepository) {
    suspend fun find(userId: Long, filter: RecordFilter): List<Record> = db.io { records.find(it, userId, filter) }

    suspend fun get(userId: Long, key: String): Record = db.io { records.get(it, userId, key) } ?: throw NotFound("record $key")

    suspend fun put(userId: Long, key: String, input: RecordInput): Record = db.tx { save(it, userId, key, input) }

    /** All or nothing: one invalid or conflicting record rejects the whole batch. */
    suspend fun putAll(userId: Long, inputs: List<RecordInput>): List<Record> = db.tx { session ->
        inputs.map { save(session, userId, it.key ?: throw Invalid("every record in a batch needs a key"), it) }
    }

    suspend fun delete(userId: Long, key: String) = db.tx { session ->
        val cur = records.get(session, userId, key) ?: throw NotFound("record $key")
        if (cur.deletedAt == null) {
            val now = Instant.now()
            records.save(session, userId, key, cur.start, cur.stop, cur.description, now, now)
        }
    }

    private fun save(session: Session, userId: Long, key: String, input: RecordInput): Record {
        if (!KEY.matches(key)) throw Invalid("key must be 1-64 letters, digits, '-' or '_'")
        if (input.description.length > DESCRIPTION_MAX) throw Invalid("description must be at most $DESCRIPTION_MAX characters")
        if (input.stop != null && input.stop < input.start) throw Invalid("stop must not be before start")
        val modifiedAt = input.modifiedAt ?: Instant.now()
        val cur = records.get(session, userId, key)
        if (cur != null && cur.modifiedAt > modifiedAt) throw Conflict(cur)
        val deletedAt = if (input.deleted) cur?.deletedAt ?: modifiedAt else null
        return records.save(session, userId, key, input.start, input.stop, input.description.trim(), deletedAt, modifiedAt)
    }
}

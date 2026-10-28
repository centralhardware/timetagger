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

private const val DESCRIPTION_MAX = 1000

class RecordService(private val db: Database, private val records: RecordRepository) {
    suspend fun find(userId: Long, filter: RecordFilter): List<Record> = db.io { records.find(it, userId, filter) }

    suspend fun tags(userId: Long): List<String> = db.io { records.tags(it, userId) }

    suspend fun get(userId: Long, id: String): Record = db.io { records.get(it, userId, recordId(id)) } ?: throw NotFound("record $id")

    suspend fun create(userId: Long, input: RecordInput): Record = db.write(userId) { create(it, userId, input) }

    suspend fun update(userId: Long, id: String, input: RecordInput): Record = db.write(userId) { update(it, userId, recordId(id), input) }

    /** All or nothing: one invalid, missing or conflicting record rejects the whole batch. */
    suspend fun saveAll(userId: Long, inputs: List<RecordInput>): List<Record> = db.write(userId) { session ->
        inputs.map { input -> input.id?.let { update(session, userId, it, input) } ?: create(session, userId, input) }
    }

    suspend fun delete(userId: Long, id: String) = db.write(userId) { session ->
        val cur = records.get(session, userId, recordId(id)) ?: throw NotFound("record $id")
        if (cur.deletedAt == null) {
            records.update(session, userId, recordId(id), cur.start, cur.stop, cur.description, Instant.now())
        }
    }

    private fun create(session: Session, userId: Long, input: RecordInput): Record {
        validate(input)
        return records.create(session, userId, input.start, input.stop, input.description.trim(), Instant.now().takeIf { input.deleted })
    }

    private fun update(session: Session, userId: Long, id: Long, input: RecordInput): Record {
        validate(input)
        val cur = records.get(session, userId, id) ?: throw NotFound("record $id")
        if (input.revision != null && input.revision != cur.revision) throw Conflict(cur)
        val deletedAt = if (input.deleted) cur.deletedAt ?: Instant.now() else null
        return records.update(session, userId, id, input.start, input.stop, input.description.trim(), deletedAt)
    }

    private fun validate(input: RecordInput) {
        if (input.description.length > DESCRIPTION_MAX) throw Invalid("description must be at most $DESCRIPTION_MAX characters")
        if (input.stop != null && input.stop < input.start) throw Invalid("stop must not be before start")
    }

    /** A malformed id can't name any record. */
    private fun recordId(id: String): Long = id.toLongOrNull() ?: throw NotFound("record $id")
}

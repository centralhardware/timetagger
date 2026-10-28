package timetagger.service

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import timetagger.db.Database
import timetagger.db.RecordRepository
import timetagger.db.SettingRepository
import timetagger.model.Changes
import org.slf4j.LoggerFactory

private val log = LoggerFactory.getLogger("timetagger.sync")

/** Clients sync by asking for everything written after the last revision they saw. */
class SyncService(private val db: Database, private val records: RecordRepository, private val settings: SettingRepository) {
    /** One snapshot, so the revision returned covers exactly the rows returned. */
    suspend fun changes(userId: Long, since: Long): Changes = db.snapshot { session ->
        Changes(
            revision = settings.latestRevision(session, userId),
            records = records.changedSince(session, userId, since),
            settings = settings.changedSince(session, userId, since),
        )
    }.also { log.debug("User {} synced from {} to {}: {} records, {} settings", userId, since, it.revision, it.records.size, it.settings.size) }

    /** Ticks after each of the user's writes commits. */
    fun written(userId: Long): Flow<Unit> = db.writes.filter { it == userId }.map { }
}

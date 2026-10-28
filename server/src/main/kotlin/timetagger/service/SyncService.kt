package timetagger.service

import timetagger.db.Database
import timetagger.db.RecordRepository
import timetagger.db.SettingRepository
import timetagger.model.Changes

/** Clients sync by asking for everything written after the last revision they saw. */
class SyncService(private val db: Database, private val records: RecordRepository, private val settings: SettingRepository) {
    suspend fun changes(userId: Long, since: Long): Changes = db.tx { session ->
        Changes(
            revision = settings.latestRevision(session, userId),
            records = records.changedSince(session, userId, since),
            settings = settings.changedSince(session, userId, since),
        )
    }
}

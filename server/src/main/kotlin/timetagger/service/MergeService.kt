package timetagger.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.slf4j.LoggerFactory
import timetagger.db.Database
import timetagger.db.RecordFilter
import timetagger.db.RecordRepository
import timetagger.model.Record
import java.time.Duration
import java.time.Instant

private val log = LoggerFactory.getLogger("timetagger.merge")

/** A run of records that collapses into its first one. */
data class Chain(val records: List<Record>)

/**
 * Folds back-to-back records of the same task into one. Stopping and restarting the timer
 * (a call, lunch, a Mac that slept) leaves several records with one description seconds
 * apart; after each write the user's recent records are checked and such runs merged.
 *
 * Mergeable, all of: both records closed (a running one is never touched and breaks the
 * run); the same description and the same tags once [ignoreTag] (`finished`, which marks
 * a day's last block) is set aside; the next one starts at most [gap] after the previous stops; nothing
 * else in between. The earliest record is kept and stretched to the last one's stop, the
 * rest are deleted. The marker survives if any record in the run carried it.
 */
class MergeService(
    private val db: Database,
    private val records: RecordRepository,
    private val gap: Duration = Duration.ofSeconds(60),
    private val ignoreTag: String? = "finished",
    /** How far back a write looks: two days covers a shift that ran past midnight. */
    private val window: Duration = Duration.ofDays(2),
) {
    /** Merges after every committed write, for as long as [scope] lives. */
    fun start(scope: CoroutineScope): Job = scope.launch {
        db.writes.collect { userId ->
            runCatching { mergeRecent(userId) }.onFailure { log.error("Merging records for user {} failed", userId, it) }
        }
    }

    /**
     * Merges the user's recent runs; returns how many. Reads first and writes only when there
     * is something to merge, so the merge's own write (which notifies again) ends the round.
     */
    suspend fun mergeRecent(userId: Long, now: Instant = Instant.now()): Int {
        val filter = RecordFilter(from = now.minus(window), to = now.plus(Duration.ofDays(1)))
        if (chains(db.io { records.find(it, userId, filter) }).isEmpty()) return 0
        return db.write(userId) { session ->
            val found = chains(records.find(session, userId, filter))
            for (chain in found) {
                val first = chain.records.first()
                val last = chain.records.last()
                records.update(session, userId, first.id, first.start, last.stop, first.description, mergedTags(chain), null)
                for (r in chain.records.drop(1)) records.update(session, userId, r.id, r.start, r.stop, r.description, r.tags, now)
                log.info("Merged {} records into {} ({})", chain.records.size, first.id, first.description)
            }
            found.size
        }
    }

    /** Runs of two or more mergeable records, in `records` sorted by start. */
    fun chains(records: List<Record>): List<Chain> {
        val out = mutableListOf<Chain>()
        var current = mutableListOf<Record>()
        fun bank() {
            if (current.size > 1) out += Chain(current)
        }
        for (r in records.sortedWith(compareBy({ it.start }, { it.id }))) {
            val stop = r.stop
            if (stop == null) {
                bank()
                current = mutableListOf()
                continue
            }
            val prev = current.lastOrNull()
            val gapToPrev = prev?.stop?.let { Duration.between(it, r.start) }
            if (prev != null && prev.description.trim() == r.description.trim() && clean(prev.tags) == clean(r.tags) &&
                gapToPrev != null && !gapToPrev.isNegative && gapToPrev <= gap
            ) {
                current += r
                continue
            }
            bank()
            current = mutableListOf(r)
        }
        bank()
        return out
    }

    private fun mergedTags(chain: Chain): List<String> {
        val marked = ignoreTag != null && chain.records.any { ignoreTag in it.tags }
        return if (marked) (chain.records.first().tags + ignoreTag!!).distinct().sorted() else chain.records.first().tags
    }

    /** The tags without the ignored one. */
    fun clean(tags: List<String>): List<String> = tags.filter { it != ignoreTag }
}

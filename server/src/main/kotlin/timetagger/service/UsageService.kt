package timetagger.service

import timetagger.Invalid
import timetagger.db.UsageRepository
import timetagger.model.UsageBlock
import timetagger.model.UsageSummary
import timetagger.model.UsageTotal
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeParseException
import io.ktor.http.HttpStatusCode
import timetagger.ApiException

private const val BATCH_MAX = 1000
private const val TEXT_MAX = 256
/** One block is one stretch in front; a day-long one means a client bug, not usage. */
private val BLOCK_MAX: Duration = Duration.ofHours(24)

/** Null [usage] means no ClickHouse is configured: every call answers 503. */
class UsageService(private val usage: UsageRepository?) {
    private val repo: UsageRepository get() = usage ?: throw UsageDisabled()

    /** Stores the blocks in one insert. Usage is not synced to other clients, so no revision. */
    suspend fun save(userId: Long, blocks: List<UsageBlock>) {
        if (blocks.size > BATCH_MAX) throw Invalid("at most $BATCH_MAX blocks per upload")
        val parsed = blocks.map { b ->
            for ((name, v) in listOf("device" to b.device, "bundleId" to b.bundleId, "appName" to b.appName)) {
                if (v.isBlank() || v.length > TEXT_MAX) throw Invalid("$name must be 1-$TEXT_MAX characters")
            }
            val start = instant(b.start, "start")
            val stop = instant(b.stop, "stop")
            if (stop < start) throw Invalid("stop must not be before start")
            if (Duration.between(start, stop) > BLOCK_MAX) throw Invalid("a block must be at most 24 hours")
            Triple(b, start, stop)
        }
        repo.insert(userId, parsed)
    }

    suspend fun find(userId: Long, from: Instant, to: Instant): List<UsageBlock> = repo.find(userId, from, to)

    suspend fun summary(userId: Long, from: Instant, to: Instant): UsageSummary {
        if (to <= from) throw Invalid("to must be after from")
        val apps: List<UsageTotal> = repo.totals(userId, from, to)
        return UsageSummary(from.toString(), to.toString(), apps.sumOf { it.seconds }, apps)
    }

    private fun instant(s: String, name: String): Instant = try {
        Instant.parse(s)
    } catch (e: DateTimeParseException) {
        throw Invalid("$name must be an ISO-8601 instant")
    }
}

class UsageDisabled : ApiException(HttpStatusCode.ServiceUnavailable, "usage_disabled", "app usage needs TIMETAGGER_CLICKHOUSE_URI on the server")

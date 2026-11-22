package timetagger.service

import io.ktor.http.HttpStatusCode
import timetagger.ApiException
import timetagger.Invalid
import timetagger.db.RecordFilter
import timetagger.db.UsageRepository
import timetagger.db.UsageRow
import timetagger.model.TitleTotal
import timetagger.model.UsageBlock
import timetagger.model.UsageSummary
import timetagger.model.UsageTotal
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeParseException

private const val BATCH_MAX = 1000
private const val TEXT_MAX = 256
private const val TITLE_MAX = 1024
/** Titles listed per app in a summary. */
private const val TOP_TITLES = 10
/** A ticket worked on in more stretches than this is summed over its newest ones only. */
private const val RANGES_MAX = 500
/** One block is one stretch in front; a day-long one means a client bug, not usage. */
private val BLOCK_MAX: Duration = Duration.ofHours(24)
private val KINDS = setOf("app", "away")
/** Away blocks that end in one of these were ended by someone picking the Mac up. */
private val PICKUP_REASONS = setOf("lock", "sleep")

/** Null [usage] means no ClickHouse is configured: every call answers 503. */
class UsageService(private val usage: UsageRepository?, private val records: RecordService) {
    private val repo: UsageRepository get() = usage ?: throw UsageDisabled()

    /** Stores the blocks in one insert. Usage is not synced to other clients, so no revision. */
    suspend fun save(userId: Long, blocks: List<UsageBlock>) {
        if (blocks.size > BATCH_MAX) throw Invalid("at most $BATCH_MAX blocks per upload")
        val parsed = blocks.map { b ->
            for ((name, v) in listOf("device" to b.device, "bundleId" to b.bundleId, "appName" to b.appName)) {
                if (v.isBlank() || v.length > TEXT_MAX) throw Invalid("$name must be 1-$TEXT_MAX characters")
            }
            if (b.kind !in KINDS) throw Invalid("kind must be one of $KINDS")
            if (b.title.length > TITLE_MAX) throw Invalid("title must be at most $TITLE_MAX characters")
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
        return summarize(userId, listOf(from to to), from, to)
    }

    /** What was in front while one TimeTagger record ran (a running record: until now). */
    suspend fun forRecord(userId: Long, id: String): UsageSummary {
        repo
        val r = records.get(userId, id)
        val stop = r.stop ?: Instant.now()
        return summarize(userId, listOf(r.start to stop), r.start, stop).copy(record = r.id)
    }

    /** What was in front during every record of a ticket, all time. */
    suspend fun forTicket(userId: Long, ticket: String): UsageSummary {
        repo // 503 before looking anything up
        val key = ticket.trim().uppercase()
        if (key.isEmpty()) throw Invalid("ticket must not be empty")
        val recs = records.find(userId, RecordFilter(from = Instant.EPOCH, to = Instant.parse("9999-12-31T00:00:00Z"), text = key))
            .filter { it.ticket == key }
            .takeLast(RANGES_MAX)
        if (recs.isEmpty()) throw timetagger.NotFound("ticket $key")
        val now = Instant.now()
        val ranges = recs.map { it.start to (it.stop ?: now) }
        return summarize(userId, ranges, ranges.minOf { it.first }, ranges.maxOf { it.second }).copy(ticket = key)
    }

    private suspend fun summarize(userId: Long, ranges: List<Pair<Instant, Instant>>, from: Instant, to: Instant): UsageSummary {
        val rows = ranges.flatMap { (a, b) -> if (b > a) repo.totals(userId, a, b) else emptyList() }
        return build(rows, from, to)
    }

    private fun build(rows: List<UsageRow>, from: Instant, to: Instant): UsageSummary {
        val (apps, away) = rows.partition { it.kind == "app" }
        val perApp = apps.groupBy { it.bundleId }.map { (bundle, rs) ->
            val titles = rs.groupBy { it.title }.map { (t, xs) -> TitleTotal(t, xs.sumOf { it.seconds }) }
                .filter { it.title.isNotEmpty() && it.seconds > 0 }
                .sortedByDescending { it.seconds }.take(TOP_TITLES)
            UsageTotal(bundle, rs.last().appName, rs.sumOf { it.seconds }, titles)
        }.filter { it.seconds > 0 }.sortedWith(compareByDescending<UsageTotal> { it.seconds }.thenBy { it.bundleId })
        return UsageSummary(
            from = from.toString(), to = to.toString(),
            totalSeconds = perApp.sumOf { it.seconds },
            awaySeconds = away.sumOf { it.seconds },
            pickups = away.filter { it.bundleId in PICKUP_REASONS }.sumOf { it.blocks },
            apps = perApp,
        )
    }

    private fun instant(s: String, name: String): Instant = try {
        Instant.parse(s)
    } catch (e: DateTimeParseException) {
        throw Invalid("$name must be an ISO-8601 instant")
    }
}

class UsageDisabled : ApiException(HttpStatusCode.ServiceUnavailable, "usage_disabled", "app usage needs TIMETAGGER_CLICKHOUSE_URI on the server")

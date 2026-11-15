package timetagger.routes

import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.Serializable
import timetagger.Invalid
import timetagger.auth.AuthService
import timetagger.auth.Unauthorized
import timetagger.db.RecordFilter
import timetagger.model.Record
import timetagger.service.RecordService
import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * The day's tracked time as a small JSON file for a watch-face complication app
 * ("Complicated" and the like) that polls a URL and can't send headers.
 */
@Serializable
data class WatchToday(
    /** First complication line, e.g. "6:12". */
    val line1: String,
    /** Second line: the target and whether a record is running, e.g. "/ 7:40 ●". */
    val line2: String,
    val trackedSeconds: Long,
    val targetSeconds: Long,
    /** 0..1 of the target, capped at 1, for gauge/ring styles. */
    val progress: Double,
    val running: Boolean,
    val date: String,
)

/** Records belong to the day they started in, as worktime.py counts them; a running record counts until now. */
fun watchToday(records: List<Record>, day: LocalDate, zone: ZoneId, targetMinutes: Long, now: Instant = Instant.now()): WatchToday {
    val todays = records.filter { it.start.atZone(zone).toLocalDate() == day }
    val seconds = todays.sumOf { maxOf(0L, ((it.stop ?: now).epochSecond - it.start.epochSecond)) }
    val running = todays.any { it.stop == null }
    val target = targetMinutes * 60
    return WatchToday(
        line1 = hm(seconds),
        line2 = "/ ${hm(target)}" + if (running) " ●" else "",
        trackedSeconds = seconds,
        targetSeconds = target,
        progress = if (target > 0) minOf(1.0, seconds.toDouble() / target) else 0.0,
        running = running,
        date = day.toString(),
    )
}

private fun hm(seconds: Long) = "%d:%02d".format(seconds / 3600, seconds / 60 % 60)

/**
 * GET /watch/today?key=tt_…[&tz=Europe/Podgorica][&target=460]. Only an API key is accepted here,
 * as a query parameter, since a complication app can't set Authorization. Request logs carry
 * the path without the query, so the key does not land in them.
 */
fun Route.watchRoutes(auth: AuthService, records: RecordService, defaultZone: ZoneId, defaultTargetMinutes: Long) = get("watch/today") {
    val q = call.request.queryParameters
    val key = q["key"]?.takeIf { it.startsWith(AuthService.API_KEY_PREFIX) } ?: throw Unauthorized("key must be an API key")
    val user = auth.authenticate(key) ?: throw Unauthorized("unknown API key")
    val zone = q["tz"]?.let { try { ZoneId.of(it) } catch (_: DateTimeException) { throw Invalid("tz must be an IANA zone, e.g. Europe/Podgorica") } } ?: defaultZone
    val target = q["target"]?.let { it.toLongOrNull()?.takeIf { m -> m >= 0 } ?: throw Invalid("target must be minutes") } ?: defaultTargetMinutes
    val now = Instant.now()
    val day = now.atZone(zone).toLocalDate()
    val from = day.atStartOfDay(zone).toInstant()
    val to = day.plusDays(1).atStartOfDay(zone).toInstant()
    call.respond(watchToday(records.find(user.userId, RecordFilter(from, to)), day, zone, target, now))
}

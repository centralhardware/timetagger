package timetagger.db

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import timetagger.model.UsageBlock
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val CH_TIME: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS")

private fun Instant.ch(): String = CH_TIME.format(atOffset(ZoneOffset.UTC))

private fun parseCh(s: String): Instant = LocalDateTime.parse(s.replace(' ', 'T')).toInstant(ZoneOffset.UTC)

/** One row of [UsageRepository.totals]: seconds of one (kind, bundle, title) inside a range. */
data class UsageRow(val kind: String, val bundleId: String, val appName: String, val title: String, val seconds: Long, val blocks: Long)

/**
 * Mac app usage in ClickHouse. A client re-sends the block it is still in with a later stop;
 * (user, device, start) identifies a block and the row with the latest stop wins on merge,
 * so every read uses FINAL.
 */
/** The table comes from the ClickHouse migrations ([ClickHouseMigrations]). */
class UsageRepository(private val ch: ClickHouse) {
    suspend fun insert(userId: Long, blocks: List<Triple<UsageBlock, Instant, Instant>>) =
        ch.insert(
            "app_usage",
            blocks.map { (b, start, stop) ->
                JsonObject(
                    mapOf(
                        "user_id" to JsonPrimitive(userId), "device" to JsonPrimitive(b.device), "kind" to JsonPrimitive(b.kind),
                        "bundle_id" to JsonPrimitive(b.bundleId), "app_name" to JsonPrimitive(b.appName), "title" to JsonPrimitive(b.title),
                        "start_at" to JsonPrimitive(start.ch()), "stop_at" to JsonPrimitive(stop.ch()),
                    ),
                )
            },
        )

    private fun range(userId: Long, from: Instant, to: Instant) = mapOf("user" to userId, "from" to from.ch(), "to" to to.ch())

    private val overlaps = "user_id = {user:UInt64} AND stop_at > {from:DateTime64(3, 'UTC')} AND start_at < {to:DateTime64(3, 'UTC')}"

    /** Blocks overlapping [from, to). */
    suspend fun find(userId: Long, from: Instant, to: Instant): List<UsageBlock> =
        ch.select(
            """
            SELECT device, kind, bundle_id, app_name, title, toString(start_at) AS s, toString(stop_at) AS e
            FROM app_usage FINAL
            WHERE $overlaps
            ORDER BY start_at
            """.trimIndent(),
            range(userId, from, to),
        ).map {
            UsageBlock(
                device = it.str("device"), bundleId = it.str("bundle_id"), appName = it.str("app_name"),
                start = parseCh(it.str("s")).toString(), stop = parseCh(it.str("e")).toString(),
                kind = it.str("kind"), title = it.str("title"),
            )
        }

    /**
     * Seconds per (kind, bundle, title) inside [from, to), blocks clipped to the range; the latest
     * name of an app wins. `blocks` counts the blocks that end inside the range (used for pickups).
     */
    suspend fun totals(userId: Long, from: Instant, to: Instant): List<UsageRow> =
        ch.select(
            """
            SELECT kind, bundle_id, title,
                   argMax(app_name, start_at) AS name,
                   toInt64(sum(dateDiff('millisecond',
                       greatest(start_at, {from:DateTime64(3, 'UTC')}),
                       least(stop_at, {to:DateTime64(3, 'UTC')}))) / 1000) AS seconds,
                   toInt64(countIf(stop_at < {to:DateTime64(3, 'UTC')})) AS ended
            FROM app_usage FINAL
            WHERE $overlaps
            GROUP BY kind, bundle_id, title
            """.trimIndent(),
            range(userId, from, to),
        ).map {
            UsageRow(it.str("kind"), it.str("bundle_id"), it.str("name"), it.str("title"), it.str("seconds").toLong(), it.str("ended").toLong())
        }

    private fun JsonObject.str(k: String) = this[k]!!.jsonPrimitive.content
}

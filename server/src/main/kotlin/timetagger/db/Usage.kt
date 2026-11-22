package timetagger.db

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import timetagger.model.UsageBlock
import timetagger.model.UsageTotal
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val CH_TIME: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS")

private fun Instant.ch(): String = CH_TIME.format(atOffset(ZoneOffset.UTC))

private fun parseCh(s: String): Instant = LocalDateTime.parse(s.replace(' ', 'T')).toInstant(ZoneOffset.UTC)

/**
 * Mac app usage in ClickHouse. A client re-sends the block it is still in with a later stop;
 * (user, device, start) identifies a block and the row with the latest stop wins on merge,
 * so every read uses FINAL.
 */
class UsageRepository(private val ch: ClickHouse) {
    suspend fun migrate() {
        ch.execute(
            """
            CREATE TABLE IF NOT EXISTS app_usage (
                user_id   UInt64,
                device    LowCardinality(String),
                bundle_id LowCardinality(String),
                app_name  LowCardinality(String),
                start_at  DateTime64(3, 'UTC'),
                stop_at   DateTime64(3, 'UTC')
            )
            ENGINE = ReplacingMergeTree(stop_at)
            PARTITION BY toYYYYMM(start_at)
            ORDER BY (user_id, device, start_at)
            """.trimIndent(),
        )
    }

    suspend fun insert(userId: Long, blocks: List<Triple<UsageBlock, Instant, Instant>>) =
        ch.insert(
            "app_usage",
            blocks.map { (b, start, stop) ->
                JsonObject(
                    mapOf(
                        "user_id" to JsonPrimitive(userId), "device" to JsonPrimitive(b.device),
                        "bundle_id" to JsonPrimitive(b.bundleId), "app_name" to JsonPrimitive(b.appName),
                        "start_at" to JsonPrimitive(start.ch()), "stop_at" to JsonPrimitive(stop.ch()),
                    ),
                )
            },
        )

    private fun range(userId: Long, from: Instant, to: Instant) = mapOf("user" to userId, "from" to from.ch(), "to" to to.ch())

    /** Blocks overlapping [from, to). */
    suspend fun find(userId: Long, from: Instant, to: Instant): List<UsageBlock> =
        ch.select(
            """
            SELECT device, bundle_id, app_name, toString(start_at) AS s, toString(stop_at) AS e
            FROM app_usage FINAL
            WHERE user_id = {user:UInt64} AND stop_at > {from:DateTime64(3, 'UTC')} AND start_at < {to:DateTime64(3, 'UTC')}
            ORDER BY start_at
            """.trimIndent(),
            range(userId, from, to),
        ).map {
            UsageBlock(
                device = it.str("device"), bundleId = it.str("bundle_id"), appName = it.str("app_name"),
                start = parseCh(it.str("s")).toString(), stop = parseCh(it.str("e")).toString(),
            )
        }

    /** Seconds per app inside [from, to), blocks clipped to the range; the latest name of an app wins. */
    suspend fun totals(userId: Long, from: Instant, to: Instant): List<UsageTotal> =
        ch.select(
            """
            SELECT bundle_id,
                   argMax(app_name, start_at) AS name,
                   toInt64(sum(dateDiff('millisecond',
                       greatest(start_at, {from:DateTime64(3, 'UTC')}),
                       least(stop_at, {to:DateTime64(3, 'UTC')}))) / 1000) AS seconds
            FROM app_usage FINAL
            WHERE user_id = {user:UInt64} AND stop_at > {from:DateTime64(3, 'UTC')} AND start_at < {to:DateTime64(3, 'UTC')}
            GROUP BY bundle_id
            ORDER BY seconds DESC, bundle_id
            """.trimIndent(),
            range(userId, from, to),
        ).map { UsageTotal(it.str("bundle_id"), it.str("name"), it["seconds"]!!.jsonPrimitive.content.toLong()) }

    private fun JsonObject.str(k: String) = this[k]!!.jsonPrimitive.content
}

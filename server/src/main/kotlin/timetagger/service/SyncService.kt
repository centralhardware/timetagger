package timetagger.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import timetagger.db.Database
import timetagger.db.RecordQuery
import timetagger.db.RecordRepository
import timetagger.db.SettingRepository
import timetagger.db.UserInfoRepository
import timetagger.model.InvalidItem
import timetagger.model.ItemParser
import timetagger.model.PushResponse
import timetagger.model.Record
import timetagger.model.Setting
import timetagger.model.UpdatesResponse
import timetagger.now
import kotliquery.Session

/**
 * Reads and writes a user's records and settings, and implements the sync
 * rules: the newest edit (by mt) wins, and every write gets a strictly
 * increasing server time so clients converge on the same state.
 */
class SyncService(
    private val db: Database,
    private val records: RecordRepository,
    private val settings: SettingRepository,
    private val userInfo: UserInfoRepository,
) {
    suspend fun findRecords(user: String, q: RecordQuery): List<Record> = db.io { records.find(it, user, q) }

    suspend fun allSettings(user: String): List<Setting> = db.io { settings.all(it, user) }

    suspend fun updates(user: String, since: Double): UpdatesResponse {
        val serverTime = now()
        return db.io { session ->
            // Fast path, which is what happens most of the time.
            if (userInfo.lastWrite(session, user) + 0.2 < since) {
                return@io UpdatesResponse(serverTime, JsonPrimitive(0), emptyList(), emptyList())
            }
            // The client must start over when the data was reset after `since`.
            val reset = since <= resetTime(session, user)
            val from = if (reset) null else since
            UpdatesResponse(serverTime, JsonPrimitive(reset), records.changedSince(session, user, from), settings.changedSince(session, user, from))
        }
    }

    /** Makes every client that synced before now drop its local state on its next sync. */
    suspend fun forceReset(user: String) = db.tx { userInfo.put(it, user, "reset_time", JsonPrimitive(now()), now()) }

    suspend fun pushRecords(user: String, items: JsonArray) =
        push(user, items, ItemParser::record, Record::mt, Record::st, { session, key -> records.get(session, user, key) }) { session, r, st ->
            records.upsert(session, user, r.copy(st = st))
        }

    suspend fun pushSettings(user: String, items: JsonArray) =
        push(user, items, ItemParser::setting, Setting::mt, Setting::st, { session, key -> settings.get(session, user, key) }) { session, s, st ->
            settings.upsert(session, user, s.copy(st = st))
        }

    /**
     * Stores the items in one transaction. An invalid item, or one edited before
     * the last reset, is rejected; the stored copy (if any) is still re-stamped.
     */
    private suspend fun <T : Any> push(
        user: String,
        items: JsonArray,
        parse: (JsonObject) -> T,
        mt: (T) -> Long,
        st: (T) -> Double?,
        current: (Session, String) -> T?,
        store: (Session, T, Double) -> Unit,
    ): PushResponse {
        val serverTime = now()
        val accepted = mutableListOf<String>()
        val failed = mutableListOf<String>()
        val errors = mutableListOf<String>()
        var keyless = 0
        db.tx { session ->
            val resetTime = resetTime(session, user)
            for (raw in items) {
                val key = ItemParser.key(raw)
                if (key == null) {
                    keyless++
                    continue
                }
                val cur = current(session, key)
                val item = try {
                    parse(raw as JsonObject).also {
                        if (mt(it) < resetTime) throw InvalidItem("Item was modified after a reset")
                        accepted += key
                    }
                } catch (e: InvalidItem) {
                    failed += key
                    errors += e.message.orEmpty()
                    cur ?: continue
                }
                val winner = if (cur != null && mt(cur) > mt(item)) cur else item
                store(session, winner, stamp(serverTime, cur?.let(st)))
            }
        }
        return PushResponse(accepted, failed, errors + List(keyless) { "Got item that is not a dict with str 'key' field." })
    }

    private fun resetTime(session: Session, user: String): Double =
        userInfo.get(session, user, "reset_time")?.jsonPrimitive?.doubleOrNull ?: -1.0

    private fun stamp(serverTime: Double, current: Double?) =
        if (current == null) serverTime else maxOf(serverTime, current + 0.0001)
}

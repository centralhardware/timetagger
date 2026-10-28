package timetagger.service

import timetagger.Invalid
import timetagger.NotFound
import timetagger.db.Database
import timetagger.db.SettingRepository
import timetagger.model.Setting
import timetagger.model.SettingInput
import java.time.Instant

private val KEY = Regex("[A-Za-z0-9_.-]{1,64}")
private const val VALUE_MAX = 8192

class SettingService(private val db: Database, private val settings: SettingRepository) {
    suspend fun all(userId: Long): List<Setting> = db.io { settings.all(it, userId) }

    suspend fun get(userId: Long, key: String): Setting = db.io { settings.get(it, userId, key) } ?: throw NotFound("setting $key")

    /** Last write wins: an edit older than the stored one is ignored and the stored setting returned. */
    suspend fun put(userId: Long, key: String, input: SettingInput): Setting = db.tx { session ->
        if (!KEY.matches(key)) throw Invalid("key must be 1-64 letters, digits, '.', '-' or '_'")
        if (input.value.toString().length > VALUE_MAX) throw Invalid("value must be at most $VALUE_MAX characters as JSON")
        val modifiedAt = input.modifiedAt ?: Instant.now()
        val cur = settings.get(session, userId, key)
        if (cur != null && cur.modifiedAt > modifiedAt) cur else settings.save(session, userId, key, input.value, modifiedAt)
    }
}

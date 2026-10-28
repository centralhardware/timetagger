package timetagger.service

import timetagger.Invalid
import timetagger.NotFound
import timetagger.db.Database
import timetagger.db.SettingRepository
import timetagger.model.Setting
import timetagger.model.SettingInput

private val KEY = Regex("[A-Za-z0-9_.-]{1,64}")
private const val VALUE_MAX = 8192

class SettingService(private val db: Database, private val settings: SettingRepository) {
    suspend fun all(userId: Long): List<Setting> = db.io { settings.all(it, userId) }

    suspend fun get(userId: Long, key: String): Setting = db.io { settings.get(it, userId, key) } ?: throw NotFound("setting $key")

    /** A write based on a stale revision is ignored and the stored setting returned. */
    suspend fun put(userId: Long, key: String, input: SettingInput): Setting = db.write(userId) { session ->
        if (!KEY.matches(key)) throw Invalid("key must be 1-64 letters, digits, '.', '-' or '_'")
        if (input.value.toString().length > VALUE_MAX) throw Invalid("value must be at most $VALUE_MAX characters as JSON")
        val cur = settings.get(session, userId, key)
        if (cur != null && input.revision != null && input.revision != cur.revision) cur else settings.save(session, userId, key, input.value)
    }
}

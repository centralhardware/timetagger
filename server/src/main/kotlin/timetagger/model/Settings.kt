package timetagger.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class Setting(val key: String, val value: JsonElement, val revision: Long)

@Serializable
data class SettingInput(
    val value: JsonElement,
    /** The revision the client last read; a stale one leaves the stored setting as it is. Omit to overwrite. */
    val revision: Long? = null,
)

@Serializable
data class SettingList(val settings: List<Setting>)

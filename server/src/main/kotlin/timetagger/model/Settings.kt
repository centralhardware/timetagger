package timetagger.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class Setting(val key: String, val value: JsonElement, val modifiedAt: IsoInstant, val revision: Long)

@Serializable
data class SettingInput(val value: JsonElement, val modifiedAt: IsoInstant? = null)

@Serializable
data class SettingList(val settings: List<Setting>)

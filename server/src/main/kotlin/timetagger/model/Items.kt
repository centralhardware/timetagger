package timetagger.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** A time record. A running record has t1 == t2; deleted records are tombstones. */
@Serializable
data class Record(
    val key: String,
    val mt: Long,
    val t1: Long,
    val t2: Long,
    val ds: String = "",
    val deleted: Int = 0,
    /** Server time of the last write, assigned by the server. */
    val st: Double? = null,
)

/** A user setting; the value is arbitrary JSON. */
@Serializable
data class Setting(val key: String, val mt: Long, val value: JsonElement, val st: Double? = null)

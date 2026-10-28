package timetagger.model

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Values must be *shorter* than these limits.
const val STR_MAX = 256
const val JSON_MAX = 8192

class InvalidItem(message: String) : IllegalArgumentException(message)

/**
 * Parses incoming items leniently, like the old pydantic models: unknown fields
 * are ignored and integers may arrive as whole floats or numeric strings.
 */
object ItemParser {
    fun record(o: JsonObject) = Record(
        key = string(o, "key") ?: missing("key"),
        mt = long(o, "mt") ?: missing("mt"),
        t1 = long(o, "t1") ?: missing("t1"),
        t2 = long(o, "t2") ?: missing("t2"),
        ds = string(o, "ds") ?: "",
        deleted = long(o, "deleted")?.toInt() ?: 0,
    )

    fun setting(o: JsonObject): Setting {
        val value = o["value"] ?: missing("value")
        if (value.toString().length >= JSON_MAX) throw InvalidItem("Value must be less than $JSON_MAX chars when jsonized.")
        return Setting(key = string(o, "key") ?: missing("key"), mt = long(o, "mt") ?: missing("mt"), value = value)
    }

    /** The item's key, if it is an object with a string key at all. */
    fun key(o: Any?): String? = ((o as? JsonObject)?.get("key") as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun missing(field: String): Nothing = throw InvalidItem("$field: Field required")

    private fun string(o: JsonObject, field: String): String? {
        val v = o[field]
        if (v == null || v is JsonNull) return null
        val p = v as? JsonPrimitive
        if (p == null || !p.isString) throw InvalidItem("$field: Input should be a valid string")
        if (p.content.length > STR_MAX - 1) throw InvalidItem("$field: String should have at most ${STR_MAX - 1} characters")
        return p.content
    }

    private fun long(o: JsonObject, field: String): Long? {
        val p = o[field] as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        val d = p.content.trim().toDoubleOrNull()
        if (d == null || d.isInfinite() || d != Math.floor(d)) throw InvalidItem("$field: Input should be a valid integer")
        return d.toLong()
    }
}

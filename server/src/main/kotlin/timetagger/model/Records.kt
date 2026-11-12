package timetagger.model

import kotlinx.serialization.Serializable

/** A time record. It is running while `stop` is null; a deleted record keeps its row so clients sync the delete. */
@Serializable
data class Record(
    /** Assigned by the server when the record is created. */
    val id: Long,
    val start: IsoInstant,
    val stop: IsoInstant?,
    val description: String,
    /** Upper case ticket key such as "SM-1176", or null. */
    val ticket: String? = null,
    /** Lower case, sorted; stored apart from the description. */
    val tags: List<String>,
    val deletedAt: IsoInstant?,
    /** Increases with every write; see GET /changes. */
    val revision: Long,
)

/**
 * The body of POST /records and PUT /records/{id}. In POST /records/batch an entry
 * with an id updates that record and one without creates a new record.
 */
@Serializable
data class RecordInput(
    val id: Long? = null,
    val start: IsoInstant,
    val stop: IsoInstant? = null,
    val description: String = "",
    /** The ticket key; see [Tickets.normalize]. Null or blank clears it. */
    val ticket: String? = null,
    /** Replaces the record's tags; see [Tags.normalize]. */
    val tags: List<String> = emptyList(),
    /** Marks the record deleted (or restores it with false). */
    val deleted: Boolean = false,
    /** The revision the client last read; if the record has moved on since, the write is rejected with 409. Omit to overwrite. */
    val revision: Long? = null,
)

/** The user's tags, most recently used first. */
@Serializable
data class TagList(val tags: List<String>)

@Serializable
data class RecordBatch(val records: List<RecordInput>)

@Serializable
data class RecordList(val records: List<Record>)

object Tickets {
    private val valid = Regex("[A-Z][A-Z0-9]*-[0-9]+")

    /** Upper case and trimmed; null for none; throws [IllegalArgumentException] when it isn't a key like "SM-1176". */
    fun normalize(ticket: String?): String? {
        val t = ticket?.trim()?.removePrefix("#")?.uppercase()?.takeIf { it.isNotEmpty() } ?: return null
        require(valid.matches(t)) { "a ticket must look like SM-1176" }
        return t
    }
}

object Tags {
    private val valid = Regex("[^\\s#,]+")

    /** Lower case, without a leading '#', de-duplicated and sorted; null when a tag is malformed. */
    fun normalize(tags: List<String>): List<String>? {
        val out = tags.map { it.trim().removePrefix("#").lowercase() }.filter { it.isNotEmpty() }
        if (out.any { !valid.matches(it) }) return null
        return out.distinct().sorted()
    }
}

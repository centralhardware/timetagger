package timetagger.model

import kotlinx.serialization.Serializable

/** A time record. It is running while `stop` is null; a deleted record keeps its row so clients sync the delete. */
@Serializable
data class Record(
    val key: String,
    val start: IsoInstant,
    val stop: IsoInstant?,
    val description: String,
    /** The #tags in the description, lower case, without the '#'. */
    val tags: List<String>,
    val deletedAt: IsoInstant?,
    /** When a client last edited it; the newest edit wins. */
    val modifiedAt: IsoInstant,
    /** Increases with every write; see GET /changes. */
    val revision: Long,
)

/** The body of PUT /records/{key}, and one entry of POST /records/batch (which also carries the key). */
@Serializable
data class RecordInput(
    val key: String? = null,
    val start: IsoInstant,
    val stop: IsoInstant? = null,
    val description: String = "",
    /** Marks the record deleted (or restores it with false). */
    val deleted: Boolean = false,
    /** Defaults to now. An edit older than the stored one is rejected with 409. */
    val modifiedAt: IsoInstant? = null,
)

@Serializable
data class RecordBatch(val records: List<RecordInput>)

@Serializable
data class RecordList(val records: List<Record>)

object Tags {
    private val pattern = Regex("#([^\\s#,]+)")

    fun of(description: String): List<String> = pattern.findAll(description).map { it.groupValues[1].lowercase() }.distinct().sorted().toList()
}

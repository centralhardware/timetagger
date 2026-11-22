package timetagger.model

import kotlinx.serialization.Serializable

/**
 * A stretch of time on one device. Times are ISO-8601 instants.
 * kind "app": [bundleId] was frontmost, [title] its focused window's title ("" when unknown).
 * kind "away": the user was not at the Mac; [bundleId] and [appName] give why: idle, lock or sleep.
 */
@Serializable
data class UsageBlock(
    val device: String,
    val bundleId: String,
    val appName: String,
    val start: String,
    val stop: String,
    val kind: String = "app",
    val title: String = "",
)

@Serializable
data class UsageBatch(val blocks: List<UsageBlock>)

@Serializable
data class UsageList(val blocks: List<UsageBlock>)

@Serializable
data class TitleTotal(val title: String, val seconds: Long)

/** Seconds per app within the requested range, biggest first, with its top window titles. */
@Serializable
data class UsageTotal(val bundleId: String, val appName: String, val seconds: Long, val titles: List<TitleTotal> = emptyList())

@Serializable
data class UsageSummary(
    val from: String,
    val to: String,
    /** Time in front of some app. */
    val totalSeconds: Long,
    /** Time away from the Mac (idle, locked, asleep). */
    val awaySeconds: Long,
    /** How often the Mac was picked up: away blocks ended by an unlock or wake. */
    val pickups: Long,
    val apps: List<UsageTotal>,
    /** Set when the summary covers a record or ticket instead of a plain range. */
    val record: Long? = null,
    val ticket: String? = null,
)

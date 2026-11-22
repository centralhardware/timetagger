package timetagger.model

import kotlinx.serialization.Serializable

/** A stretch of time one app was frontmost on one device. Times are ISO-8601 instants. */
@Serializable
data class UsageBlock(
    val device: String,
    val bundleId: String,
    val appName: String,
    val start: String,
    val stop: String,
)

@Serializable
data class UsageBatch(val blocks: List<UsageBlock>)

@Serializable
data class UsageList(val blocks: List<UsageBlock>)

/** Seconds per app within the requested range, biggest first. */
@Serializable
data class UsageTotal(val bundleId: String, val appName: String, val seconds: Long)

@Serializable
data class UsageSummary(val from: String, val to: String, val totalSeconds: Long, val apps: List<UsageTotal>)

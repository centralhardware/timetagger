package timetagger.model

import kotlinx.serialization.Serializable

/** A set of records the user switches between (Work, Personal, ...). */
@Serializable
data class Workspace(val id: Long, val name: String, val deletedAt: IsoInstant?, val revision: Long)

@Serializable
data class WorkspaceInput(val name: String)

@Serializable
data class WorkspaceList(val workspaces: List<Workspace>)

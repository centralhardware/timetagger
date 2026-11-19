package timetagger.service

import timetagger.Invalid
import timetagger.NotFound
import timetagger.db.Database
import timetagger.db.WorkspaceRepository
import timetagger.model.Workspace

private const val NAME_MAX = 100

class WorkspaceService(private val db: Database, private val workspaces: WorkspaceRepository) {
    suspend fun all(userId: Long): List<Workspace> = db.io { workspaces.all(it, userId) }

    suspend fun create(userId: Long, name: String): Workspace = db.write(userId) { session ->
        val n = name(name)
        if (workspaces.byName(session, userId, n) != null) throw Invalid("a workspace named $n already exists")
        workspaces.create(session, userId, n)
    }

    suspend fun rename(userId: Long, id: String, name: String): Workspace = db.write(userId) { session ->
        val ws = live(session, userId, id)
        val n = name(name)
        workspaces.byName(session, userId, n)?.let { if (it.id != ws.id) throw Invalid("a workspace named $n already exists") }
        workspaces.rename(session, userId, ws.id, n)
    }

    /** The workspace's records stay; they just stop showing under any live workspace. */
    suspend fun delete(userId: Long, id: String) = db.write(userId) { session -> workspaces.delete(session, userId, live(session, userId, id).id) }

    private fun live(session: kotliquery.Session, userId: Long, id: String): Workspace =
        id.toLongOrNull()?.let { workspaces.get(session, userId, it) }?.takeIf { it.deletedAt == null } ?: throw NotFound("workspace $id")

    private fun name(name: String): String {
        val n = name.trim()
        if (n.isEmpty() || n.length > NAME_MAX) throw Invalid("a workspace name must be 1-$NAME_MAX characters")
        return n
    }
}

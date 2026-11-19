package timetagger.db

import kotliquery.Row
import kotliquery.Session
import kotliquery.queryOf
import timetagger.model.Workspace

class WorkspaceRepository {
    private val select = "SELECT id, name, deleted_at, revision FROM workspaces"

    private fun workspace(row: Row) = Workspace(row.long("id"), row.string("name"), row.instantOrNull("deleted_at"), row.long("revision"))

    /** Live workspaces, by name. */
    fun all(session: Session, userId: Long): List<Workspace> =
        session.list(queryOf("$select WHERE user_id = ? AND deleted_at IS NULL ORDER BY lower(name)", userId), ::workspace)

    fun get(session: Session, userId: Long, id: Long): Workspace? =
        session.single(queryOf("$select WHERE user_id = ? AND id = ?", userId, id), ::workspace)

    fun byName(session: Session, userId: Long, name: String): Workspace? =
        session.single(queryOf("$select WHERE user_id = ? AND deleted_at IS NULL AND lower(name) = lower(?)", userId, name), ::workspace)

    fun changedSince(session: Session, userId: Long, revision: Long): List<Workspace> =
        session.list(queryOf("$select WHERE user_id = ? AND revision > ? ORDER BY revision", userId, revision), ::workspace)

    fun create(session: Session, userId: Long, name: String): Workspace =
        session.single(queryOf("INSERT INTO workspaces (user_id, name) VALUES (?, ?) RETURNING id", userId, name)) { it.long("id") }!!
            .let { get(session, userId, it)!! }

    fun rename(session: Session, userId: Long, id: Long, name: String): Workspace {
        session.update(queryOf("UPDATE workspaces SET name = ?, updated_at = now(), revision = nextval('revision_seq') WHERE user_id = ? AND id = ?", name, userId, id))
        return get(session, userId, id)!!
    }

    fun delete(session: Session, userId: Long, id: Long) {
        session.update(
            queryOf(
                "UPDATE workspaces SET deleted_at = now(), updated_at = now(), revision = nextval('revision_seq') " +
                    "WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
                userId, id,
            ),
        )
    }
}

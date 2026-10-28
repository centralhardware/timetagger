package timetagger.routes

import io.ktor.http.HttpStatusCode
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.principal
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import timetagger.ApiException
import timetagger.Invalid
import timetagger.auth.TokenKind
import timetagger.auth.TokenService
import timetagger.model.Me
import timetagger.model.TokenResponse

/** POST /sessions with HTTP Basic credentials → a web token. */
fun Route.sessionRoutes(tokens: TokenService) {
    post("sessions") {
        val (token, expiresAt) = tokens.issue(call.principal<UserIdPrincipal>()!!.name, TokenKind.WEB)
        call.respond(HttpStatusCode.Created, TokenResponse(token, expiresAt))
    }
}

/**
 * GET /me; POST /tokens → an API token (only with a web token);
 * DELETE /tokens/{kind} revokes every web or API token.
 */
fun Route.tokenRoutes(tokens: TokenService) {
    get("me") { call.respond(Me(call.auth.username)) }
    post("tokens") {
        if (call.auth.kind != TokenKind.WEB) {
            throw ApiException(HttpStatusCode.Forbidden, "forbidden", "API tokens can only be made with a web token")
        }
        val (token, expiresAt) = tokens.issue(call.auth.username, TokenKind.API)
        call.respond(HttpStatusCode.Created, TokenResponse(token, expiresAt))
    }
    delete("tokens/{kind}") {
        val kind = TokenKind.of(call.path("kind")) ?: throw Invalid("kind must be web or api")
        tokens.revoke(call.auth.userId, kind)
        call.respond(HttpStatusCode.NoContent)
    }
}

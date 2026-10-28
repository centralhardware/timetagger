package timetagger.auth

import io.ktor.http.HttpStatusCode
import io.ktor.server.auth.AuthenticationConfig
import io.ktor.server.auth.AuthenticationContext
import io.ktor.server.auth.AuthenticationFailedCause
import io.ktor.server.auth.AuthenticationProvider
import io.ktor.server.response.respondText

/**
 * Authenticates requests by the `authtoken` header. With proxy auth on, the
 * token's user must also match the proxy's user header when one is sent.
 */
class TokenAuthenticationProvider(config: Config) : AuthenticationProvider(config) {
    private val tokens = config.tokens
    private val proxyHeader = config.proxyHeader

    class Config(name: String?) : AuthenticationProvider.Config(name) {
        lateinit var tokens: TokenService
        /** Set when proxy auth is enabled. */
        var proxyHeader: String? = null
    }

    override suspend fun onAuthenticate(context: AuthenticationContext) {
        val call = context.call
        val error = try {
            val info = tokens.authenticate(call.request.headers["authtoken"].orEmpty())
            val proxyUser = proxyHeader?.let { call.request.headers[it].orEmpty().trim() }.orEmpty()
            if (proxyUser.isNotEmpty() && proxyUser != info.username) throw AuthException("Autheticated user does not match proxy user")
            context.principal(info)
            return
        } catch (e: AuthException) {
            e.message.orEmpty()
        }
        context.challenge("authtoken", AuthenticationFailedCause.InvalidCredentials) { challenge, c ->
            c.respondText("unauthorized: $error", status = HttpStatusCode.Unauthorized)
            challenge.complete()
        }
    }
}

fun AuthenticationConfig.token(name: String? = null, configure: TokenAuthenticationProvider.Config.() -> Unit) {
    register(TokenAuthenticationProvider(TokenAuthenticationProvider.Config(name).apply(configure)))
}

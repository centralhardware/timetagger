package timetagger.auth

import io.ktor.http.HttpStatusCode
import kotlinx.serialization.Serializable
import timetagger.ApiException
import timetagger.config.Config

/** The body of POST bootstrap_authentication, base64-encoded JSON. */
@Serializable
data class LoginRequest(val method: String = "unspecified", val username: String = "", val password: String = "")

/** Where a login request came from, as far as the trust checks care. */
data class LoginOrigin(val serverHost: String, val remoteAddress: String, val proxyUser: String)

/** Exchanges some form of trust (password, localhost, a trusted proxy) for a web token. */
class LoginService(private val config: Config, private val passwords: PasswordService, private val tokens: TokenService) {
    private val trustedProxies = IpRanges(config.proxyAuthTrusted)

    suspend fun login(req: LoginRequest, origin: LoginOrigin): String {
        val user = when (req.method) {
            "usernamepassword" -> {
                if (!passwords.verify(req.username, req.password.trim())) forbidden("Invalid credentials")
                req.username.trim()
            }
            "localhost" -> {
                if (!config.bind.startsWith("127.0.0.1")) {
                    forbidden("Can only login via localhost if the server address (config.bind) is '127.0.0.1'")
                }
                if (config.proxyAuthEnabled) forbidden("forbidden: disabled when proxy auth is available")
                if (origin.serverHost !in setOf("localhost", "127.0.0.1")) forbidden("forbidden: must be on localhost")
                "defaultuser"
            }
            "proxy" -> {
                if (!config.proxyAuthEnabled) forbidden("forbidden: proxy auth is not enabled")
                if (!trustedProxies.contains(origin.remoteAddress)) forbidden("forbidden: the proxy is not trusted")
                origin.proxyUser.ifEmpty { forbidden("forbidden: no proxy user provided") }
            }
            else -> throw ApiException(HttpStatusCode.Unauthorized, "Invalid authentication method: ${req.method}")
        }
        return tokens.issue(user, TokenKind.WEB)
    }

    private fun forbidden(message: String): Nothing = throw ApiException(HttpStatusCode.Forbidden, message)
}

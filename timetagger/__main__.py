"""
Default script to run timetagger.

The timetagger library behaves like a framework; it provides the
building blocks to setup a timetracking app. This script puts things
together in the "default way". You can also create your own script to
customize/extend timetagger or embed in it a larger application.

A major hurdle in deploying an app like this is user authentication.
Timetagger implements its own token-based authentication, but it needs
to be "bootstrapped": the server needs to provide the first webtoken
when it has established trust in some way.

This script implements two methods to do this:
* A single-user login when client and server are on the same machine (localhost).
* Authentication with credentials specified as config params.

If you want another form of login, you will need to implement that yourself,
using a modified version of this script.
"""

import sys
import json
import asyncio
import logging
from base64 import b64decode
from importlib import resources

import asgineer
import pscript
import iptools
import timetagger
from timetagger import config
from timetagger.server import (
    authenticate,
    AuthException,
    api_handler_triage,
    get_webtoken_unsafe,
    create_assets_from_dir,
    enable_service_worker,
)
from timetagger.server import _credentials


def _run_user_admin(cmd, args):
    """Handle the `user-*` CLI commands for managing login credentials."""

    async def _run():
        try:
            if cmd in ("user-list", "users"):
                users = await _credentials.list_users()
                print("\n".join(users) if users else "(no users)")
            elif cmd in ("user-add", "user-set", "user-set-password"):
                if len(args) < 2:
                    print(f"Usage: python -m timetagger {cmd} <username> <password>")
                    return 2
                await _credentials.set_password(args[0], args[1])
                print(f"Saved credentials for user {args[0]!r}.")
            elif cmd in ("user-remove", "user-del", "user-delete"):
                if len(args) < 1:
                    print(f"Usage: python -m timetagger {cmd} <username>")
                    return 2
                removed = await _credentials.delete_user(args[0])
                print(f"Removed user {args[0]!r}." if removed else "No such user.")
            else:
                print(f"Unknown user command: {cmd}")
                return 2
            return 0
        finally:
            await _credentials.close()

    return asyncio.run(_run())


# Special hooks exit early
if __name__ == "__main__" and len(sys.argv) >= 2:
    if sys.argv[1] in ("--version", "version"):
        print("timetagger", timetagger.__version__)
        print("asgineer", asgineer.__version__)
        print("pscript", pscript.__version__)
        sys.exit(0)
    elif sys.argv[1] in (
        "user-list",
        "users",
        "user-add",
        "user-set",
        "user-set-password",
        "user-remove",
        "user-del",
        "user-delete",
    ):
        sys.exit(_run_user_admin(sys.argv[1], sys.argv[2:]))


logger = logging.getLogger("asgineer")

# Get sets of assets provided by TimeTagger
common_assets = create_assets_from_dir(resources.files("timetagger.common"))
apponly_assets = create_assets_from_dir(resources.files("timetagger.app"))
image_assets = create_assets_from_dir(resources.files("timetagger.images"))
page_assets = create_assets_from_dir(resources.files("timetagger.pages"))

# Combine into two groups. You could add/replace assets here.
app_assets = dict(**common_assets, **image_assets, **apponly_assets)
web_assets = dict(**common_assets, **image_assets, **page_assets)

# Enable the service worker so the app can be used offline and is installable
enable_service_worker(app_assets)

# Turn asset dicts into handlers. This feature of Asgineer provides
# lightning fast handlers that support compression and HTTP caching.
app_asset_handler = asgineer.utils.make_asset_handler(app_assets, max_age=0)
web_asset_handler = asgineer.utils.make_asset_handler(web_assets, max_age=0)


@asgineer.to_asgi
async def main_handler(request):
    """
    The main handler where we delegate to the API or asset handler.

    We serve at /timetagger for a few reasons, one being that the service
    worker won't interfere with other stuff you might serve on localhost.
    """

    # Redirect the root path straight to the app (there is no landing page)
    if request.path == "/":
        return 307, {"Location": f"{config.path_prefix}app/"}, b""

    # Handle application requests
    if request.path.startswith(config.path_prefix):
        if request.path == f"{config.path_prefix}status":
            return 200, {}, "ok"
        elif request.path.startswith(f"{config.path_prefix}api/v2/"):
            path = request.path.removeprefix(f"{config.path_prefix}api/v2/").strip("/")
            return await api_handler(request, path)
        elif request.path.startswith(f"{config.path_prefix}app/"):
            path = request.path.removeprefix(f"{config.path_prefix}app/").strip("/")
            return await app_asset_handler(request, path)
        else:
            path = request.path.removeprefix(f"{config.path_prefix}").strip("/")
            # The prefix root has no landing page either; go to the app
            if not path:
                return 307, {"Location": f"{config.path_prefix}app/"}, b""
            return await web_asset_handler(request, path)

    # Fallback Error 404
    else:
        return 404, {}, f"only serving at {config.path_prefix}"


async def api_handler(request, path):
    """The default API handler. Designed to be short, so that
    applications that implement alternative authentication and/or have
    more API endpoints can use this as a starting point.
    """

    # Some endpoints do not require authentication
    if not path and request.method == "GET":
        return 200, {}, "See https://timetagger.readthedocs.io"
    elif path == "bootstrap_authentication":
        # The client-side that requests these is in pages/login.md
        return await get_webtoken(request)

    # Authenticate and get user db
    try:
        auth_info, db = await authenticate(request)
        # Only validate if proxy auth is enabled
        if config.proxy_auth_enabled:
            await validate_auth(request, auth_info)
    except AuthException as err:
        return 401, {}, f"unauthorized: {err}"

    # Handle endpoints that require authentication
    return await api_handler_triage(request, path, auth_info, db)


async def get_webtoken(request):
    """Exhange some form of trust for a webtoken."""

    auth_info = json.loads(b64decode(await request.get_body()))
    method = auth_info.get("method", "unspecified")

    if method == "localhost":
        return await get_webtoken_localhost(request, auth_info)
    elif method == "usernamepassword":
        return await get_webtoken_usernamepassword(request, auth_info)
    elif method == "proxy":
        return await get_webtoken_proxy(request, auth_info)
    else:
        return 401, {}, f"Invalid authentication method: {method}"


async def get_webtoken_proxy(request, auth_info):
    """An authentication handler that provides a webtoken when
    the user is autheticated through a trusted reverse proxy
    by a given header. See `get_webtoken_unsafe()` for details.
    """

    # Check if proxy auth is enabled
    if not config.proxy_auth_enabled:
        return 403, {}, "forbidden: proxy auth is not enabled"

    # Check if the request comes from a trusted proxy
    client = request.scope["client"][0]
    if client not in TRUSTED_PROXIES:
        return 403, {}, "forbidden: the proxy is not trusted"

    # Get username from request header
    user = await get_username_from_proxy(request)
    if not user:
        return 403, {}, "forbidden: no proxy user provided"

    # Return the webtoken for proxy user
    token = await get_webtoken_unsafe(user)
    return 200, {}, dict(token=token)


async def get_username_from_proxy(request):
    """Returns the username that is provided by the reverse proxy
    through the request headers.
    """

    return request.headers.get(config.proxy_auth_header.lower(), "").strip()


async def get_webtoken_usernamepassword(request, auth_info):
    """An authentication handler to exchange credentials for a webtoken.
    The credentials are stored (bcrypt-hashed) in the `credentials` table
    in PostgreSQL and managed via the `python -m timetagger user-*` CLI.
    See `get_webtoken_unsafe()` for details.
    """
    # Seed any legacy env credentials into the DB (once, no overwrite).
    await _ensure_credentials_seeded()

    # Get credentials from request
    user = auth_info.get("username", "").strip()
    pw = auth_info.get("password", "").strip()
    # Check against the database
    if await _credentials.verify_password(user, pw):
        token = await get_webtoken_unsafe(user)
        return 200, {}, dict(token=token)
    else:
        return 403, {}, "Invalid credentials"


_credentials_seeded = False


async def _ensure_credentials_seeded():
    """One-time migration: copy `config.credentials` (env) into the DB table."""
    global _credentials_seeded
    if _credentials_seeded:
        return
    _credentials_seeded = True
    if config.credentials.strip():
        await _credentials.seed_from_env_credentials(config.credentials)


async def get_webtoken_localhost(request, auth_info):
    """An authentication handler that provides a webtoken when the
    hostname is localhost. See `get_webtoken_unsafe()` for details.
    """
    if not config.bind.startswith("127.0.0.1"):
        return (
            403,
            {},
            "Can only login via localhost if the server address (config.bind) is '127.0.0.1'",
        )
    # Don't allow localhost validation when proxy auth is enabled
    if config.proxy_auth_enabled:
        return 403, {}, "forbidden: disabled when proxy auth is available"
    # Establish that we can trust the client
    if request.host not in ("localhost", "127.0.0.1"):
        return 403, {}, "forbidden: must be on localhost"
    # Return the webtoken for the default user
    token = await get_webtoken_unsafe("defaultuser")
    return 200, {}, dict(token=token)


async def validate_auth(request, auth_info):
    """Validates that the autheticated user is still the same that
    is provided by the reverse proxy.
    """

    # Check that the proxy user is the same
    proxy_user = await get_username_from_proxy(request)
    if proxy_user and proxy_user != auth_info["username"]:
        raise AuthException("Autheticated user does not match proxy user")


def load_trusted_proxies():
    ips = [s.strip() for s in config.proxy_auth_trusted.replace(";", ",").split(",")]
    return iptools.IpRangeList(*ips)


TRUSTED_PROXIES = load_trusted_proxies()


if __name__ == "__main__":
    asgineer.run(
        "timetagger.__main__:main_handler", "uvicorn", config.bind, log_level="warning"
    )

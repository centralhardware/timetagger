import os
import sys


def to_bool(value):
    """Converts a string to a bool"""
    stringValue = str(value).lower()
    if stringValue in ["true", "yes", "on", "1"]:
        return True
    return False


def to_path_prefix(value):
    """Ensures that a path prefix starts and ends with '/'"""
    path_prefix = str(value).strip()
    if not path_prefix.startswith("/"):
        path_prefix = "/" + path_prefix
    if not path_prefix.endswith("/") and path_prefix != "/":
        path_prefix = path_prefix + "/"
    return path_prefix


class Config:
    """Object that holds config values.

    * `bind (str)`: the address and port to bind on. Default "127.0.0.1:8080".
    * `db_uri (str)`: the PostgreSQL connection string, e.g.
      "postgresql://user:pass@host:5432/timetagger". This is REQUIRED:
      TimeTagger stores all user data in this database. There is no SQLite
      fallback.
    * `jwt_key (str)`: secret used to sign JWT auth tokens. TimeTagger never
      writes to disk, so when this is empty an ephemeral key is generated in
      memory and all sessions are invalidated on restart. Set it to a long
      random secret in production.
    * `log_level (str)`: the log level for timetagger and asgineer
      (not the asgi server). Default "info".
    * `proxy_auth_enabled (bool)`: enables authentication from a reverse proxy
      (for example Authelia). Default "False".
    * `proxy_auth_trusted (str)`: list of trusted reverse proxy IPs with or without CIDR, in the
      form "127.0.0.1,10.0.0.1,10.99.0.0/24,192.168/16". Default "127.0.0.1".
    * `proxy_auth_header (str)`: name of the proxy header which contains the
      username of the logged in user. Default "X-Remote-User".
    * `path_prefix (str)`: the path prefix where timetagger is served. Default "/timetagger/".

    The values can be configured using CLI arguments and environment variables.
    For CLI arguments, the following formats are supported:
    ```
    python -m timetagger --bind=0.0.0.0:80
    python -m timetagger --bind 0.0.0.0:80
    ```

    For environment variable, the key is uppercase and prefixed:
    ```
    TIMETAGGER_BIND=0.0.0.0:80
    ```
    """

    _ITEMS = [
        ("bind", str, "127.0.0.1:8080"),
        ("db_uri", str, ""),
        ("jwt_key", str, ""),
        ("log_level", str, "info"),
        ("proxy_auth_enabled", to_bool, False),
        ("proxy_auth_trusted", str, "127.0.0.1"),
        ("proxy_auth_header", str, "X-Remote-User"),
        ("path_prefix", to_path_prefix, "/timetagger/"),
    ]
    __slots__ = [name for name, _, _ in _ITEMS]


config = Config()


def set_config(argv=None, env=None):
    """Set config values. By default argv is sys.argv and env is os.environ."""
    if argv is None:
        argv = sys.argv
    if env is None:
        env = os.environ

    _reset_config_to_defaults()
    _update_config_from_argv(argv)
    _update_config_from_env(env)


def _reset_config_to_defaults():
    for name, _, default in Config._ITEMS:
        setattr(config, name, default)


def _update_config_from_argv(argv):
    for i in range(len(argv)):
        arg = argv[i]
        for config_attr, conv, _ in Config._ITEMS:
            for name in (config_attr, config_attr.replace("_", "-")):
                if arg.startswith(f"--{name}="):
                    _, _, raw_value = arg.partition("=")
                elif arg == f"--{name}":
                    if i + 1 < len(argv):
                        raw_value = argv[i + 1]
                    else:
                        raise RuntimeError(f"Value for {arg} not given")
                else:
                    continue
                try:
                    setattr(config, config_attr, conv(raw_value))
                except Exception as err:
                    raise RuntimeError(f"Could not set config.{config_attr}: {err}")
                break


def _update_config_from_env(env):
    for name, conv, _ in Config._ITEMS:
        env_name = f"TIMETAGGER_{name.upper()}"
        raw_value = env.get(env_name, None)
        if raw_value:
            try:
                setattr(config, name, conv(raw_value))
            except Exception as err:
                raise RuntimeError(f"Could not set config.{name}: {err}")


# Init config
set_config()

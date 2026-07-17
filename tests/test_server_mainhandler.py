"""Tests for main handler routing with path_prefix configuration."""

import sys

from asgineer.testutils import MockTestServer
from _common import run_tests

from timetagger import config
from timetagger._config import set_config


# Mock asset handlers to avoid compilation overhead
async def mock_app_asset_handler(request, path):
    """Mock app asset handler that returns identifiable response."""
    return 200, {}, "app"


async def mock_web_asset_handler(request, path):
    """Mock web asset handler that returns identifiable response."""
    return 200, {}, "web"


async def mock_api_handler(request, path):
    """Mock API handler that returns identifiable response."""
    if not path and request.method == "GET":
        return 200, {}, "api"
    return 200, {}, "api"


def get_main_handler():
    """Get the real main_handler with mocked asset handlers.

    This ensures we test the actual routing logic from __main__.py
    while avoiding the overhead of compiling assets.

    Returns:
        The main_handler function from timetagger.__main__.
    """
    # Remove cached module to force reimport with current config
    if "timetagger.__main__" in sys.modules:
        del sys.modules["timetagger.__main__"]

    # Import the module
    import timetagger.__main__ as main_module

    # Replace the asset handlers with mocks
    main_module.app_asset_handler = mock_app_asset_handler
    main_module.web_asset_handler = mock_web_asset_handler
    main_module.api_handler = mock_api_handler

    return main_module.main_handler


def test_path_prefix_default():
    """Test routing with default path_prefix (/timetagger/)."""
    set_config([], {})
    assert config.path_prefix == "/timetagger/"

    main_handler = get_main_handler()

    with MockTestServer(main_handler) as p:
        # Root should redirect straight to the app (no landing page)
        r = p.get("/")
        assert r.status == 307
        assert r.headers["location"] == "/timetagger/app/"

        # The prefix root should also redirect to the app
        r = p.get("/timetagger/")
        assert r.status == 307
        assert r.headers["location"] == "/timetagger/app/"

        # Status endpoint
        r = p.get("/timetagger/status")
        assert r.status == 200
        assert r.body.decode() == "ok"

        # App route
        r = p.get("/timetagger/app/")
        assert r.status == 200
        assert r.body.decode() == "app"

        # Other web assets (e.g. account/login pages) are still served
        r = p.get("/timetagger/account")
        assert r.status == 200
        assert r.body.decode() == "web"

        # API root
        r = p.get("/timetagger/api/v2/")
        assert r.status == 200
        assert r.body.decode() == "api"

        # Non-timetagger paths should 404
        r = p.get("/other/path")
        assert r.status == 404
        assert "only serving at /timetagger/" in r.body.decode()


def test_path_prefix_custom():
    """Test routing with custom path_prefix."""
    set_config(["--path_prefix=/custom/path/"], {})
    assert config.path_prefix == "/custom/path/"

    main_handler = get_main_handler()

    with MockTestServer(main_handler) as p:
        # Root should redirect to the app at the custom prefix
        r = p.get("/")
        assert r.status == 307
        assert r.headers["location"] == "/custom/path/app/"

        # The prefix root should also redirect to the app
        r = p.get("/custom/path/")
        assert r.status == 307
        assert r.headers["location"] == "/custom/path/app/"

        # Status endpoint at custom prefix
        r = p.get("/custom/path/status")
        assert r.status == 200
        assert r.body.decode() == "ok"

        # App route at custom prefix
        r = p.get("/custom/path/app/")
        assert r.status == 200
        assert r.body.decode() == "app"

        # API at custom prefix
        r = p.get("/custom/path/api/v2/")
        assert r.status == 200
        assert r.body.decode() == "api"

        # Old path should not work
        r = p.get("/timetagger/")
        assert r.status == 404
        assert "only serving at /custom/path/" in r.body.decode()


def test_path_prefix_root():
    """Test routing with path_prefix set to root (/)."""
    set_config(["--path_prefix=/"], {})
    assert config.path_prefix == "/"

    main_handler = get_main_handler()

    with MockTestServer(main_handler) as p:
        # Root should redirect to the app
        r = p.get("/")
        assert r.status == 307
        assert r.headers["location"] == "/app/"

        # Status at root
        r = p.get("/status")
        assert r.status == 200
        assert r.body.decode() == "ok"

        # App route at root
        r = p.get("/app/")
        assert r.status == 200
        assert r.body.decode() == "app"

        # API at root
        r = p.get("/api/v2/")
        assert r.status == 200
        assert r.body.decode() == "api"


def test_path_prefix_normalization():
    """Test that path_prefix is normalized correctly."""
    # Test various input formats
    test_cases = [
        ("custom", "/custom/"),
        ("/custom", "/custom/"),
        ("custom/", "/custom/"),
        ("/custom/", "/custom/"),
        ("custom/path", "/custom/path/"),
        ("/custom/path/", "/custom/path/"),
        ("/", "/"),
    ]

    for input_val, expected in test_cases:
        set_config([f"--path_prefix={input_val}"], {})
        assert (
            config.path_prefix == expected
        ), f"Input '{input_val}' should normalize to '{expected}', got '{config.path_prefix}'"


if __name__ == "__main__":
    run_tests(globals())

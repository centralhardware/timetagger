import time

from _common import run_tests
from timetagger.server import _utils as utils

from pytest import raises


def test_jwt_stuff():
    exp = time.time() + 100

    # The secret key must be a long enough string
    k = utils._load_jwt_key()
    assert isinstance(k, str) and len(k) > 10

    # Payload needs username, expires, seed.
    with raises(ValueError):
        token = utils.create_jwt({})
    with raises(ValueError):
        token = utils.create_jwt({"expires": exp, "seed": "x"})
    with raises(ValueError):
        token = utils.create_jwt({"username": "foo", "seed": "x"})
    with raises(ValueError):
        token = utils.create_jwt({"username": "foo", "expires": exp})

    # Get a JWT
    payload = {"username": "foo", "expires": exp, "seed": "x"}
    token = utils.create_jwt(payload)
    assert isinstance(token, str) and token.count(".") == 2

    # Decode it
    assert utils.decode_jwt(token) == payload

    # We can always decode the unsafe way
    assert utils.decode_jwt_nocheck(token) == payload

    # Cannot decode bullshit
    with raises(Exception):
        utils.decode_jwt("not.a.token")


def test_scss_stuff():
    text = """
    $foo: #fff;
    $bar: 1px solid $foo;
    p {
        border: $bar;
        color: $spam;
    }
    """

    css = """
    p {
        border: 1px solid #fff;
        color: red;
    }
    """

    vars = utils.get_scss_vars(text)
    assert vars == {"$foo": "#fff", "$bar": "1px solid $foo"}
    assert utils.compile_scss_to_css(text, spam="red") == css

    with raises(ValueError):
        utils.compile_scss_to_css(text)


if __name__ == "__main__":
    run_tests(globals())

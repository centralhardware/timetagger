import os

from _common import run_tests

import timetagger.app
from timetagger.server import _dtos


def _load_client_common():
    """Exec the COMMON PART of the client stores.py and return its namespace.

    The client (pscript) still declares the item contract as SPEC dicts; the
    server models it with pydantic DTOs. This test makes sure they agree.
    """
    t_begin = "# ----- COMMON PART"
    t_end = "# ----- END COMMON PART"
    filename = os.path.join(os.path.dirname(timetagger.app.__file__), "stores.py")
    code = open(filename, "rb").read().decode()
    block = code.split(t_begin)[1].split(t_end)[0]
    block = block.split("\n", 1)[1]  # drop the rest of the marker line
    ns = {"to_str": str, "to_int": int, "to_jsonable": lambda x: x}
    exec(block, ns)
    return ns


def _required(model):
    return {name for name, info in model.model_fields.items() if info.is_required()}


def test_matching_specs_and_reqs():
    """Ensure the client spec and the server DTOs use the same fields,
    required fields and limits. ``st`` is server-only, so it is excluded.
    """
    ns = _load_client_common()

    # Records
    assert set(ns["RECORD_SPEC"]) == set(_dtos.Record.model_fields) - {"st"}
    assert set(ns["RECORD_REQ"]) == _required(_dtos.Record)

    # Settings
    assert set(ns["SETTING_SPEC"]) == set(_dtos.Setting.model_fields) - {"st"}
    assert set(ns["SETTING_REQ"]) == _required(_dtos.Setting)

    # Limits
    assert ns["STR_MAX"] == _dtos.STR_MAX
    assert ns["JSON_MAX"] == _dtos.JSON_MAX


if __name__ == "__main__":
    run_tests(globals())

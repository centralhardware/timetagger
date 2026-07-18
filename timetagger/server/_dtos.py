"""
Typed data-transfer objects for the items that the API accepts and stores.

These are pydantic models: parsing, validation, coercion and (de)serialization
to/from JSON-able dicts are handled by the library, driven by the type hints.
``Model.model_validate(dict)`` validates an incoming item; ``model.model_dump()``
turns it back into a plain dict for the storage layer (see ``server/_pg.py``).

The wire/DB contract (field names, required fields, limits) is mirrored on the
client (``app/stores.py``); ``tests/test_both.py`` checks that they agree.
"""

import json
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Limits (mirrored on the client). Values must be *shorter* than the limit.
STR_MAX = 256
JSON_MAX = 8192


class _Item(BaseModel):
    # Ignore unknown incoming fields (old/new clients may send extra fields).
    model_config = ConfigDict(extra="ignore", validate_assignment=True)


class Record(_Item):
    """A time record. ``st`` (server time) is assigned by the server."""

    key: str = Field(max_length=STR_MAX - 1)
    mt: int
    t1: int
    t2: int
    ds: str = Field(default="", max_length=STR_MAX - 1)
    deleted: int = 0
    st: Optional[float] = None


class Setting(_Item):
    """A user setting. ``value`` is arbitrary (json-able) data."""

    key: str = Field(max_length=STR_MAX - 1)
    mt: int
    value: Any
    st: Optional[float] = None

    @field_validator("value")
    @classmethod
    def _check_value_size(cls, v):
        if len(json.dumps(v)) >= JSON_MAX:
            raise ValueError(f"Value must be less than {JSON_MAX} chars when jsonized.")
        return v


# Maps the API "what" to its DTO class.
DTO_CLASSES = {"records": Record, "settings": Setting}

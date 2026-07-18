"""
Typed data-transfer objects for the items stored in the database.

Every table has a DTO (``Record``, ``Setting``, ``UserInfo``). These are the
typed model used throughout the server, including the storage layer
(``server/_pg.py``), which reads and writes DTOs directly rather than loose
dicts. pydantic drives parsing, validation, coercion and (de)serialization.

Each DTO also carries its persistence metadata: the table name and, where the
readable database column differs from the short field name (the wire/client
contract), a ``column_overrides`` mapping. So the DTOs mirror the (typed)
database schema, and the two only ever change together via a migration.

The field names/limits are mirrored on the client (``app/stores.py``);
``tests/test_both.py`` checks that they agree.
"""

import json
from typing import Any, ClassVar, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Limits (mirrored on the client). Values must be *shorter* than the limit.
STR_MAX = 256
JSON_MAX = 8192


def _check_json_size(v):
    if len(json.dumps(v)) >= JSON_MAX:
        raise ValueError(f"Value must be less than {JSON_MAX} chars when jsonized.")
    return v


class Item(BaseModel):
    """Base for all stored items, with the persistence mapping."""

    # Ignore unknown incoming fields (old/new clients may send extra fields).
    model_config = ConfigDict(extra="ignore", validate_assignment=True)

    # Persistence metadata (overridden by subclasses).
    table_name: ClassVar[str] = ""
    key_field: ClassVar[str] = "key"
    # field name -> database column, only where they differ.
    column_overrides: ClassVar[dict] = {}

    @classmethod
    def column_for(cls, field):
        return cls.column_overrides.get(field, field)

    @classmethod
    def from_wire(cls, data):
        """Validate/coerce an incoming item dict into a DTO."""
        return cls.model_validate(data)

    @classmethod
    def from_row(cls, row):
        """Build a DTO from a trusted database row (no validation)."""
        data = {f: row[f] for f in cls.model_fields if row[f] is not None}
        return cls.model_construct(**data)

    def to_row(self):
        """Column -> value for the fields that are set (skips None)."""
        cls = type(self)
        return {
            cls.column_for(f): getattr(self, f)
            for f in cls.model_fields
            if getattr(self, f) is not None
        }


class Record(Item):
    """A time record. ``st`` (server time) is assigned by the server."""

    table_name: ClassVar[str] = "records"
    column_overrides: ClassVar[dict] = {
        "st": "server_time",
        "mt": "modified_time",
        "t1": "start_time",
        "t2": "stop_time",
        "ds": "description",
    }

    key: str = Field(max_length=STR_MAX - 1)
    mt: int
    t1: int
    t2: int
    ds: str = Field(default="", max_length=STR_MAX - 1)
    deleted: int = 0
    st: Optional[float] = None


class Setting(Item):
    """A user setting. ``value`` is arbitrary (json-able) data."""

    table_name: ClassVar[str] = "settings"
    column_overrides: ClassVar[dict] = {"st": "server_time", "mt": "modified_time"}

    key: str = Field(max_length=STR_MAX - 1)
    mt: int
    value: Any
    st: Optional[float] = None

    @field_validator("value")
    @classmethod
    def _check_value_size(cls, v):
        return _check_json_size(v)


class UserInfo(Item):
    """Server-internal per-user data (token seeds, reset time). Not sent by
    clients, so ``mt`` may be a fractional timestamp (it is set to ``st``)."""

    table_name: ClassVar[str] = "userinfo"
    column_overrides: ClassVar[dict] = {"st": "server_time", "mt": "modified_time"}

    key: str = Field(max_length=STR_MAX - 1)
    mt: float
    value: Any
    st: Optional[float] = None


# Maps the API "what" (records/settings) to its DTO class.
DTO_CLASSES = {"records": Record, "settings": Setting}

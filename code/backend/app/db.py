from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path


@dataclass(frozen=True)
class StoredEncoding:
    person_id: str
    encoding: list[float]


class Database:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.init()

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        return connection

    def init(self) -> None:
        with self.connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS people(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    reference_image BLOB,
                    relationship TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    last_seen TEXT
                );

                CREATE TABLE IF NOT EXISTS face_encodings(
                    id TEXT PRIMARY KEY,
                    person_id TEXT NOT NULL,
                    encoding_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY(person_id) REFERENCES people(id)
                );
                """
            )
            columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(people)").fetchall()
            }
            if "reference_image" not in columns:
                connection.execute("ALTER TABLE people ADD COLUMN reference_image BLOB")
            if "relationship" not in columns:
                connection.execute("ALTER TABLE people ADD COLUMN relationship TEXT NOT NULL DEFAULT ''")
            if "last_seen" not in columns:
                connection.execute("ALTER TABLE people ADD COLUMN last_seen TEXT")
            if "notes" not in columns:
                connection.execute("ALTER TABLE people ADD COLUMN notes TEXT NOT NULL DEFAULT ''")

    def create_person(self, name: str, description: str, relationship: str = "", notes: str = "", reference_image: bytes | None = None) -> dict:
        person_id = str(uuid.uuid4())
        created_at = _now()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO people(id, name, description, created_at, reference_image, relationship, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (person_id, name, description, created_at, reference_image, relationship, notes),
            )
        return {
            "id": person_id,
            "name": name,
            "description": description,
            "created_at": created_at,
            "relationship": relationship,
            "notes": notes,
            "last_seen": None,
        }

    def add_face_encoding(self, person_id: str, encoding: list[float]) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO face_encodings(id, person_id, encoding_json, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (str(uuid.uuid4()), person_id, json.dumps(encoding), _now()),
            )

    def get_person(self, person_id: str) -> dict | None:
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT id, name, description, created_at, relationship, notes, last_seen
                FROM people
                WHERE id = ?
                """,
                (person_id,),
            ).fetchone()
        return dict(row) if row else None

    def get_reference_image(self, person_id: str) -> bytes | None:
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT reference_image
                FROM people
                WHERE id = ?
                """,
                (person_id,),
            ).fetchone()
        if row is None:
            return None
        return row["reference_image"]

    def update_person(self, person_id: str, name: str, description: str, relationship: str = "", notes: str = "") -> dict | None:
        with self.connect() as connection:
            cursor = connection.execute(
                """
                UPDATE people
                SET name = ?, description = ?, relationship = ?, notes = ?
                WHERE id = ?
                """,
                (name, description, relationship, notes, person_id),
            )
            if cursor.rowcount == 0:
                return None

            row = connection.execute(
                """
                SELECT id, name, description, created_at, relationship, notes, last_seen
                FROM people
                WHERE id = ?
                """,
                (person_id,),
            ).fetchone()
        return dict(row) if row else None

    def delete_person(self, person_id: str) -> bool:
        with self.connect() as connection:
            connection.execute(
                """
                DELETE FROM face_encodings
                WHERE person_id = ?
                """,
                (person_id,),
            )
            cursor = connection.execute(
                """
                DELETE FROM people
                WHERE id = ?
                """,
                (person_id,),
            )
        return cursor.rowcount > 0

    def list_people(self) -> list[dict]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT id, name, description, created_at, relationship, notes, last_seen
                FROM people
                ORDER BY created_at DESC
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def update_last_seen(self, person_id: str) -> None:
        with self.connect() as connection:
            connection.execute(
                "UPDATE people SET last_seen = ? WHERE id = ?",
                (_now(), person_id),
            )

    def list_encodings(self) -> list[StoredEncoding]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT person_id, encoding_json
                FROM face_encodings
                """
            ).fetchall()
        return [
            StoredEncoding(
                person_id=row["person_id"],
                encoding=[float(value) for value in json.loads(row["encoding_json"])],
            )
            for row in rows
        ]


def _now() -> str:
    return datetime.now(UTC).isoformat()

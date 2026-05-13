from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests


class BackendError(RuntimeError):
    pass


@dataclass(frozen=True)
class RecognitionResult:
    status: str
    name: str | None
    description: str | None
    distance: float | None
    face_count: int

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> RecognitionResult:
        person = payload.get("person")
        return cls(
            status=payload["status"],
            name=person["name"] if person else None,
            description=person["description"] if person else None,
            distance=payload.get("distance"),
            face_count=payload["face_count"],
        )


@dataclass(frozen=True)
class Person:
    id: str
    name: str
    description: str

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> Person:
        return cls(
            id=payload["id"],
            name=payload["name"],
            description=payload["description"],
        )


class BackendClient:
    def __init__(self, base_url: str, session: requests.Session | None = None):
        self.base_url = base_url.rstrip("/")
        self.session = session or requests.Session()

    def health(self) -> str:
        response = self.session.get(f"{self.base_url}/health", timeout=10)
        payload = self._json_or_raise(response)
        return str(payload["status"])

    def recognize(self, jpeg_bytes: bytes) -> RecognitionResult:
        response = self.session.post(
            f"{self.base_url}/recognize",
            files={"file": ("webcam.jpg", jpeg_bytes, "image/jpeg")},
            timeout=30,
        )
        payload = self._json_or_raise(response)
        return RecognitionResult.from_json(payload)

    def create_person(self, name: str, description: str, jpeg_bytes: bytes) -> Person:
        response = self.session.post(
            f"{self.base_url}/people",
            data={"name": name, "description": description},
            files={"file": ("webcam.jpg", jpeg_bytes, "image/jpeg")},
            timeout=30,
        )
        payload = self._json_or_raise(response)
        return Person.from_json(payload)

    def _json_or_raise(self, response: requests.Response) -> dict[str, Any]:
        if response.status_code >= 400:
            raise BackendError(f"{response.status_code}: {_response_message(response)}")
        try:
            return response.json()
        except ValueError as exc:
            raise BackendError(f"Invalid JSON response: {response.text}") from exc


def _response_message(response: requests.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        return response.text

    detail = payload.get("detail") if isinstance(payload, dict) else None
    if isinstance(detail, str):
        return detail
    return response.text

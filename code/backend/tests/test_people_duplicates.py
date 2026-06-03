from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app
from app.recognition import FaceEncodingResult


class StaticRecognizer:
    def encode_faces(self, image_bytes: bytes) -> FaceEncodingResult:
        return FaceEncodingResult(encodings=[[0.1, 0.2, 0.3]], face_count=1)


def _client(tmp_path: Path) -> TestClient:
    app = create_app(db_path=tmp_path / "test.sqlite", recognizer=StaticRecognizer())
    return TestClient(app)


def _create_person(client: TestClient, name: str):
    return client.post(
        "/people",
        data={"name": name, "description": "", "relationship": ""},
        files={"file": ("face.jpg", b"fake image bytes", "image/jpeg")},
    )


def test_create_person_rejects_duplicate_name(tmp_path: Path) -> None:
    client = _client(tmp_path)

    first = _create_person(client, "Grace")
    assert first.status_code == 200

    duplicate = _create_person(client, " grace ")
    assert duplicate.status_code == 409
    assert "already exists" in duplicate.json()["detail"]

    people = client.get("/people").json()
    assert len(people) == 1
    assert people[0]["name"] == "Grace"


def test_duplicate_photo_can_be_combined_with_existing_person(tmp_path: Path) -> None:
    client = _client(tmp_path)

    person = _create_person(client, "Emily").json()
    assert client.get(f"/people/{person['id']}/photo-count").json()["count"] == 1

    response = client.post(
        f"/people/{person['id']}/photos",
        files={"file": ("extra.jpg", b"another face", "image/jpeg")},
    )
    assert response.status_code == 204
    assert client.get(f"/people/{person['id']}/photo-count").json()["count"] == 2

    people = client.get("/people").json()
    assert len(people) == 1


def test_update_person_rejects_duplicate_name(tmp_path: Path) -> None:
    client = _client(tmp_path)

    first = _create_person(client, "Mao").json()
    second = _create_person(client, "Jessie").json()

    response = client.patch(
        f"/people/{second['id']}",
        json={
            "name": "mao",
            "description": second["description"],
            "relationship": second["relationship"],
            "notes": second["notes"],
        },
    )
    assert response.status_code == 409
    assert client.get(f"/people/{first['id']}").json()["name"] == "Mao"
    assert client.get(f"/people/{second['id']}").json()["name"] == "Jessie"

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Response, UploadFile

from .db import Database
from .recognition import (
    FaceEncodingResult,
    FaceRecognitionRecognizer,
    InvalidImageError,
    MockImageRecognizer,
    RecognitionError,
    Recognizer,
    face_distance,
)
from .schemas import FaceEncodingSummary, HealthResponse, Person, PersonMemory, PersonUpdate, RecognitionResponse

DEFAULT_DB_PATH = Path(__file__).resolve().parents[1] / "data" / "face_recall.sqlite"
DEFAULT_DISTANCE_THRESHOLD = 0.6
DEFAULT_MOCK_DISTANCE_THRESHOLD = 2.5


def create_app(
    db_path: str | Path | None = None,
    recognizer: Recognizer | None = None,
    distance_threshold: float | None = None,
) -> FastAPI:
    app = FastAPI(title="Nemo Backend")
    app.state.db = Database(db_path or os.environ.get("FACE_DB_PATH", DEFAULT_DB_PATH))
    app.state.recognizer = recognizer or default_recognizer()
    app.state.distance_threshold = (
        distance_threshold
        if distance_threshold is not None
        else default_distance_threshold()
    )

    @app.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(status="ok")

    @app.get("/people", response_model=list[Person])
    def list_people() -> list[dict]:
        return app.state.db.list_people()

    @app.get("/people/{person_id}", response_model=Person)
    def get_person(person_id: str) -> dict:
        person = app.state.db.get_person(person_id)
        if person is None:
            raise HTTPException(status_code=404, detail="Person not found")
        return person

    @app.get("/people/{person_id}/reference-image")
    def get_reference_image(person_id: str) -> Response:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")

        image_bytes = app.state.db.get_reference_image(person_id)
        if image_bytes is None:
            raise HTTPException(status_code=404, detail="Reference image not found")
        return Response(content=image_bytes, media_type="image/jpeg")

    @app.post("/people/{person_id}/reference-image", status_code=204)
    @app.put("/people/{person_id}/reference-image", status_code=204)
    async def update_reference_image(person_id: str, file: UploadFile = File(...)) -> Response:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        image_bytes = await file.read()
        result = _encode_or_raise(app.state.recognizer, image_bytes)
        if not result.encodings:
            raise HTTPException(status_code=400, detail="No face detected in image")
        app.state.db.update_reference_image(person_id, image_bytes)
        return Response(status_code=204)

    @app.post("/people/{person_id}/photos")
    async def add_person_photo(person_id: str, file: UploadFile = File(...)) -> dict:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        image_bytes = await file.read()
        result = _encode_or_raise(app.state.recognizer, image_bytes)
        if not result.encodings:
            raise HTTPException(status_code=400, detail="No face detected in image")
        encoding_id = app.state.db.add_face_encoding(
            person_id,
            result.encodings[0],
            image=image_bytes,
            image_content_type=file.content_type or "image/jpeg",
        )
        return {"encoding_id": encoding_id}

    @app.get("/people/{person_id}/photos", response_model=list[FaceEncodingSummary])
    def list_person_photos(person_id: str) -> list:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        return app.state.db.list_face_encoding_summaries(person_id)

    @app.get("/people/{person_id}/photos/{encoding_id}/image")
    def get_person_photo_image(person_id: str, encoding_id: str) -> Response:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        image = app.state.db.get_face_encoding_image(person_id, encoding_id)
        if image is None:
            raise HTTPException(status_code=404, detail="Encoding image not found")
        image_bytes, media_type = image
        return Response(content=image_bytes, media_type=media_type)

    @app.delete("/people/{person_id}/photos/{encoding_id}", status_code=204)
    def delete_person_photo(person_id: str, encoding_id: str) -> Response:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        deleted = app.state.db.delete_face_encoding(person_id, encoding_id)
        if not deleted:
            raise HTTPException(status_code=404, detail="Encoding not found")
        return Response(status_code=204)

    @app.get("/people/{person_id}/photo-count")
    def get_photo_count(person_id: str) -> dict:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        return {"count": app.state.db.get_encoding_count(person_id)}

    @app.get("/people/{person_id}/memories", response_model=list[PersonMemory])
    def list_memories(person_id: str) -> list[dict]:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        return app.state.db.list_memories(person_id)

    @app.post("/people/{person_id}/memories", response_model=PersonMemory)
    async def add_memory(person_id: str, file: UploadFile = File(...)) -> dict:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")

        media_type = file.content_type or "application/octet-stream"
        if not (media_type.startswith("image/") or media_type.startswith("video/")):
            raise HTTPException(status_code=400, detail="Memory must be an image or video")

        media = await file.read()
        if not media:
            raise HTTPException(status_code=400, detail="Memory file cannot be empty")

        return app.state.db.add_memory(
            person_id=person_id,
            media=media,
            media_type=media_type,
            file_name=file.filename or "memory",
        )

    @app.get("/people/{person_id}/memories/{memory_id}")
    def get_memory(person_id: str, memory_id: str) -> Response:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")

        memory = app.state.db.get_memory(person_id, memory_id)
        if memory is None:
            raise HTTPException(status_code=404, detail="Memory not found")
        return Response(content=memory["media"], media_type=memory["media_type"])

    @app.delete("/people/{person_id}/memories/{memory_id}", status_code=204)
    def delete_memory(person_id: str, memory_id: str) -> Response:
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        deleted = app.state.db.delete_memory(person_id, memory_id)
        if not deleted:
            raise HTTPException(status_code=404, detail="Memory not found")
        return Response(status_code=204)

    @app.post("/people", response_model=Person)
    async def create_person(
        name: str = Form(...),
        description: str = Form(""),
        relationship: str = Form(""),
        notes: str = Form(""),
        file: UploadFile = File(...),
    ) -> dict:
        image_bytes = await file.read()
        result = _encode_or_raise(app.state.recognizer, image_bytes)
        if not result.encodings:
            raise HTTPException(status_code=400, detail="No face detected in image")

        name = name.strip()
        description = description.strip()
        relationship = relationship.strip()
        notes = notes.strip()
        if not name:
            raise HTTPException(status_code=400, detail="Name cannot be empty")
        if app.state.db.has_person_with_name(name):
            raise HTTPException(
                status_code=409,
                detail="A person with this name already exists. Add this photo to the existing person or choose a different name.",
            )

        person = app.state.db.create_person(
            name=name,
            description=description,
            relationship=relationship,
            notes=notes,
            reference_image=image_bytes,
        )
        app.state.db.add_face_encoding(
            person["id"],
            result.encodings[0],
            image=image_bytes,
            image_content_type=file.content_type or "image/jpeg",
        )
        return person

    @app.patch("/people/{person_id}", response_model=Person)
    def update_person(person_id: str, update: PersonUpdate) -> dict:
        name = update.name.strip()
        description = update.description.strip()
        if not name:
            raise HTTPException(status_code=400, detail="Name cannot be empty")
        if app.state.db.get_person(person_id) is None:
            raise HTTPException(status_code=404, detail="Person not found")
        if app.state.db.has_person_with_name(name, excluding_person_id=person_id):
            raise HTTPException(
                status_code=409,
                detail="A person with this name already exists. Choose a different name.",
            )

        person = app.state.db.update_person(
            person_id=person_id,
            name=name,
            description=description,
            relationship=update.relationship.strip(),
            notes=update.notes.strip(),
        )
        return person

    @app.delete("/people/{person_id}", status_code=204)
    def delete_person(person_id: str) -> Response:
        deleted = app.state.db.delete_person(person_id)
        if not deleted:
            raise HTTPException(status_code=404, detail="Person not found")
        return Response(status_code=204)

    @app.post("/recognize", response_model=RecognitionResponse)
    async def recognize(file: UploadFile = File(...)) -> RecognitionResponse:
        image_bytes = await file.read()
        result = _encode_or_raise(app.state.recognizer, image_bytes)
        if not result.encodings:
            raise HTTPException(status_code=400, detail="No face detected in image")

        best = _find_best_match(
            probe_encodings=result.encodings,
            db=app.state.db,
            threshold=app.state.distance_threshold,
        )
        if best is None:
            return RecognitionResponse(
                status="unknown",
                person=None,
                distance=None,
                face_count=result.face_count,
            )

        person, distance = best
        return RecognitionResponse(
            status="recognized",
            person=Person(**person),
            distance=distance,
            face_count=result.face_count,
        )

    return app


def default_recognizer() -> Recognizer:
    if os.environ.get("NEMO_MOCK_RECOGNITION") == "1":
        return MockImageRecognizer()
    return FaceRecognitionRecognizer()


def default_distance_threshold() -> float:
    configured = os.environ.get("FACE_DISTANCE_THRESHOLD")
    if configured is not None:
        return float(configured)
    if os.environ.get("NEMO_MOCK_RECOGNITION") == "1":
        return DEFAULT_MOCK_DISTANCE_THRESHOLD
    return DEFAULT_DISTANCE_THRESHOLD


def _encode_or_raise(recognizer: Recognizer, image_bytes: bytes) -> FaceEncodingResult:
    try:
        return recognizer.encode_faces(image_bytes)
    except InvalidImageError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RecognitionError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def _find_best_match(
    probe_encodings: list[list[float]],
    db: Database,
    threshold: float,
) -> tuple[dict, float] | None:
    best_person_id: str | None = None
    best_distance: float | None = None

    for stored in db.list_encodings():
        for probe in probe_encodings:
            distance = face_distance(probe, stored.encoding)
            if best_distance is None or distance < best_distance:
                best_distance = distance
                best_person_id = stored.person_id

    if best_person_id is None or best_distance is None or best_distance > threshold:
        return None

    person = db.get_person(best_person_id)
    if person is None:
        return None
    return person, best_distance


app = create_app()

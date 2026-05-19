from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Response, UploadFile

from .db import Database
from .recognition import (
    FaceEncodingResult,
    FaceRecognitionRecognizer,
    InvalidImageError,
    RecognitionError,
    Recognizer,
    face_distance,
)
from .schemas import HealthResponse, Person, PersonUpdate, RecognitionResponse

DEFAULT_DB_PATH = Path(__file__).resolve().parents[1] / "data" / "face_recall.sqlite"
DEFAULT_DISTANCE_THRESHOLD = 0.6


def create_app(
    db_path: str | Path | None = None,
    recognizer: Recognizer | None = None,
    distance_threshold: float | None = None,
) -> FastAPI:
    app = FastAPI(title="Nemo Backend")
    app.state.db = Database(db_path or os.environ.get("FACE_DB_PATH", DEFAULT_DB_PATH))
    app.state.recognizer = recognizer or FaceRecognitionRecognizer()
    app.state.distance_threshold = (
        distance_threshold
        if distance_threshold is not None
        else float(os.environ.get("FACE_DISTANCE_THRESHOLD", DEFAULT_DISTANCE_THRESHOLD))
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

    @app.post("/people", response_model=Person)
    async def create_person(
        name: str = Form(...),
        description: str = Form(""),
        file: UploadFile = File(...),
    ) -> dict:
        image_bytes = await file.read()
        result = _encode_or_raise(app.state.recognizer, image_bytes)
        if not result.encodings:
            raise HTTPException(status_code=400, detail="No face detected in image")

        person = app.state.db.create_person(
            name=name,
            description=description,
            reference_image=image_bytes,
        )
        app.state.db.add_face_encoding(person["id"], result.encodings[0])
        return person

    @app.patch("/people/{person_id}", response_model=Person)
    def update_person(person_id: str, update: PersonUpdate) -> dict:
        name = update.name.strip()
        description = update.description.strip()
        if not name:
            raise HTTPException(status_code=400, detail="Name cannot be empty")

        person = app.state.db.update_person(
            person_id=person_id,
            name=name,
            description=description,
        )
        if person is None:
            raise HTTPException(status_code=404, detail="Person not found")
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
        app.state.db.update_last_seen(person["id"])
        person = app.state.db.get_person(person["id"])
        return RecognitionResponse(
            status="recognized",
            person=Person(**person),
            distance=distance,
            face_count=result.face_count,
        )

    return app


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

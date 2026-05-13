from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO
from typing import Protocol

import numpy as np
from PIL import Image, UnidentifiedImageError


class RecognitionError(RuntimeError):
    pass


class InvalidImageError(RecognitionError):
    pass


@dataclass(frozen=True)
class FaceEncodingResult:
    encodings: list[list[float]]
    face_count: int


class Recognizer(Protocol):
    def encode_faces(self, image_bytes: bytes) -> FaceEncodingResult:
        """Return face encodings detected in image bytes."""


class FaceRecognitionRecognizer:
    def encode_faces(self, image_bytes: bytes) -> FaceEncodingResult:
        try:
            import face_recognition
        except ImportError as exc:
            raise RecognitionError(
                "face_recognition is not installed. Install backend requirements first."
            ) from exc

        try:
            image = Image.open(BytesIO(image_bytes)).convert("RGB")
        except (OSError, UnidentifiedImageError) as exc:
            raise InvalidImageError("Uploaded file is not a readable image") from exc

        image_array = np.array(image)
        locations = face_recognition.face_locations(image_array)
        encodings = face_recognition.face_encodings(image_array, locations)
        return FaceEncodingResult(
            encodings=[encoding.astype(float).tolist() for encoding in encodings],
            face_count=len(locations),
        )


def face_distance(left: list[float], right: list[float]) -> float:
    return float(np.linalg.norm(np.array(left) - np.array(right)))

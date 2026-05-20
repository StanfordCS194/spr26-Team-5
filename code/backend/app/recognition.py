from __future__ import annotations

import ctypes
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
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
            _preload_optional_image_codecs()
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


class MockImageRecognizer:
    def encode_faces(self, image_bytes: bytes) -> FaceEncodingResult:
        try:
            image = Image.open(BytesIO(image_bytes)).convert("L")
        except (OSError, UnidentifiedImageError) as exc:
            raise InvalidImageError("Uploaded file is not a readable image") from exc

        # Downsample to a deterministic 128-value fingerprint so the existing
        # database and distance logic can still exercise the app flow.
        fingerprint = image.resize((16, 8)).load()
        encoding = [
            float(fingerprint[x, y]) / 255.0
            for y in range(8)
            for x in range(16)
        ]
        return FaceEncodingResult(encodings=[encoding], face_count=1)


def face_distance(left: list[float], right: list[float]) -> float:
    return float(np.linalg.norm(np.array(left) - np.array(right)))


def _preload_optional_image_codecs() -> None:
    candidates = (
        "/opt/homebrew/lib/libgif.dylib",
        "/opt/homebrew/lib/libwebp.dylib",
        "/opt/homebrew/opt/jpeg/lib/libjpeg.dylib",
        "/usr/local/lib/libgif.dylib",
        "/usr/local/lib/libwebp.dylib",
        "/usr/local/opt/jpeg/lib/libjpeg.dylib",
    )

    for raw_path in candidates:
        path = Path(raw_path)
        if not path.exists():
            continue
        try:
            ctypes.CDLL(str(path), mode=ctypes.RTLD_GLOBAL)
        except OSError:
            continue

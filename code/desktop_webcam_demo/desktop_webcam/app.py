from __future__ import annotations

import argparse
import time

import cv2

from .camera import draw_status, encode_jpeg
from .client import BackendClient, BackendError, RecognitionResult


def main() -> None:
    args = parse_args()
    client = BackendClient(args.backend)

    try:
        health = client.health()
    except Exception as exc:
        raise SystemExit(f"Backend health check failed: {exc}") from exc

    capture = cv2.VideoCapture(args.camera)
    if not capture.isOpened():
        raise SystemExit(f"Could not open camera index {args.camera}")

    status = f"Backend online: {health}"
    auto_enabled = False
    last_auto_at = 0.0
    last_frame = None

    print("Desktop webcam prototype running.")
    print("Controls: r recognize | e enroll | a auto | q quit")

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                status = "Could not read webcam frame"
                continue

            last_frame = frame
            now = time.monotonic()
            if auto_enabled and now - last_auto_at >= args.auto_interval:
                status = recognize_frame(client, frame)
                last_auto_at = now

            cv2.imshow("FaceRecall Webcam", draw_status(frame, status, auto_enabled))
            key = cv2.waitKey(1) & 0xFF

            if key == ord("q"):
                break
            if key == ord("a"):
                auto_enabled = not auto_enabled
                status = f"Auto-recognition {'enabled' if auto_enabled else 'disabled'}"
            if key == ord("r"):
                status = recognize_frame(client, frame)
            if key == ord("e"):
                status = enroll_frame(client, frame)
    finally:
        capture.release()
        cv2.destroyAllWindows()

    if last_frame is None:
        print("No frames were captured.")


def recognize_frame(client: BackendClient, frame) -> str:
    try:
        result = client.recognize(encode_jpeg(frame))
    except BackendError as exc:
        return f"Recognition failed: {exc}"
    except Exception as exc:
        return f"Recognition failed: {exc}"
    return format_recognition(result)


def enroll_frame(client: BackendClient, frame) -> str:
    print()
    name = input("Name for current frame: ").strip()
    if not name:
        return "Enrollment canceled: empty name"
    description = input("Description: ").strip()

    try:
        person = client.create_person(name, description, encode_jpeg(frame))
    except BackendError as exc:
        return f"Enrollment failed: {exc}"
    except Exception as exc:
        return f"Enrollment failed: {exc}"
    return f"Enrolled {person.name}"


def format_recognition(result: RecognitionResult) -> str:
    if result.status == "recognized" and result.name:
        distance = "n/a" if result.distance is None else f"{result.distance:.3f}"
        return f"Recognized {result.name} | distance {distance} | faces {result.face_count}"
    return f"Unknown | faces {result.face_count}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FaceRecall desktop webcam prototype")
    parser.add_argument("--backend", default="http://127.0.0.1:8000", help="Backend base URL")
    parser.add_argument("--camera", type=int, default=0, help="OpenCV camera index")
    parser.add_argument("--auto-interval", type=float, default=4.0, help="Seconds between auto-recognition attempts")
    return parser.parse_args()


if __name__ == "__main__":
    main()

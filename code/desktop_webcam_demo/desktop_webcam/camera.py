from __future__ import annotations

import cv2
import numpy as np


def encode_jpeg(frame: np.ndarray) -> bytes:
    ok, encoded = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 88])
    if not ok:
        raise ValueError("Could not encode webcam frame as JPEG")
    return encoded.tobytes()


def draw_status(frame: np.ndarray, status: str, auto_enabled: bool) -> np.ndarray:
    output = frame.copy()
    overlay = output.copy()
    cv2.rectangle(overlay, (0, 0), (output.shape[1], 92), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.55, output, 0.45, 0, output)

    cv2.putText(
        output,
        status[:90],
        (16, 32),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.75,
        (255, 255, 255),
        2,
        cv2.LINE_AA,
    )
    controls = "r recognize | e enroll | a auto {} | q quit".format("on" if auto_enabled else "off")
    cv2.putText(
        output,
        controls,
        (16, 70),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.58,
        (210, 230, 255),
        1,
        cv2.LINE_AA,
    )
    return output

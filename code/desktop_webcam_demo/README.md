# Desktop Webcam Prototype

Small macOS webcam client for testing the face recognition backend before returning to the iPhone app.

## Start Backend

```bash
UV_PROJECT_ENVIRONMENT=.uv-venv uv run --python 3.11 python -m desktop_webcam.app --backend http://127.0.0.1:8000
```
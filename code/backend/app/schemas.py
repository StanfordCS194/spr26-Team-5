from pydantic import BaseModel


class Person(BaseModel):
    id: str
    name: str
    description: str
    created_at: str


class RecognitionResponse(BaseModel):
    status: str
    person: Person | None
    distance: float | None
    face_count: int


class HealthResponse(BaseModel):
    status: str

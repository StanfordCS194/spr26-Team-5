from pydantic import BaseModel


class Person(BaseModel):
    id: str
    name: str
    description: str
    created_at: str
    relationship: str = ""
    notes: str = ""


class PersonUpdate(BaseModel):
    name: str
    description: str
    relationship: str = ""
    notes: str = ""


class PersonMemory(BaseModel):
    id: str
    person_id: str
    media_type: str
    file_name: str
    created_at: str


class RecognitionResponse(BaseModel):
    status: str
    person: Person | None
    distance: float | None
    face_count: int


class HealthResponse(BaseModel):
    status: str

class VoiceCommandRequest(BaseModel):
    text: str

class VoiceCommandResponse(BaseModel):
    action: str
    message: str
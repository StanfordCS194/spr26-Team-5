import Foundation

struct HealthResponse: Codable {
    let status: String
}

struct Person: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case createdAt = "created_at"
    }
}

struct PersonUpdateRequest: Codable {
    let name: String
    let description: String
}

struct RecognitionResponse: Codable, Equatable {
    let status: RecognitionStatus
    let person: Person?
    let distance: Double?
    let faceCount: Int

    enum CodingKeys: String, CodingKey {
        case status
        case person
        case distance
        case faceCount = "face_count"
    }
}

enum RecognitionStatus: String, Codable {
    case recognized
    case unknown
}

enum ScanIssue: Equatable {
    case noFaceDetected
    case failed(String)

    var title: String {
        switch self {
        case .noFaceDetected:
            return "No Face Detected"
        case .failed:
            return "Scan Failed"
        }
    }

    var message: String {
        switch self {
        case .noFaceDetected:
            return "The newest photo was scanned, but the backend could not find a face. The app is ready for the next new photo."
        case let .failed(message):
            return message
        }
    }
}

struct RecognitionRun: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let imageData: Data
    let result: RecognitionResponse
    let photoCreatedAt: Date?
    let photoModifiedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        imageData: Data,
        result: RecognitionResponse,
        photoCreatedAt: Date?,
        photoModifiedAt: Date?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.imageData = imageData
        self.result = result
        self.photoCreatedAt = photoCreatedAt
        self.photoModifiedAt = photoModifiedAt
    }
}

extension RecognitionResponse {
    func replacingPerson(_ person: Person) -> RecognitionResponse {
        RecognitionResponse(
            status: status,
            person: person,
            distance: distance,
            faceCount: faceCount
        )
    }

    func removingPerson() -> RecognitionResponse {
        RecognitionResponse(
            status: .unknown,
            person: nil,
            distance: distance,
            faceCount: faceCount
        )
    }
}

extension RecognitionRun {
    func replacingPerson(_ person: Person) -> RecognitionRun {
        RecognitionRun(
            id: id,
            createdAt: createdAt,
            imageData: imageData,
            result: result.replacingPerson(person),
            photoCreatedAt: photoCreatedAt,
            photoModifiedAt: photoModifiedAt
        )
    }

    func removingPerson() -> RecognitionRun {
        RecognitionRun(
            id: id,
            createdAt: createdAt,
            imageData: imageData,
            result: result.removingPerson(),
            photoCreatedAt: photoCreatedAt,
            photoModifiedAt: photoModifiedAt
        )
    }
}

enum AppRoute: Equatable {
    case person(String)
    case createPerson
}

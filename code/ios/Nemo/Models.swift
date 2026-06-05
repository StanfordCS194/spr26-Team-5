import Foundation

struct HealthResponse: Codable {
    let status: String
}

struct Person: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let createdAt: String
    let relationship: String
    let notes: String
    let lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case createdAt = "created_at"
        case relationship
        case notes
        case lastSeen = "last_seen"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        relationship = try container.decodeIfPresent(String.self, forKey: .relationship) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        lastSeen = try container.decodeIfPresent(String.self, forKey: .lastSeen)
    }
}

extension Person {
    var isCloseFriend: Bool {
        relationship.localizedCaseInsensitiveContains("close friend")
    }

    var patientRelationshipLabel: String? {
        if isCloseFriend {
            return "Close Friend"
        }
        return relationship.isEmpty ? nil : relationship.capitalized
    }

    var lastSeenLabel: String? {
        guard let lastSeen else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: lastSeen) else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

struct PersonUpdateRequest: Codable {
    let name: String
    let description: String
    let relationship: String
    let notes: String
}

struct PersonMemory: Codable, Identifiable, Equatable {
    let id: String
    let personID: String
    let mediaType: String
    let fileName: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case personID = "person_id"
        case mediaType = "media_type"
        case fileName = "file_name"
        case createdAt = "created_at"
    }

    var isVideo: Bool {
        mediaType.hasPrefix("video/")
    }
}

struct FaceEncodingSummary: Codable, Identifiable, Equatable {
    let id: String
    let personID: String
    let createdAt: String
    let hasImage: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case personID = "person_id"
        case createdAt = "created_at"
        case hasImage = "has_image"
    }
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
    case backendUnavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .noFaceDetected:
            return "No Face Detected"
        case .backendUnavailable:
            return "Backend Unavailable"
        case .failed:
            return "Scan Failed"
        }
    }

    var message: String {
        switch self {
        case .noFaceDetected:
            return "The newest photo was scanned, but no face was visible clearly enough to match."
        case let .backendUnavailable(message):
            return message
        case let .failed(message):
            return message
        }
    }

    var nextStep: String {
        switch self {
        case .noFaceDetected:
            return "Try again with a closer photo, better lighting, or a clearer face."
        case .backendUnavailable:
            return "Open Settings to check the backend URL and connection, then scan again."
        case .failed:
            return "Try scanning again. If this keeps happening, check Settings and the backend health."
        }
    }
}

struct RecognitionRun: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let thumbnailData: Data
    let result: RecognitionResponse
    let photoCreatedAt: Date?
    let photoModifiedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        thumbnailData: Data,
        result: RecognitionResponse,
        photoCreatedAt: Date?,
        photoModifiedAt: Date?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.thumbnailData = thumbnailData
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
            thumbnailData: thumbnailData,
            result: result.replacingPerson(person),
            photoCreatedAt: photoCreatedAt,
            photoModifiedAt: photoModifiedAt
        )
    }

    func removingPerson() -> RecognitionRun {
        RecognitionRun(
            id: id,
            createdAt: createdAt,
            thumbnailData: thumbnailData,
            result: result.removingPerson(),
            photoCreatedAt: photoCreatedAt,
            photoModifiedAt: photoModifiedAt
        )
    }
}

struct VoiceCommandRequest: Codable {
    let text: String
}

struct VoiceCommandResponse: Codable {
    let action: String
    let message: String
}

enum AppRoute: Equatable {
    case person(String)
    case createPerson
}

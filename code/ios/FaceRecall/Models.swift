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

struct AppEvent: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let createdAt = Date()
}

enum AppRoute: Equatable {
    case person(String)
    case createPerson
}

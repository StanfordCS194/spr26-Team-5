import Foundation

enum APIClientError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid backend URL."
        case .invalidResponse:
            return "Backend returned an invalid response."
        case let .serverError(status, message):
            return "Backend error \(status): \(message)"
        }
    }

    var statusCode: Int? {
        switch self {
        case let .serverError(status, _):
            return status
        default:
            return nil
        }
    }

    var message: String {
        switch self {
        case .invalidBaseURL:
            return "Invalid backend URL."
        case .invalidResponse:
            return "Backend returned an invalid response."
        case let .serverError(_, message):
            return message
        }
    }
}

struct APIClient {
    func health(baseURL: String) async throws -> HealthResponse {
        let request = try request(path: "/health", baseURL: baseURL)
        return try await send(request)
    }

    func recognize(imageData: Data, baseURL: String) async throws -> RecognitionResponse {
        var request = try request(path: "/recognize", baseURL: baseURL)
        request.httpMethod = "POST"
        request.setMultipartBody(fields: [:], fileField: "file", fileName: "photo.jpg", mimeType: "image/jpeg", data: imageData)
        return try await send(request)
    }

    func createPerson(name: String, description: String, relationship: String, imageData: Data, baseURL: String) async throws -> Person {
        var request = try request(path: "/people", baseURL: baseURL)
        request.httpMethod = "POST"
        request.setMultipartBody(
            fields: ["name": name, "description": description, "relationship": relationship],
            fileField: "file",
            fileName: "enrollment.jpg",
            mimeType: "image/jpeg",
            data: imageData
        )
        return try await send(request)
    }

    func people(baseURL: String) async throws -> [Person] {
        let request = try request(path: "/people", baseURL: baseURL)
        return try await send(request)
    }

    func person(id: String, baseURL: String) async throws -> Person {
        let request = try request(path: "/people/\(id)", baseURL: baseURL)
        return try await send(request)
    }

    func personReferenceImage(id: String, baseURL: String) async throws -> Data? {
        let request = try request(path: "/people/\(id)/reference-image", baseURL: baseURL)
        return try await sendOptionalData(request)
    }

    func updatePerson(id: String, name: String, description: String, relationship: String, baseURL: String) async throws -> Person {
        var request = try request(path: "/people/\(id)", baseURL: baseURL)
        request.httpMethod = "PATCH"
        request.setJSONBody(
            PersonUpdateRequest(
                name: name,
                description: description,
                relationship: relationship,
                notes: ""
            )
        )
        return try await send(request)
    }

    func addPersonPhoto(id: String, imageData: Data, baseURL: String) async throws {
        var request = try request(path: "/people/\(id)/photos", baseURL: baseURL)
        request.httpMethod = "POST"
        request.setMultipartBody(fields: [:], fileField: "file", fileName: "extra_photo.jpg", mimeType: "image/jpeg", data: imageData)
        try await sendEmpty(request)
    }

    func personPhotoCount(id: String, baseURL: String) async throws -> Int {
        let request = try request(path: "/people/\(id)/photo-count", baseURL: baseURL)
        let result: [String: Int] = try await send(request)
        return result["count"] ?? 0
    }

    func deletePerson(id: String, baseURL: String) async throws {
        var request = try request(path: "/people/\(id)", baseURL: baseURL)
        request.httpMethod = "DELETE"
        try await sendEmpty(request)
    }

    private func request(path: String, baseURL: String) throws -> URLRequest {
        guard let base = URL(string: baseURL), let url = URL(string: path, relativeTo: base) else {
            throw APIClientError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw APIClientError.serverError(httpResponse.statusCode, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendEmpty(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw APIClientError.serverError(httpResponse.statusCode, message)
        }
    }

    private func sendOptionalData(_ request: URLRequest) async throws -> Data? {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw APIClientError.serverError(httpResponse.statusCode, message)
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = payload["detail"] as? String {
            return detail
        }
        return String(data: data, encoding: .utf8) ?? "No response body"
    }
}

private extension URLRequest {
    mutating func setJSONBody<T: Encodable>(_ value: T) {
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpBody = try? JSONEncoder().encode(value)
    }

    mutating func setMultipartBody(fields: [String: String], fileField: String, fileName: String, mimeType: String, data: Data) {
        let boundary = "Boundary-\(UUID().uuidString)"
        setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        httpBody = body
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

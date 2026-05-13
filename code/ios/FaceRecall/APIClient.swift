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

    func createPerson(name: String, description: String, imageData: Data, baseURL: String) async throws -> Person {
        var request = try request(path: "/people", baseURL: baseURL)
        request.httpMethod = "POST"
        request.setMultipartBody(
            fields: ["name": name, "description": description],
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

    func updatePerson(id: String, name: String, description: String, baseURL: String) async throws -> Person {
        var request = try request(path: "/people/\(id)", baseURL: baseURL)
        request.httpMethod = "PATCH"
        request.setJSONBody(PersonUpdateRequest(name: name, description: description))
        return try await send(request)
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
            let message = String(data: data, encoding: .utf8) ?? "No response body"
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
            let message = String(data: data, encoding: .utf8) ?? "No response body"
            throw APIClientError.serverError(httpResponse.statusCode, message)
        }
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

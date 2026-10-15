import AKitFoundation
import Foundation

/// The one way review talks to GitLab and Azure DevOps: a request in, the body and the
/// response out. The app uses `URLSession`; tests pass a fake server.
public typealias ReviewFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum ReviewHTTP {
    public struct Failure: Error, LocalizedError {
        public let message: String
        /// The HTTP status, when the server answered.
        public let status: Int?
        public var errorDescription: String? { message }

        public init(message: String, status: Int? = nil) {
            self.message = message
            self.status = status
        }
    }

    public static let network: ReviewFetch = { request in
        guard request.url?.scheme?.lowercased() == "https" else {
            throw Failure(message: "AKit sends tokens only over https, not to \(request.url?.absoluteString ?? "this address").")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "\(request.url?.host() ?? "The server") gave no HTTP answer.") }
        return (data, http)
    }

    /// No redirects: a redirect to another host would carry the token's header there. A 3xx
    /// comes back as an error that names it.
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Sends the request and checks the status. The error text names the method and path,
    /// never a header (the token is in one) and only a masked piece of the body.
    static func send(_ request: URLRequest, fetch: ReviewFetch) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode) else {
            let path = request.url.map { $0.path() } ?? ""
            let body = SecretFilter.masked(String(decoding: data.prefix(300), as: UTF8.self))
            let hint = switch response.statusCode {
            case 401: " The token is missing, wrong or expired."
            case 403: " The token lacks a right this needs."
            case 404: " Not found, or the token can't see it."
            case 300..<400: " GitLab or Azure DevOps answered with a redirect, which AKit doesn't follow: check the address in the profile."
            default: ""
            }
            throw Failure(message: "\(request.httpMethod ?? "GET") \(path): HTTP \(response.statusCode).\(hint) \(body)"
                            .trimmingCharacters(in: .whitespaces), status: response.statusCode)
        }
        return (data, response)
    }

    static func json(_ data: Data, what: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw Failure(message: "\(what): the answer is not JSON.")
        }
    }
}

/// Reads fields of `JSONSerialization` objects.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool { (self[key] as? Bool) ?? ((self[key] as? NSNumber)?.boolValue ?? false) }
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func objects(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
}

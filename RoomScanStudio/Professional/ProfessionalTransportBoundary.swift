import Foundation

struct ProfessionalTransportAttempt: Equatable, Sendable {
    let url: URL
    let method: String
}

struct ProfessionalHTTPRequest: Equatable, Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?

    init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

struct ProfessionalHTTPResponse: Equatable, Sendable {
    let data: Data
    let statusCode: Int
}

/// Provider/auth adapters may depend on this app-owned protocol, never on a
/// Foundation/Network/socket client. The only concrete HTTP implementation is
/// below in this exact audited transport-boundary file.
protocol ProfessionalHTTPTransport: Sendable {
    func send(_ request: ProfessionalHTTPRequest) async throws -> ProfessionalHTTPResponse
}

/// File transfers are a separate capability because professional working-set
/// archives can be large. The only production implementation remains this
/// audited Foundation boundary; callers never obtain a URLSession directly.
struct ProfessionalFileTransferResponse: Equatable, Sendable {
    let statusCode: Int
}

protocol ProfessionalFileStreamingTransport: Sendable {
    func uploadFile(
        at fileURL: URL,
        to url: URL,
        method: String,
        headers: [String: String]
    ) async throws -> ProfessionalFileTransferResponse

    func downloadFile(
        from url: URL,
        to destinationURL: URL
    ) async throws -> ProfessionalFileTransferResponse
}

protocol ProfessionalTransportRequestObserving: AnyObject, Sendable {
    func observe(_ attempt: ProfessionalTransportAttempt) throws
}

/// The sole request-observation seam shared by guest composition and every
/// permitted professional HTTP adapter. Guest builds create a denying boundary;
/// configured professional composition must explicitly supply its observer.
struct ProfessionalTransportObserverFactory: Sendable {
    private let makeObserver: @Sendable () -> any ProfessionalTransportRequestObserving

    private init(
        makeObserver: @escaping @Sendable () -> any ProfessionalTransportRequestObserving
    ) {
        self.makeObserver = makeObserver
    }

    static let guestDefault = ProfessionalTransportObserverFactory {
        GuestProfessionalTransportDenyingObserver()
    }

    static func observing(
        _ observer: any ProfessionalTransportRequestObserving
    ) -> ProfessionalTransportObserverFactory {
        ProfessionalTransportObserverFactory { observer }
    }

    fileprivate func makeBoundary() -> ProfessionalTransportBoundary {
        ProfessionalTransportBoundary(observer: makeObserver())
    }
}

final class ProfessionalTransportBoundary: @unchecked Sendable {
    private let observer: any ProfessionalTransportRequestObserving

    fileprivate init(observer: any ProfessionalTransportRequestObserving) {
        self.observer = observer
    }

    func observe(_ attempt: ProfessionalTransportAttempt) throws {
        try observer.observe(attempt)
    }
}

private struct GuestProfessionalTransportBlocked: Error {}

private final class GuestProfessionalTransportDenyingObserver:
    ProfessionalTransportRequestObserving,
    @unchecked Sendable
{
    func observe(_ attempt: ProfessionalTransportAttempt) throws {
        throw GuestProfessionalTransportBlocked()
    }
}

/// The sole production owner of URLSession. Authorization/recording occurs on
/// the one send path before the Foundation request is created or any I/O starts.
final class FoundationProfessionalHTTPTransport:
    ProfessionalHTTPTransport,
    ProfessionalFileStreamingTransport,
    @unchecked Sendable
{
    private let session: URLSession
    private let boundary: ProfessionalTransportBoundary

    init(
        session: URLSession,
        observerFactory: ProfessionalTransportObserverFactory = .guestDefault
    ) {
        self.session = session
        boundary = observerFactory.makeBoundary()
    }

    func send(
        _ request: ProfessionalHTTPRequest
    ) async throws -> ProfessionalHTTPResponse {
        try requireHTTPS(request.url)
        try boundary.observe(
            ProfessionalTransportAttempt(
                url: request.url,
                method: request.method
            )
        )

        var foundationRequest = URLRequest(url: request.url)
        foundationRequest.httpMethod = request.method
        foundationRequest.httpBody = request.body
        for (header, value) in request.headers {
            foundationRequest.setValue(value, forHTTPHeaderField: header)
        }
        let (data, response) = try await session.data(for: foundationRequest)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProfessionalHTTPResponse(
            data: data,
            statusCode: response.statusCode
        )
    }

    func uploadFile(
        at fileURL: URL,
        to url: URL,
        method: String,
        headers: [String: String]
    ) async throws -> ProfessionalFileTransferResponse {
        try requireHTTPS(url)
        guard !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) else {
            throw ProfessionalSignedTransferError.authorizationHeaderForbidden
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProfessionalSignedTransferError.invalidFile
        }
        try boundary.observe(ProfessionalTransportAttempt(url: url, method: method))
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return ProfessionalFileTransferResponse(statusCode: response.statusCode)
    }

    func downloadFile(
        from url: URL,
        to destinationURL: URL
    ) async throws -> ProfessionalFileTransferResponse {
        try requireHTTPS(url)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ProfessionalSignedTransferError.destinationExists
        }
        try boundary.observe(ProfessionalTransportAttempt(url: url, method: "GET"))
        let (temporaryURL, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw ProfessionalSignedTransferError.unsuccessfulStatus(response.statusCode)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return ProfessionalFileTransferResponse(statusCode: response.statusCode)
    }

    private func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil
        else {
            throw ProfessionalSignedTransferError.insecureURL
        }
    }
}

private enum ProfessionalSignedTransferError: Error {
    case insecureURL
    case authorizationHeaderForbidden
    case invalidFile
    case destinationExists
    case unsuccessfulStatus(Int)
}

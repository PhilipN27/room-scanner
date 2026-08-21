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
}

import Foundation
import HTTPTypes

/// Session bookkeeping is outside APIClient so the session manager cannot retain itself.
struct SessionAPIClient: Sendable {
  let api: APIClient
  let sessionManager: SessionManager
  let eventEmitter: AuthStateChangeEventEmitter

  func execute(_ request: Helpers.HTTPRequest, for session: Session? = nil) async throws
    -> Helpers.HTTPResponse
  {
    let result = try await api.send(request)
    if case .failure(.sessionMissing) = result,
      await sessionManager.removeIfUnchanged(session)
    {
      eventEmitter.emit(.signedOut, session: nil)
    }
    return try result.get()
  }

  @discardableResult
  func authorizedExecute(_ request: Helpers.HTTPRequest) async throws -> Helpers.HTTPResponse {
    let session = try await sessionManager.session()
    var request = request
    request.headers[.authorization] = "Bearer \(session.accessToken)"
    return try await execute(request, for: session)
  }
}

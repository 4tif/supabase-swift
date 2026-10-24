import Foundation
import HTTPTypes

extension HTTPClient {
  init(configuration: AuthClient.Configuration) {
    var interceptors: [any HTTPClientInterceptor] = []
    if let logger = configuration.logger {
      interceptors.append(LoggerInterceptor(logger: logger))
    }

    interceptors.append(
      RetryRequestInterceptor(
        retryableHTTPMethods: RetryRequestInterceptor.defaultRetryableHTTPMethods.union(
          [.post]  // Add POST method so refresh token are also retried.
        )
      )
    )

    self.init(fetch: configuration.fetch, interceptors: interceptors)
  }
}

struct APIClient: Sendable {
  let configuration: AuthClient.Configuration
  let http: any HTTPClientType

  /// Error codes that should clean up local session.
  private let sessionCleanupErrorCodes: [ErrorCode] = [
    .sessionNotFound,
    .sessionExpired,
    .refreshTokenNotFound,
    .refreshTokenAlreadyUsed,
  ]

  /// Session-free requests, used by admin operations and the session-aware layer.
  func execute(_ request: Helpers.HTTPRequest) async throws -> Helpers.HTTPResponse {
    try await send(request).get()
  }

  /// Preserve the distinction between a server refusal and an error thrown by the transport.
  func send(_ request: Helpers.HTTPRequest) async throws -> Result<Helpers.HTTPResponse, AuthError>
  {
    var request = request
    request.headers = HTTPFields(configuration.headers).merging(with: request.headers)

    if request.headers[.apiVersionHeaderName] == nil {
      request.headers[.apiVersionHeaderName] = apiVersions[._20240101]!.name.rawValue
    }

    let response = try await http.send(request)

    guard 200..<300 ~= response.statusCode else {
      return .failure(handleError(response: response))
    }

    return .success(response)
  }

  func handleError(response: Helpers.HTTPResponse) -> AuthError {
    guard
      let error = try? response.decoded(
        as: _RawAPIErrorResponse.self,
        decoder: configuration.resolvedDecoder
      )
    else {
      return .api(
        message: "Unexpected error",
        errorCode: .unexpectedFailure,
        underlyingData: response.data,
        underlyingResponse: response.underlyingResponse
      )
    }

    let responseAPIVersion = parseResponseAPIVersion(response)

    let errorCode: ErrorCode? =
      if let responseAPIVersion, responseAPIVersion >= apiVersions[._20240101]!.timestamp,
        let code = error.code
      {
        ErrorCode(code)
      } else {
        error.errorCode
      }

    if errorCode == nil, let weakPassword = error.weakPassword {
      return .weakPassword(
        message: error._getErrorMessage(),
        reasons: weakPassword.reasons ?? []
      )
    } else if errorCode == .weakPassword {
      return .weakPassword(
        message: error._getErrorMessage(),
        reasons: error.weakPassword?.reasons ?? []
      )
    } else if let errorCode, sessionCleanupErrorCodes.contains(errorCode) {
      return .sessionMissing
    } else {
      return .api(
        message: error._getErrorMessage(),
        errorCode: errorCode ?? .unknown,
        underlyingData: response.data,
        underlyingResponse: response.underlyingResponse
      )
    }
  }

  private func parseResponseAPIVersion(_ response: Helpers.HTTPResponse) -> Date? {
    guard let apiVersion = response.headers[.apiVersionHeaderName] else { return nil }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: "\(apiVersion)T00:00:00.0Z")
  }
}

// Struct for mapping all fields possibly returned by API.
struct _RawAPIErrorResponse: Decodable {
  let msg: String?
  let message: String?
  let errorDescription: String?
  let error: String?
  let code: String?
  let errorCode: ErrorCode?
  let weakPassword: _WeakPassword?

  struct _WeakPassword: Decodable {
    let reasons: [String]?
  }

  func _getErrorMessage() -> String {
    msg ?? message ?? errorDescription ?? error ?? "Unknown"
  }
}

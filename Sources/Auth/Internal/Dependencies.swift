import Foundation

struct Dependencies: Sendable {
  let configuration: AuthClient.Configuration
  let http: any HTTPClientType
  let api: APIClient
  let sessionAPI: SessionAPIClient
  let codeVerifierStorage: CodeVerifierStorage
  let sessionStorage: SessionStorage
  let sessionManager: SessionManager
  let eventEmitter: AuthStateChangeEventEmitter
  let date: @Sendable () -> Date
  let urlOpener: URLOpener
  let pkce: PKCE
  let logger: (any SupabaseLogger)?

  var resolvedEncoder: JSONEncoder { configuration.resolvedEncoder }
  var resolvedDecoder: JSONDecoder { configuration.resolvedDecoder }
}

extension Dependencies {
  /// An owned acyclic graph: background work retains the values it uses, not a registry key.
  static func live(
    configuration: AuthClient.Configuration,
    http: (any HTTPClientType)? = nil,
    logger: (any SupabaseLogger)? = nil,
    date: @escaping @Sendable () -> Date = { Date() },
    pkce: PKCE = .live,
    urlOpener: URLOpener = .live
  ) -> Dependencies {
    let http = http ?? HTTPClient(configuration: configuration)
    let logger = logger ?? configuration.logger
    let eventEmitter = AuthStateChangeEventEmitter()
    let api = APIClient(configuration: configuration, http: http)
    let storage = SessionStorage.live(configuration: configuration)
    let manager = SessionManager.live(
      configuration: configuration, api: api,
      sessionStorage: storage, eventEmitter: eventEmitter, logger: logger)
    return Dependencies(
      configuration: configuration, http: http, api: api,
      sessionAPI: SessionAPIClient(api: api, sessionManager: manager, eventEmitter: eventEmitter),
      codeVerifierStorage: .live(configuration: configuration), sessionStorage: storage,
      sessionManager: manager, eventEmitter: eventEmitter, date: date, urlOpener: urlOpener,
      pkce: pkce, logger: logger)
  }
}

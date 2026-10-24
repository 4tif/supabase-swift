//
//  AuthClientLifetimeTests.swift
//  AuthTests
//
//  Created by Codex on 24/10/26.
//

import ConcurrencyExtras
import Foundation
import Helpers
import TestHelpers
import Testing

@testable import Auth

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.serialized)
struct AuthClientLifetimeTests {
  @Test(.timeLimit(.minutes(1)))
  @MainActor
  func stoppedClientReleasesItsEntireDependencyGraph() async throws {
    let released = AsyncStream<Void>.makeStream()
    var storage: LifetimeStorage? = LifetimeStorage(released: released.continuation)
    weak var weakStorage = storage
    var client: AuthClient? = AuthClient(
      configuration: .init(
        url: clientURL, localStorage: storage!, logger: nil, autoRefreshToken: false
      ))
    weak var weakClient = client
    storage = nil
    await client!.dependencies.sessionManager.startAutoRefresh()
    #expect(await client!.dependencies.sessionManager.isAutoRefreshRunning())
    await client!.dependencies.sessionManager.stopAutoRefresh()
    #expect(await client!.dependencies.sessionManager.isAutoRefreshRunning() == false)
    client = nil
    _ = await released.stream.first(where: { @Sendable _ in true })
    #expect(weakClient == nil)
    #expect(weakStorage == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  @MainActor
  func heldBackgroundRefreshFinishesAfterParentIsReleased() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let parentReleased = AsyncStream<Void>.makeStream()
    let responses = AsyncStream<Session>.makeStream()
    let writes = AsyncStream<Data>.makeStream()
    let released = AsyncStream<Void>.makeStream()
    let requests = LockIsolated(0)
    var storage: LifetimeStorage? = LifetimeStorage(
      released: released.continuation, writes: writes.continuation)
    weak var weakStorage = storage
    var client: AuthClient? = AuthClient(
      configuration: .init(
        url: clientURL, localStorage: storage!,
        logger: ParentReleaseLogger(released: parentReleased.continuation),
        fetch: { request in
          #expect(request.url?.path.hasSuffix("/token") == true)
          requests.withValue { $0 += 1 }
          entered.continuation.yield(())
          let session = await responses.stream.first(where: { _ in true })!
          return (
            try AuthClient.Configuration.jsonEncoder.encode(session),
            HTTPURLResponse(
              url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        }, autoRefreshToken: false
      ))
    weak var weakClient = client
    client!.dependencies.sessionStorage.store(.expiredSession)
    storage = nil
    await client!.dependencies.sessionManager.startAutoRefresh()
    _ = await entered.stream.first(where: { @Sendable _ in true })
    // No test task captures the parent. Only the SDK's held refresh owns its dependency values.
    client = nil
    _ = await parentReleased.stream.first(where: { @Sendable _ in true })
    #expect(weakClient == nil)
    #expect(weakStorage != nil)
    responses.continuation.yield(.validSession)
    responses.continuation.finish()
    let stored = await writes.stream.first { @Sendable data in
      (try? JSONDecoder().decode(Session.self, from: data))?.expiresIn
        == Session.validSession.expiresIn
    }
    #expect(stored != nil)
    _ = await released.stream.first(where: { @Sendable _ in true })
    #expect(weakStorage == nil)
    #expect(requests.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func adminAndAdminOAuthOutliveTheParent() async throws {
    let (admin, requests, released) = subClient(\.admin)
    _ = await released.first(where: { _ in true })
    try await admin.deleteUser(id: UUID())
    #expect(requests.value == 1)
    let (oauth, oauthRequests, releasedOAuth) = subClient(\.admin.oauth)
    _ = await releasedOAuth.first(where: { _ in true })
    try await oauth.deleteClient(clientId: UUID())
    #expect(oauthRequests.value == 1)
  }

  @Test
  func sessionAwareSubClientsKeepTheirParentAlive() async throws {
    let (oauth, requests, _) = subClient(\.oauthServer)
    oauth.client.dependencies.sessionStorage.store(.validSession)
    try await oauth.revokeGrant(clientId: UUID())
    #expect(requests.value == 1)
    let (mfa, mfaRequests, _) = subClient(\.mfa, body: Data(#"{"id":"factor-id"}"#.utf8))
    mfa.client.dependencies.sessionStorage.store(.validSession)
    let response = try await mfa.unenroll(params: .init(factorId: "factor-id"))
    #expect(response.id == "factor-id")
    #expect(mfaRequests.value == 1)
  }

  private func subClient<T>(_ keyPath: KeyPath<AuthClient, T>, body: Data = Data()) -> (
    T, LockIsolated<Int>, AsyncStream<Void>
  ) {
    let requests = LockIsolated(0)
    let released = AsyncStream<Void>.makeStream()
    let client = AuthClient(
      configuration: .init(
        url: clientURL, localStorage: InMemoryLocalStorage(),
        logger: ParentReleaseLogger(released: released.continuation),
        fetch: { request in
          requests.withValue { $0 += 1 }
          return (
            body,
            HTTPURLResponse(
              url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        }, autoRefreshToken: false
      ))
    return (client[keyPath: keyPath], requests, released.stream)
  }
}

private final class LifetimeStorage: AuthLocalStorage, @unchecked Sendable {
  private let values = LockIsolated<[String: Data]>([:])
  private let released: AsyncStream<Void>.Continuation
  private let writes: AsyncStream<Data>.Continuation?

  init(released: AsyncStream<Void>.Continuation, writes: AsyncStream<Data>.Continuation? = nil) {
    self.released = released
    self.writes = writes
  }
  deinit {
    released.yield(())
    released.finish()
    writes?.finish()
  }
  func store(key: String, value: Data) throws {
    values.withValue { $0[key] = value }
    writes?.yield(value)
  }
  func retrieve(key: String) throws -> Data? { values.value[key] }
  func remove(key: String) throws { values.withValue { $0[key] = nil } }
}

/// With auto refresh disabled, this event is the client's deinit cleanup, not a timed retry.
private struct ParentReleaseLogger: SupabaseLogger {
  let released: AsyncStream<Void>.Continuation
  func log(message: SupabaseLogMessage) {
    if message.message == "stop auto refresh token" {
      released.yield(())
      released.finish()
    }
  }
}

# v2 Auth dependency lifetime backport

Base: official v2.55.4, `fee4bd78997f8b4e919c1c9711e0cfb346fd7a55`.

This backports the ownership fix from upstream
[`faf626bf` / #1395](https://github.com/supabase/supabase-swift/pull/1395)
without the v3 HTTP, logging or public API changes.

AuthClient owns its immutable dependency graph. Storage and the refresh manager
hold the values they use, so a refresh already in flight can finish after its
client is released. Deinit still stops automatic refresh. MFA and OAuth subclients
retain their client; admin subclients retain a session-free API client. The
session-free API breaks the API/session-manager retain cycle.

The v2 adaptation uses an internal Result from APIClient.send to distinguish a
server session-invalidating response from a transport error. SessionAPIClient
and the refresh manager preserve the existing session-snapshot cleanup behavior;
an old request must not clear a replacement session. Public responses and errors
remain v2 types.

Verification on the SpaceJam owner Mac: Auth target compiles; all 245 Auth tests
in 18 suites pass, including held refresh, dependency graph release, and subclient
lifetimes. Full application and other platform checks are separate release gates.

Consumers must pin the exact reviewed fork commit in both Bazel's SwiftPM graph
and Xcode. Replace this pin with an official v2 release containing the fix once
that release has passed the same application gates.

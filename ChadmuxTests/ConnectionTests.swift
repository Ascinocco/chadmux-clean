import XCTest
import Crypto
import NIO
import NIOSSH
@testable import Chadmux

final class ConnectionTests: XCTestCase {
    func testUnknownPinnedAndChangedHostKeys() async throws {
        let host = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let key = String(openSSHPublicKey: host)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        for expected in [nil, key, "a different host"] {
            let promise = loop.makePromise(of: Void.self)
            PinnedHostValidator(expected: expected).validateHostKey(hostKey: host, validationCompletePromise: promise)
            do {
                try await promise.futureResult.get()
                XCTAssertEqual(expected, key)
            } catch let unknown as UnknownHost {
                XCTAssertNil(expected)
                XCTAssertEqual(unknown.key, key)
                XCTAssertTrue(unknown.fingerprint.hasPrefix("SHA256:"))
            } catch { XCTAssertTrue(error is ChangedHost); XCTAssertEqual(expected,"a different host") }
        }
    }

    func testKeychainKeepsSameDevicePublicKeyAndScopesHostTrust() throws {
        let store = SecretStore(service: "com.chadmux.tests." + UUID().uuidString)
        defer { try? store.remove("device-ed25519"); try? store.remove("host:fixture:22") }
        let first = SSHPrimitives.authorizedKey(try store.deviceKey())
        let second = SSHPrimitives.authorizedKey(try store.deviceKey())
        XCTAssertEqual(first, second)
        try store.write(Data("fixture-public-host-key".utf8), account:"host:fixture:22")
        XCTAssertNil(try store.read("host:other:22"))
        try store.remove("host:fixture:22")
        XCTAssertNil(try store.read("host:fixture:22"))
    }

    @MainActor
    func testSavedConnectionRestoresWithoutAutomaticallyConnecting() throws {
        let name = "com.chadmux.tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName:name)!
        let secrets = SecretStore(service:name)
        defer { prefs.removePersistentDomain(forName:name); try? secrets.remove("device-ed25519") }
        let first = MacTransport(preferences:prefs,secrets:secrets)
        let profile = MacConnection(host:"fixture.example",port:2222,username:"fixture")
        try first.save(profile)
        let restored = MacTransport(preferences:prefs,secrets:secrets)
        XCTAssertEqual(restored.profile,profile)
        XCTAssertFalse(restored.connected)
        XCTAssertFalse(restored.connecting)
        XCTAssertThrowsError(try first.save(MacConnection(host:"bad\nhost",port:22,username:"fixture")))
        XCTAssertEqual(first.profile,profile)
    }

    func testForwardedHTTPRejectsTruncationAndErrors() throws {
        let body = "{\"text\":\"Use SSH.\",\"duration_seconds\":1.2}"
        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        XCTAssertEqual(try LoopbackAPI.decode(Data(response.utf8)).text,"Use SSH.")
        XCTAssertThrowsError(try LoopbackAPI.decode(Data(response.dropLast().utf8)))
        XCTAssertThrowsError(try LoopbackAPI.decode(Data(response.replacingOccurrences(of:"200 OK",with:"503 Unavailable").utf8)))
        XCTAssertThrowsError(try LoopbackAPI.decode(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n".utf8)))
    }
}


extension ConnectionTests {
    final class ClosedFlag: @unchecked Sendable {
        let lock = NSLock()
        private var value = false
        func mark() { lock.withLock { value = true } }
        var closed: Bool { lock.withLock { value } }
    }

    func testOpeningDeadlineReturnsBeforeLateResourceAndClosesIt() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let release = loop.makePromise(of: Void.self)
        let lateClosed = loop.makePromise(of: Void.self)
        let flag = ClosedFlag()
        do {
            let _: Int = try await LoopbackAPI.bounded(on: loop, timeout: .milliseconds(20)) { owner in
                try await release.futureResult.get() // deliberately never opens before deadline
                let accepted = owner.own { flag.mark(); lateClosed.succeed(()) }
                XCTAssertFalse(accepted)
                return 1
            }
            XCTFail("Stalled opening must time out")
        } catch { XCTAssertTrue(error is LoopbackAPI.Unavailable) }
        XCTAssertFalse(flag.closed)
        release.succeed(())
        try await lateClosed.futureResult.get()
        XCTAssertTrue(flag.closed)
    }

    func testCancellationBeforeChannelOpenClosesLateChild() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let started = loop.makePromise(of: Void.self)
        let release = loop.makePromise(of: Void.self)
        let lateClosed = loop.makePromise(of: Void.self)
        let child = ClosedFlag()
        let operation = Task {
            try await LoopbackAPI.bounded(on: loop, timeout: .seconds(5)) { owner in
                started.succeed(())
                try await release.futureResult.get()
                _ = owner.own { child.mark(); lateClosed.succeed(()) }
                return 1
            }
        }
        try await started.futureResult.get()
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled opening must return immediately") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(child.closed)
        release.succeed(())
        try await lateClosed.futureResult.get()
        XCTAssertTrue(child.closed)
    }
}


extension ConnectionTests {
    func testSessionListingRejectsInjectedOrDuplicateIDs() throws {
        XCTAssertEqual(try TmuxSessions.parseIDs("$0\n$21\n"), ["$0", "$21"])
        for invalid in ["name", "$1;touch bad", "$1\n$1", "$", "$١"] {
            XCTAssertThrowsError(try TmuxSessions.parseIDs(invalid))
        }
    }
}

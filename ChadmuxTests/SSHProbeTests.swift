import XCTest
import Network
@testable import Chadmux

final class SSHProbeTests: XCTestCase {
    func testBannersAreClassified() {
        XCTAssertEqual(SSHProbe.classify("SSH-2.0-OpenSSH_9.9\r\n"), .openSSH("SSH-2.0-OpenSSH_9.9"))
        XCTAssertEqual(SSHProbe.classify("SSH-2.0-Tailscale"), .tailscaleSSH("SSH-2.0-Tailscale"))
        XCTAssertEqual(SSHProbe.classify("SSH-2.0-dropbear_2022.83"), .otherSSH("SSH-2.0-dropbear_2022.83"))
        XCTAssertEqual(SSHProbe.classify("HTTP/1.1 400 Bad Request"), .notSSH)
        XCTAssertTrue(SSHProbe.Result.tailscaleSSH("x").isProblem)
        XCTAssertTrue(SSHProbe.Result.unreachable.isProblem)
        XCTAssertFalse(SSHProbe.Result.openSSH("x").isProblem)
        XCTAssertTrue(SSHProbe.Result.tailscaleSSH("x").message.contains("tailscale set --ssh=false"))
    }

    /// A one-shot local server that writes `banner` to whoever connects.
    private func serve(_ banner: String) throws -> (NWListener, Int) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: Data(banner.utf8), completion: .contentProcessed { _ in })
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, Int(listener.port!.rawValue))
    }

    func testProbesARealListener() async throws {
        let (openSSH, openPort) = try serve("SSH-2.0-OpenSSH_9.9\r\n")
        defer { openSSH.cancel() }
        let result = await SSHProbe.probe(host: "127.0.0.1", port: openPort)
        XCTAssertEqual(result, .openSSH("SSH-2.0-OpenSSH_9.9"))
        let (tailscale, tailscalePort) = try serve("SSH-2.0-Tailscale\r\n")
        defer { tailscale.cancel() }
        let warned = await SSHProbe.probe(host: "127.0.0.1", port: tailscalePort)
        XCTAssertEqual(warned, .tailscaleSSH("SSH-2.0-Tailscale"))
    }

    func testNothingListeningIsUnreachable() async throws {
        let (listener, port) = try serve("")
        listener.cancel()   // the port is now closed
        try await Task.sleep(nanoseconds: 200_000_000)
        let result = await SSHProbe.probe(host: "127.0.0.1", port: port, timeout: 3)
        XCTAssertEqual(result, .unreachable)
    }
}

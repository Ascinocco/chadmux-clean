import Foundation
import Citadel
import NIO
import NIOSSH

/// One bounded HTTP/1.1 request over SSH, never a local listener or public URL.
enum LoopbackAPI {
    struct Reply: Decodable, Sendable { let text: String; let duration_seconds: Double }
    struct Unavailable: Error {}
    struct InvalidToken: Error {}
    struct Rejected: Error { let status: Int }

    static func transcribe(client: SSHClient, recording: Data, token: String, port: Int = 8420) async throws -> Reply {
        guard (20...512).contains(token.count), token.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw InvalidToken() }
        guard !recording.isEmpty, recording.count <= 12 * 1024 * 1024 else { throw Unavailable() }
        return try await bounded(on: client.eventLoop, timeout: .seconds(120)) { ownership in
            let handler = ResponseHandler(promise: client.eventLoop.makePromise(of: Data.self))
            do {
                let channel = try await client.createDirectTCPIPChannel(using: .init(
                    targetHost: "127.0.0.1", targetPort: port,
                    originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))) { channel in
                        // Runs before SSH channel-open confirmation. A cancelled
                        // or late initializer refuses opening and closes its child.
                        guard ownership.own({ channel.close(promise: nil) }) else {
                            return channel.eventLoop.makeFailedFuture(CancellationError())
                        }
                        return channel.pipeline.addHandler(handler)
                    }
                try Task.checkCancellation()
                var request = ByteBuffer(string: "POST /transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: audio/mp4\r\nContent-Length: \(recording.count)\r\nConnection: close\r\n\r\n")
                request.writeBytes(recording)
                try await channel.writeAndFlush(request).get()
                let data = try await handler.promise.futureResult.get()
                try Task.checkCancellation()
                return try decode(data)
            } catch {
                client.eventLoop.execute { handler.fail(Unavailable()) }
                throw error
            }
        }
    }

    /// The caller's deadline includes channel opening. NIO may finish opening a
    /// child after cancellation; ownership also closes that eventual resource.
    static func bounded<T: Sendable>(on loop: EventLoop, timeout: TimeAmount,
        perform: @escaping @Sendable (ChannelOwnership) async throws -> T) async throws -> T {
        let result = loop.makePromise(of: T.self)
        let ownership = ChannelOwnership()
        let finish: @Sendable (Result<T, Error>) -> Void = { outcome in
            if ownership.finish() { result.completeWith(outcome) }
        }
        let deadline = loop.scheduleTask(in: timeout) { finish(.failure(Unavailable())) }
        return try await withTaskCancellationHandler {
            let worker = Task {
                do { finish(.success(try await perform(ownership))) }
                catch { finish(.failure(error)) }
            }
            defer { deadline.cancel(); worker.cancel() }
            return try await result.futureResult.get()
        } onCancel: { finish(.failure(CancellationError())) }
    }

    final class ChannelOwnership: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        private var close: (@Sendable () -> Void)?
        func own(_ close: @escaping @Sendable () -> Void) -> Bool {
            let active = lock.withLock {
                guard !ended else { return false }
                self.close = close
                return true
            }
            if !active { close() }
            return active
        }
        func finish() -> Bool {
            let action: (Bool, (@Sendable () -> Void)?) = lock.withLock {
                guard !ended else { return (false, nil) }
                ended = true
                let saved = close
                close = nil
                return (true, saved)
            }
            action.1?()
            return action.0
        }
    }

    static func decode(_ response: Data) throws -> Reply {
        guard let divider = response.range(of: Data("\r\n\r\n".utf8)), divider.lowerBound < 8192,
              let headers = String(data: response[..<divider.lowerBound], encoding: .utf8) else { throw Unavailable() }
        let lines = headers.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 "),
              let status = Int(first.split(separator: " ").dropFirst().first ?? "") else { throw Unavailable() }
        let body = response[divider.upperBound...]
        let lengths = lines.dropFirst().filter { $0.lowercased().hasPrefix("content-length:") }
        guard lengths.count == 1, let length = Int(lengths[0].split(separator: ":",maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)),
              length == body.count, length <= 65536,
              !lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else { throw Unavailable() }
        guard status == 200 else { throw Rejected(status: status) }
        let reply = try JSONDecoder().decode(Reply.self, from: body)
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply.text.count <= 16000 else { throw Unavailable() }
        return reply
    }

    // Mutable state is confined to the SSH child channel event loop.
    private final class ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<Data>
        var received = Data()
        var completed = false
        init(promise: EventLoopPromise<Data>) { self.promise = promise }
        func fail(_ error: Error) {
            guard !completed else { return }; completed = true; promise.fail(error)
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            guard received.count + buffer.readableBytes <= 73728 else {
                fail(Unavailable()); context.close(promise: nil); return
            }
            received.append(contentsOf: buffer.readableBytesView)
            if let divider = received.range(of: Data("\r\n\r\n".utf8)) {
                guard divider.lowerBound < 8192,
                      let header = String(data: received[..<divider.lowerBound], encoding: .utf8),
                      let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)),
                      (0...65536).contains(length) else {
                    fail(Unavailable()); context.close(promise: nil); return
                }
                if received.count >= divider.upperBound + length, !completed {
                    completed = true; promise.succeed(received); context.close(promise: nil)
                }
            } else if received.count > 8192 {
                fail(Unavailable()); context.close(promise: nil)
            }
        }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? ChannelEvent, event == .inputClosed {
                fail(Unavailable()); context.close(promise: nil)
            } else { context.fireUserInboundEventTriggered(event) }
        }
        func channelInactive(context: ChannelHandlerContext) {
            if !completed { completed = true; promise.succeed(received) }
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            fail(Unavailable()); context.close(promise: nil)
        }
    }
}

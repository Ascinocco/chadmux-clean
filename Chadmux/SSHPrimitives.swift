import Foundation
import Citadel
import Crypto
import NIOSSH

/// These values never embed commands supplied by terminal output or a user draft.
enum SSHPrimitives {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func authorizedKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let encoded = String(openSSHPublicKey: key).split(separator: " ")[1]
        let digest = SHA256.hash(data: Data(base64Encoded: String(encoded))!)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// An exact session ID avoids tmux name-pattern matching and shell quoting ambiguity.
    static func attachCommand(sessionID: String) throws -> String {
        guard sessionID.first == "$", sessionID.count > 1,
              sessionID.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw InvalidSessionID()
        }
        return "exec tmux attach-session -t " + shellQuote(sessionID)
    }

    struct InvalidSessionID: Error {}
}

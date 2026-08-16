import Darwin
import Foundation

/// Picks a free TCP port on the loopback interface.
///
/// Used to give the `whisper-server` child process a port nobody else is on. The
/// alternative — hard-coding whisper.cpp's default 8080 — collides with the many
/// other things that use it and would let an unrelated server on that port receive
/// the user's audio.
enum LocalPort {

    enum Failure: LocalizedError {
        case noPortAvailable

        var errorDescription: String? {
            "Could not reserve a local port for the transcription server."
        }
    }

    /// Asks the kernel for an unused loopback port and returns it.
    ///
    /// The socket is closed before returning, so there is a window in which something
    /// else could take the port before the child binds it. That window is why a failed
    /// server start is retried rather than treated as fatal — and why the caller falls
    /// back to the CLI instead of failing the dictation.
    static func reserve() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.noPortAvailable }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR,
            &reuse, socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                              // 0 = "any free port"
        // Loopback only. Binding the probe anywhere else would suggest the child could
        // be reachable off-box, which it must never be.
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Failure.noPortAvailable }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw Failure.noPortAvailable }

        // sin_port is network byte order.
        let port = UInt16(bigEndian: assigned.sin_port)
        guard port != 0 else { throw Failure.noPortAvailable }
        return port
    }
}

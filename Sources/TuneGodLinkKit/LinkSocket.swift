// A blocking stream socket (TCP, or the Unix socket to the Mac's device multiplexer). Writes are serialised by a lock so the audio and
// control paths can share one connection; reads happen on one thread.
import Foundation

public final class LinkSocket: @unchecked Sendable {
    public let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public var closed: Bool { stateLock.withLock { isClosed } }

    /// Low latency for TCP: send small writes at once.
    public func setNoDelay() {
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send(_ bytes: [UInt8]) throws {
        try writeLock.withLock {
            try bytes.withUnsafeBytes { buf in
                var sent = 0
                while sent < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw LinkError.socket("write", errno)
                    }
                    sent += n
                }
            }
        }
    }

    public func send(_ message: LinkMessage) throws { try send(message.encoded()) }

    /// Reads what is available (blocking until something is). 0 at the end of the stream.
    public func read(into buffer: inout [UInt8]) throws -> Int {
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                if closed { return 0 }
                throw LinkError.socket("read", errno)
            }
            return n
        }
    }

    public func readExactly(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n < 0 {
                if errno == EINTR { continue }
                throw LinkError.socket("read", errno)
            }
            if n == 0 { throw LinkError.closed }
            got += n
        }
        return out
    }

    public func close() {
        let first = stateLock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    // MARK: Opening

    public static func connectTCP(host: String, port: UInt16) throws -> LinkSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw LinkError.socket("resolve \(host)", EHOSTUNREACH) }
        defer { freeaddrinfo(res) }
        var lastError = ECONNREFUSED
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    let s = LinkSocket(fd: fd)
                    s.setNoDelay()
                    return s
                }
                lastError = errno
                Darwin.close(fd)
            }
            p = ai.pointee.ai_next
        }
        throw LinkError.socket("connect \(host):\(port)", lastError)
    }

    public static func connectUnix(path: String) throws -> LinkSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LinkError.socket("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.enumerated() where i < buf.count - 1 { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw LinkError.socket("connect \(String(decoding: path, as: UTF8.self))", e)
        }
        return LinkSocket(fd: fd)
    }
}

/// A listening TCP socket on the loopback address (what the phone opens; the simulator uses it on the Mac).
public final class LinkListener: @unchecked Sendable {
    public let fd: Int32

    public init(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LinkError.socket("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 2) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw LinkError.socket("listen on port \(port)", e)
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    public func accept() throws -> LinkSocket {
        while true {
            let c = Darwin.accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                throw LinkError.socket("accept", errno)
            }
            let s = LinkSocket(fd: c)
            s.setNoDelay()
            return s
        }
    }
}

import Darwin
import Foundation

enum UnixSocketError: Error, CustomStringConvertible {
  case pathTooLong(String)
  case connectionClosed
  case lockUnavailable(String)
  case lineTooLarge(actual: Int, maximum: Int)
  case payloadTooLarge(actual: Int, maximum: Int)
  case unsafeStaleSocket(String)
  case syscallFailed(name: String, errno: Int32)

  var description: String {
    switch self {
    case let .pathTooLong(path):
      return "Unix socket path is too long: \(path)"
    case .connectionClosed:
      return "Unix socket connection closed before the message completed"
    case let .lockUnavailable(path):
      return "Notification agent lock is already held: \(path)"
    case let .lineTooLarge(actual, maximum):
      return "Unix socket line is too large: \(actual) bytes (maximum: \(maximum))"
    case let .payloadTooLarge(actual, maximum):
      return "Unix socket frame is too large: \(actual) bytes (maximum: \(maximum))"
    case let .unsafeStaleSocket(path):
      return "Refusing to remove unsafe stale socket entry: \(path)"
    case let .syscallFailed(name, code):
      let message = String(cString: strerror(code))
      return "\(name) failed (\(code)): \(message)"
    }
  }
}

let maximumFramePayloadBytes = 1024 * 1024
let maximumSocketLineBytes = 1024 * 1024
private let frameHeaderBytes = 4

func connectUnixSocket(path: String) throws -> Int32 {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else {
    throw UnixSocketError.syscallFailed(name: "socket", errno: errno)
  }
  setNoSIGPIPE(on: fd)

  do {
    var address = try makeUnixAddress(path: path)
    let result = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.connect(fd, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      throw UnixSocketError.syscallFailed(name: "connect", errno: errno)
    }
    return fd
  } catch {
    Darwin.close(fd)
    throw error
  }
}

func makeListeningUnixSocket(path: String) throws -> Int32 {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else {
    throw UnixSocketError.syscallFailed(name: "socket", errno: errno)
  }
  setNoSIGPIPE(on: fd)

  do {
    var address = try makeUnixAddress(path: path)
    let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.bind(fd, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      throw UnixSocketError.syscallFailed(name: "bind", errno: errno)
    }

    guard Darwin.listen(fd, 16) == 0 else {
      throw UnixSocketError.syscallFailed(name: "listen", errno: errno)
    }

    return fd
  } catch {
    Darwin.close(fd)
    throw error
  }
}

func acquireAgentLock(path: String) throws -> Int32 {
  let fd = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  guard fd >= 0 else {
    throw UnixSocketError.syscallFailed(name: "open", errno: errno)
  }

  var lock = flock()
  lock.l_type = Int16(F_WRLCK)
  lock.l_whence = Int16(SEEK_SET)
  lock.l_start = 0
  lock.l_len = 0

  guard Darwin.fcntl(fd, F_SETLK, &lock) == 0 else {
    let code = errno
    Darwin.close(fd)
    if code == EACCES || code == EAGAIN {
      throw UnixSocketError.lockUnavailable(path)
    }
    throw UnixSocketError.syscallFailed(name: "fcntl", errno: code)
  }

  return fd
}

func removeOwnedStaleSocket(path: String) throws {
  var metadata = stat()
  guard Darwin.lstat(path, &metadata) == 0 else {
    if errno == ENOENT {
      return
    }
    throw UnixSocketError.syscallFailed(name: "lstat", errno: errno)
  }

  let isSocket = (metadata.st_mode & S_IFMT) == S_IFSOCK
  guard isSocket, metadata.st_uid == geteuid() else {
    throw UnixSocketError.unsafeStaleSocket(path)
  }

  guard unlink(path) == 0 else {
    throw UnixSocketError.syscallFailed(name: "unlink", errno: errno)
  }
}

func acceptClients(
  on serverFD: Int32,
  clientQueue: DispatchQueue,
  handler: @escaping @Sendable (Int32) -> Void
) {
  while true {
    let clientFD = Darwin.accept(serverFD, nil, nil)
    if clientFD < 0 {
      if errno == EINTR {
        continue
      }
      if errno == EBADF || errno == EINVAL {
        return
      }
      continue
    }
    clientQueue.async {
      handler(clientFD)
    }
  }
}

func setSocketTimeout(on fd: Int32, seconds: TimeInterval) throws {
  let boundedSeconds = max(seconds, 0.001)
  var timeout = timeval(
    tv_sec: Int(boundedSeconds),
    tv_usec: Int32((boundedSeconds.truncatingRemainder(dividingBy: 1)) * 1_000_000)
  )

  for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
    let result = withUnsafePointer(to: &timeout) { pointer in
      Darwin.setsockopt(fd, SOL_SOCKET, option, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
    guard result == 0 else {
      throw UnixSocketError.syscallFailed(name: "setsockopt", errno: errno)
    }
  }
}

private func readExactly(_ byteCount: Int, from fd: Int32) throws -> Data {
  var data = Data(count: byteCount)
  var offset = 0

  try data.withUnsafeMutableBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }

    while offset < byteCount {
      let bytesRead = Darwin.read(fd, baseAddress.advanced(by: offset), byteCount - offset)
      if bytesRead == 0 {
        throw UnixSocketError.connectionClosed
      }
      if bytesRead < 0 {
        if errno == EINTR {
          continue
        }
        throw UnixSocketError.syscallFailed(name: "read", errno: errno)
      }
      offset += bytesRead
    }
  }

  return data
}

func readFrame(from fd: Int32, maximumPayloadBytes: Int = maximumFramePayloadBytes) throws -> Data {
  let header = try readExactly(frameHeaderBytes, from: fd)
  let length = header.reduce(UInt32(0)) { partial, byte in
    (partial << 8) | UInt32(byte)
  }
  let payloadLength = Int(length)

  guard payloadLength <= maximumPayloadBytes else {
    throw UnixSocketError.payloadTooLarge(actual: payloadLength, maximum: maximumPayloadBytes)
  }
  guard payloadLength > 0 else {
    return Data()
  }

  return try readExactly(payloadLength, from: fd)
}

func writeFrame(_ data: Data, to fd: Int32) throws {
  guard data.count <= maximumFramePayloadBytes else {
    throw UnixSocketError.payloadTooLarge(actual: data.count, maximum: maximumFramePayloadBytes)
  }

  let length = UInt32(data.count)
  let header = Data([
    UInt8((length >> 24) & 0xFF),
    UInt8((length >> 16) & 0xFF),
    UInt8((length >> 8) & 0xFF),
    UInt8(length & 0xFF),
  ])
  try writeAll(header, to: fd)
  try writeAll(data, to: fd)
}

func readSocketLine(from fd: Int32, maximumBytes: Int = maximumSocketLineBytes) throws -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)

  while true {
    let bytesRead = Darwin.read(fd, &buffer, buffer.count)
    if bytesRead == 0 {
      throw UnixSocketError.connectionClosed
    }
    if bytesRead < 0 {
      if errno == EINTR {
        continue
      }
      throw UnixSocketError.syscallFailed(name: "read", errno: errno)
    }

    let chunk = buffer.prefix(bytesRead)
    if let newlineIndex = chunk.firstIndex(of: 0x0A) {
      let count = chunk.distance(from: chunk.startIndex, to: newlineIndex)
      guard data.count + count <= maximumBytes else {
        throw UnixSocketError.lineTooLarge(actual: data.count + count, maximum: maximumBytes)
      }
      data.append(contentsOf: chunk.prefix(count))
      return data
    }

    guard data.count + bytesRead <= maximumBytes else {
      throw UnixSocketError.lineTooLarge(actual: data.count + bytesRead, maximum: maximumBytes)
    }
    data.append(contentsOf: chunk)
  }
}

func writeSocketLine(_ data: Data, to fd: Int32) throws {
  guard data.count <= maximumSocketLineBytes else {
    throw UnixSocketError.lineTooLarge(actual: data.count, maximum: maximumSocketLineBytes)
  }
  try writeAll(data + Data([0x0A]), to: fd)
}

typealias SocketWriteOperation = (Int32, UnsafeRawPointer, Int) -> Int

func writeAll(
  _ data: Data,
  to fd: Int32,
  writeOperation: SocketWriteOperation = { descriptor, buffer, count in
    Darwin.write(descriptor, buffer, count)
  }
) throws {
  var offset = 0
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }

    while offset < rawBuffer.count {
      let bytesWritten = writeOperation(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
      if bytesWritten == 0 {
        throw UnixSocketError.connectionClosed
      }
      if bytesWritten < 0 {
        if errno == EINTR {
          continue
        }
        throw UnixSocketError.syscallFailed(name: "write", errno: errno)
      }
      offset += bytesWritten
    }
  }
}

func setNoSIGPIPE(on fd: Int32) {
  var noSIGPIPE: Int32 = 1
  withUnsafePointer(to: &noSIGPIPE) { pointer in
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
  }
}

private func makeUnixAddress(path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)

  let maxLength = MemoryLayout.size(ofValue: address.sun_path)
  let pathCString = path.utf8CString
  guard pathCString.count <= maxLength else {
    throw UnixSocketError.pathTooLong(path)
  }

  let result = pathCString.withUnsafeBufferPointer { buffer in
    strncpy(&address.sun_path.0, buffer.baseAddress, maxLength - 1)
  }

  _ = result
  return address
}

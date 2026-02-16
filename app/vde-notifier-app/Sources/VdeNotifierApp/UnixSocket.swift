import Darwin
import Foundation

enum UnixSocketError: Error, CustomStringConvertible {
  case pathTooLong(String)
  case syscallFailed(name: String, errno: Int32)

  var description: String {
    switch self {
    case let .pathTooLong(path):
      return "Unix socket path is too long: \(path)"
    case let .syscallFailed(name, code):
      let message = String(cString: strerror(code))
      return "\(name) failed (\(code)): \(message)"
    }
  }
}

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

  unlink(path)

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

func readAll(from fd: Int32) throws -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)

  while true {
    let bytesRead = Darwin.read(fd, &buffer, buffer.count)
    if bytesRead == 0 {
      break
    }
    if bytesRead < 0 {
      if errno == EINTR {
        continue
      }
      throw UnixSocketError.syscallFailed(name: "read", errno: errno)
    }
    data.append(contentsOf: buffer[0 ..< Int(bytesRead)])
  }

  return data
}

func writeAll(_ data: Data, to fd: Int32) throws {
  var offset = 0
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }

    while offset < rawBuffer.count {
      let bytesWritten = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
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

func socketExistsAndReachable(path: String) -> Bool {
  do {
    let fd = try connectUnixSocket(path: path)
    Darwin.close(fd)
    return true
  } catch {
    return false
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

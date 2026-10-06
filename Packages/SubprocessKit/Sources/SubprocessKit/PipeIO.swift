import Darwin
import Dispatch
import Foundation

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
}

/// Reads a pipe without ever blocking a thread: a non-blocking descriptor watched by a
/// `DispatchSourceRead`. Everything runs on the serial `queue` it is given, so no lock is needed;
/// a blocking `read` on a Swift-concurrency thread could starve the cooperative pool.
final class PipeReader: @unchecked Sendable {
    private static let bufferSize = 64 * 1_024

    private let fd: Int32
    private let source: DispatchSourceRead
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: PipeReader.bufferSize, alignment: 1)
    private let onData: @Sendable (Data) -> Void
    private var finished = false

    init(fd: Int32, queue: DispatchQueue, onData: @escaping @Sendable (Data) -> Void) {
        self.fd = fd
        self.onData = onData
        setNonBlocking(fd)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in pump() }
        // The descriptor may only be closed once the source is done with it.
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { buffer.deallocate() }

    /// Reads what is there, until the pipe would block or ends.
    private func pump() {
        while !finished {
            let count = read(fd, buffer, Self.bufferSize)
            if count > 0 {
                onData(Data(bytes: buffer, count: count))
            } else if count == 0 {
                stop()  // every writer closed its end
            } else if errno == EINTR {
                continue
            } else {
                if errno != EAGAIN { stop() }
                return
            }
        }
    }

    /// The child is gone: take what it left in the pipe and stop, even if a grandchild still holds
    /// the write end open. Must run on the reader's queue.
    func finish() {
        pump()
        stop()
    }

    private func stop() {
        guard !finished else { return }
        finished = true
        source.cancel()
    }
}

/// Writes data to a child's stdin without blocking, then closes the pipe. A child that exits or
/// closes stdin before everything was written ends the write quietly.
final class PipeWriter: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceWrite
    private let data: Data
    private var offset = 0
    private var finished = false

    init(fd: Int32, data: Data, queue: DispatchQueue) {
        self.fd = fd
        self.data = data
        setNonBlocking(fd)
        // A write to a pipe nobody reads raises SIGPIPE, which would end the app; ask for EPIPE instead.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in pump() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func pump() {
        while !finished, offset < data.count {
            let written = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                return  // the pipe is full; the source fires again when there is room
            } else {
                stop()  // EPIPE or anything else: the child stopped reading
                return
            }
        }
        stop()
    }

    func cancel() { stop() }

    private func stop() {
        guard !finished else { return }
        finished = true
        source.cancel()
    }
}

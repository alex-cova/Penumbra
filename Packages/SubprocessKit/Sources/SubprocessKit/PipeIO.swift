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

/// Writes to a child's stdin without blocking. Either everything is given up front and the pipe is
/// closed once it is written, or the pipe stays open and more arrives through `append(_:)` until
/// `closeInput()`. A child that exits or closes stdin before everything was written ends the write
/// quietly. Every method must run on the `queue` it was given.
final class PipeWriter: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceWrite
    private var pending: Data
    private var closeWhenDrained: Bool
    private var finished = false
    /// A write source that is resumed fires whenever the pipe has room, which is always while
    /// nothing is waiting to be written; it is only resumed while there is something to send.
    private var isResumed = false

    init(fd: Int32, data: Data, closeAfterWriting: Bool = true, queue: DispatchQueue) {
        self.fd = fd
        pending = data
        closeWhenDrained = closeAfterWriting
        setNonBlocking(fd)
        // A write to a pipe nobody reads raises SIGPIPE, which would end the app; ask for EPIPE instead.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in pump() }
        source.setCancelHandler { close(fd) }
        if !pending.isEmpty {
            resumeSource()
        } else if closeWhenDrained {
            stop()
        }
    }

    /// Queues `data` behind what is waiting. Ignored once the pipe is closed or the child stopped reading.
    func append(_ data: Data) {
        guard !finished, !closeWhenDrained, !data.isEmpty else { return }
        pending.append(data)
        resumeSource()
    }

    /// Closes the pipe once everything queued is written, so the child sees end of input.
    func closeInput() {
        guard !finished else { return }
        closeWhenDrained = true
        if pending.isEmpty { stop() } else { resumeSource() }
    }

    func cancel() { stop() }

    private func pump() {
        while !finished, !pending.isEmpty {
            let written = pending.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!, raw.count)
            }
            if written > 0 {
                pending.removeSubrange(pending.startIndex..<pending.startIndex + written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                return  // the pipe is full; the source fires again when there is room
            } else {
                stop()  // EPIPE or anything else: the child stopped reading
                return
            }
        }
        guard !finished else { return }
        if closeWhenDrained {
            stop()
        } else if isResumed {
            isResumed = false
            source.suspend()
        }
    }

    private func resumeSource() {
        guard !isResumed, !finished else { return }
        isResumed = true
        source.resume()
    }

    private func stop() {
        guard !finished else { return }
        finished = true
        pending = Data()
        source.cancel()
        // A source that was never resumed (or is suspended) delivers no cancel handler, and
        // releasing it in that state is a libdispatch error.
        if !isResumed {
            isResumed = true
            source.resume()
        }
    }
}

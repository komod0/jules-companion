import Foundation
import Collections

enum BufferSource: Equatable {
    case original
    case added
}

struct Span: Equatable {
    let source: BufferSource
    let start: Int
    let length: Int
}

struct PieceTable {
    let originalBuffer: String
    var addedBuffer: String // Mutable for edits

    // Using Deque for O(1) inserts at ends and efficient slicing
    private(set) var spans: Deque<Span>

    // Cache total length
    private(set) var length: Int

    init(original: String, added: String = "") {
        self.originalBuffer = original
        self.addedBuffer = added
        self.spans = []
        self.length = 0

        if !original.isEmpty {
            self.spans.append(Span(source: .original, start: 0, length: original.count))
            self.length += original.count
        }
    }

    func string() -> String {
        var result = ""
        result.reserveCapacity(length)
        for span in spans {
            let buffer = (span.source == .original) ? originalBuffer : addedBuffer
            let start = buffer.index(buffer.startIndex, offsetBy: span.start)
            let end = buffer.index(start, offsetBy: span.length)
            result += buffer[start..<end]
        }
        return result
    }

    // Insert text at index
    mutating func insert(_ text: String, at index: Int) {
        if text.isEmpty { return }

        // Add text to append buffer
        let addedStart = addedBuffer.count
        addedBuffer += text
        let newSpan = Span(source: .added, start: addedStart, length: text.count)

        // Optimization: Append to end
        if index == length {
            spans.append(newSpan)
            length += text.count
            return
        }

        // Find split point
        var remaining = index
        var spanIndex = 0

        while spanIndex < spans.count {
            let span = spans[spanIndex]
            if remaining < span.length {
                // Split here
                if remaining == 0 {
                    spans.insert(newSpan, at: spanIndex)
                } else {
                    let prefixSpan = Span(source: span.source, start: span.start, length: remaining)
                    let suffixSpan = Span(source: span.source, start: span.start + remaining, length: span.length - remaining)

                    spans[spanIndex] = prefixSpan
                    spans.insert(newSpan, at: spanIndex + 1)
                    spans.insert(suffixSpan, at: spanIndex + 2)
                }
                length += text.count
                return
            }
            remaining -= span.length
            spanIndex += 1
        }
    }

    // Delete range
    mutating func delete(at index: Int, length: Int) {
        if length == 0 { return }
        var remainingToDelete = length
        var currentIndex = index

        var spanIdx = 0
        var offset = 0

        while spanIdx < spans.count && remainingToDelete > 0 {
            let span = spans[spanIdx]

            let spanStart = offset
            let spanEnd = offset + span.length

            let deleteStart = currentIndex
            let deleteEnd = currentIndex + remainingToDelete

            let intersectStart = max(spanStart, deleteStart)
            let intersectEnd = min(spanEnd, deleteEnd)

            if intersectStart < intersectEnd {
                let deleteLen = intersectEnd - intersectStart

                if deleteLen == span.length {
                    spans.remove(at: spanIdx)
                    offset += 0
                } else if intersectStart == spanStart {
                    let keepLen = span.length - deleteLen
                    let newSpan = Span(source: span.source, start: span.start + deleteLen, length: keepLen)
                    spans[spanIdx] = newSpan
                    spanIdx += 1
                } else if intersectEnd == spanEnd {
                    let keepLen = span.length - deleteLen
                    let newSpan = Span(source: span.source, start: span.start, length: keepLen)
                    spans[spanIdx] = newSpan
                    spanIdx += 1
                } else {
                    let prefixLen = intersectStart - spanStart
                    let suffixLen = spanEnd - intersectEnd

                    let prefix = Span(source: span.source, start: span.start, length: prefixLen)
                    let suffix = Span(source: span.source, start: span.start + prefixLen + deleteLen, length: suffixLen)

                    spans[spanIdx] = prefix
                    spans.insert(suffix, at: spanIdx + 1)
                    spanIdx += 2
                }

                remainingToDelete -= deleteLen
            } else {
                 if offset > deleteEnd { break }
                 offset += span.length
                 spanIdx += 1
            }
        }

        self.length -= length
    }

    // MARK: - Phase 2: Span-Based Traversal

    /// Iterator that returns raw UTF-8 byte chunks for efficient memory access.
    /// Avoids Character object creation overhead by providing direct buffer access.
    struct SpanIterator: IteratorProtocol {
        private let pieceTable: PieceTable
        private var spanIndex: Int = 0
        private var offsetInSpan: Int = 0

        init(_ pieceTable: PieceTable) {
            self.pieceTable = pieceTable
        }

        /// Returns the next chunk of UTF-8 bytes as an UnsafeBufferPointer.
        /// The pointer is valid only until the next call to next() or until
        /// the PieceTable is modified.
        mutating func next() -> (buffer: UnsafeBufferPointer<UInt8>, source: BufferSource)? {
            guard spanIndex < pieceTable.spans.count else { return nil }

            let span = pieceTable.spans[spanIndex]
            let buffer = (span.source == .original) ? pieceTable.originalBuffer : pieceTable.addedBuffer

            // Get the UTF-8 view
            let utf8 = buffer.utf8

            // Calculate the byte range for this span
            let startIndex = buffer.index(buffer.startIndex, offsetBy: span.start)
            let endIndex = buffer.index(startIndex, offsetBy: span.length)

            // Move to next span for subsequent call
            spanIndex += 1

            // Return the UTF-8 bytes for this span
            return buffer[startIndex..<endIndex].withCString { ptr in
                let count = buffer[startIndex..<endIndex].utf8.count
                return (UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: count), span.source)
            }
        }
    }

    /// Creates an iterator for span-based traversal.
    /// More efficient than materializing the full string.
    func makeSpanIterator() -> SpanIterator {
        return SpanIterator(self)
    }

    /// Iterate over all spans, calling the closure with each chunk's bytes.
    /// This is more efficient than creating String objects for each span.
    ///
    /// - Parameter body: Closure called with (bytes, length, source) for each span
    func withSpans(_ body: (UnsafeRawBufferPointer, BufferSource) -> Void) {
        for span in spans {
            let buffer = (span.source == .original) ? originalBuffer : addedBuffer
            let startIndex = buffer.index(buffer.startIndex, offsetBy: span.start)
            let endIndex = buffer.index(startIndex, offsetBy: span.length)

            buffer[startIndex..<endIndex].withCString { ptr in
                let bytes = UnsafeRawBufferPointer(
                    start: ptr,
                    count: buffer[startIndex..<endIndex].utf8.count
                )
                body(bytes, span.source)
            }
        }
    }

    /// Get a substring for a specific range without full materialization.
    /// Uses copy-on-write semantics for efficiency.
    ///
    /// - Parameters:
    ///   - start: Start index in the logical document
    ///   - length: Number of characters to extract
    /// - Returns: The substring, or nil if range is invalid
    func substring(at start: Int, length: Int) -> String? {
        guard start >= 0 && start + length <= self.length else { return nil }

        var result = ""
        result.reserveCapacity(length)

        var remaining = length
        var currentOffset = 0
        var skipChars = start

        for span in spans {
            if remaining == 0 { break }

            if skipChars >= span.length {
                skipChars -= span.length
                continue
            }

            let buffer = (span.source == .original) ? originalBuffer : addedBuffer
            let spanStart = span.start + skipChars
            let charsToTake = min(span.length - skipChars, remaining)

            let startIdx = buffer.index(buffer.startIndex, offsetBy: spanStart)
            let endIdx = buffer.index(startIdx, offsetBy: charsToTake)
            result += buffer[startIdx..<endIdx]

            remaining -= charsToTake
            skipChars = 0
        }

        return result
    }
}

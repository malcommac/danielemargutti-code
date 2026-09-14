import Foundation

/// Stage 1 : reading in 64 KB blocks, hand-written scalar loop.
///
/// This is the first working version: a `FileHandle` that hands over 64 KB at a
/// time, and a state machine that looks at one byte at a time to find where rows
/// end without being fooled by newlines inside quoted fields.
///
/// The detail that matters: the three state variables live **outside** the block
/// loop. A quoted field can start at byte 65,000 and end in the next block, so
/// the state has to survive the boundary.
///
/// Measured: ~0.38s in release, ~21s in debug.
public enum StageChunks {

    public static let bufferSize = 65_536

    public static func indexLines(
        fileURL: URL,
        quoteByte: UInt8 = 0x22,
        delimiterByte: UInt8 = 0x2C
    ) throws -> [Int] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var offsets: [Int] = [0]
        var fileOffset = 0

        // Has to survive from one block to the next.
        var atFieldStart = true
        var fieldIsQuoted = false
        var inQuotes = false

        while true {
            let data = handle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { break }

            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in 0..<bytes.count {
                    let b = bytes[i]

                    // First byte of a field: this is the only place where a quote
                    // can open a quoted field. Later in the field it is just data.
                    if atFieldStart {
                        atFieldStart = false
                        if b == quoteByte {
                            fieldIsQuoted = true
                            inQuotes = true
                            continue
                        }
                        fieldIsQuoted = false
                    }

                    if fieldIsQuoted && b == quoteByte {
                        // Inside a quoted field every quote flips us in or out.
                        inQuotes.toggle()
                    } else if !inQuotes {
                        // Outside quotes the separators actually mean something.
                        if b == delimiterByte {
                            atFieldStart = true
                            fieldIsQuoted = false
                        } else if b == 0x0A {
                            atFieldStart = true
                            fieldIsQuoted = false
                            offsets.append(fileOffset + i + 1)
                        }
                    }
                }
            }

            fileOffset += data.count
        }

        // If the file ends with a newline the last offset points past the end:
        // that is a phantom row and has to go.
        if offsets.last == fileOffset { offsets.removeLast() }

        return offsets
    }
}

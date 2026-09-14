import Foundation

/// Stage 2 : the file mapped into memory, same scalar loop.
///
/// Compared to stage 1 the state machine is identical byte for byte. What
/// disappears is everything around it: the block loop, the temporary `Data`
/// objects (roughly 4,000 allocations on a 260 MB file), the full copy of the
/// contents, and the fact that the state had to survive block boundaries.
///
/// The three state variables are still here, but they are now ordinary locals
/// of a single `for`: they no longer cross anything.
///
/// **Measured: ~0.38s in release : identical to stage 1.**
///
/// `mmap` buys no speed here, and that makes sense: the bottleneck is the scalar
/// loop looking at one byte at a time, not how the bytes arrive. What `mmap` buys
/// is structural : a stable pointer to build zero-copy access on, and the removal
/// of all the block bookkeeping.
///
/// (During development this stage had looked twice as fast as the previous one.
/// It was not: that comparison put a cold measurement against a warm one. Also
/// tried with `madvise(MADV_SEQUENTIAL)`: no difference.)
public enum StageMmap {

    public enum Failure: Error {
        case cannotOpen
        case cannotStat
        case emptyFile
        case cannotMap
    }

    public static func indexLines(
        fileURL: URL,
        quoteByte: UInt8 = 0x22,
        delimiterByte: UInt8 = 0x2C
    ) throws -> [Int] {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.cannotOpen }
        // Safe to close right away: once the mapping exists it holds its own
        // reference, and the memory stays valid even with the file closed.
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.cannotStat }

        let size = Int(info.st_size)
        guard size > 0 else { throw Failure.emptyFile }

        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else { throw Failure.cannotMap }
        defer { munmap(mapped, size) }

        let base = UnsafePointer(mapped.assumingMemoryBound(to: UInt8.self))

        var offsets: [Int] = [0]
        var atFieldStart = true
        var fieldIsQuoted = false
        var inQuotes = false

        for i in 0..<size {
            let b = base[i]

            // Same four branches as stage 1 : only the surroundings changed.
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
                inQuotes.toggle()
            } else if !inQuotes {
                if b == delimiterByte {
                    atFieldStart = true
                    fieldIsQuoted = false
                } else if b == 0x0A {
                    atFieldStart = true
                    fieldIsQuoted = false
                    offsets.append(i + 1)
                }
            }
        }

        if offsets.last == size { offsets.removeLast() }

        return offsets
    }
}

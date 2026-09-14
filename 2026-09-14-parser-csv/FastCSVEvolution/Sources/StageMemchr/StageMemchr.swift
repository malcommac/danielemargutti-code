import Foundation

/// Stage 3 : `memchr` plus sniffing for quotes.
///
/// Two ideas, both small.
///
/// The first: if there is no need to track quotes, finding newlines is not a
/// logic problem but a search problem : and libc's `memchr` is hand-written SIMD,
/// so it chews through sixteen bytes per iteration instead of one.
///
/// The second, which is what makes the first usable: **how do you know quote
/// tracking isn't needed?** You check whether the file contains at least one
/// quote. If there isn't a single quote in 260 MB, then no field can be quoted,
/// so no newline can sit inside a field : and the fast path is provably correct,
/// without asking the caller to promise anything.
///
/// Sniffing costs a full pass, but almost nothing in practice: it is the one
/// paying the page faults, and the scan that follows finds the pages warm.
///
/// Measured: ~0.065s in release on a file without quotes.
public enum StageMemchr {

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
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.cannotStat }

        let size = Int(info.st_size)
        guard size > 0 else { throw Failure.emptyFile }

        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else { throw Failure.cannotMap }
        defer { munmap(mapped, size) }

        let base = UnsafePointer(mapped.assumingMemoryBound(to: UInt8.self))

        // The sniff.
        let hasQuotes = memchr(base, Int32(quoteByte), size) != nil

        var offsets: [Int] = [0]

        guard hasQuotes else {
            // No quotes anywhere, so no field is quoted and every newline is a
            // real row boundary. Searching for them is all we have to do.
            var pos = 0
            while pos < size,
                  let hit = memchr(base + pos, 0x0A, size - pos) {
                // memchr returns a pointer; subtracting the base gives the offset.
                let i = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                offsets.append(i + 1)
                pos = i + 1
            }
            if offsets.last == size { offsets.removeLast() }
            return offsets
        }

        // The file does contain quotes: we need stage 2's state machine.
        var atFieldStart = true
        var fieldIsQuoted = false
        var inQuotes = false

        for i in 0..<size {
            let b = base[i]

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

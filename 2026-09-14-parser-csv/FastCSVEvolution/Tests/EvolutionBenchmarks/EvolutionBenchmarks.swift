import Foundation
import Testing
import StageChunks
import StageMmap
import StageMemchr

// Comparison between the successive stages of the line indexing.
//
// All three run in the same process, back to back, on the same file already warm
// in the page cache: it is the only way the comparison means anything.
//
//   swift test -c release     ← the numbers quoted in the article
//   swift test                ← the same, in debug: the gap is the surprise
//
// The suite is .serialized because Swift Testing parallelizes by default, and two
// concurrent benchmarks fight over CPU and memory.

private let gtfsURL = URL(
    // In order to use the same data you may download the GTFS static map package from here:
    // <https://dati.comune.roma.it/catalog/dataset/c_h501-d-9000>
    // and extract the zip file (https://dati.comune.roma.it/catalog/dataset/c_h501-d-9000#)
    // `stop_times.txt` is inside.
    fileURLWithPath: "~/PATH/stop_times.txt"
)

private let gtfsAvailable = FileManager.default.fileExists(atPath: gtfsURL.path)

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Suite(.serialized)
struct Evolution {

    /// Before timing anything: the three stages must produce the exact same index.
    /// An optimization that changes the result is not an optimization, it is a
    /// faster bug.
    @Test func allStagesAgreeOnAFileWithQuotes() throws {
        // Raw string: the CSV contains `"""` (a doubled quote followed by the
        // closing one), which would terminate a regular literal.
        let csv = #"""
        name,note,price
        monitor 24" full HD,nothing,199
        keyboard,"line one
        line two",49
        mouse,"said ""hi""",19

        """#

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evolution-\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try StageChunks.indexLines(fileURL: url)
        let mapped = try StageMmap.indexLines(fileURL: url)
        let memchr = try StageMemchr.indexLines(fileURL: url)

        // Header plus 3 rows: the newline inside the quotes does not count.
        #expect(chunks.count == 4)
        #expect(mapped == chunks)
        #expect(memchr == chunks)
    }

    @Test(.enabled(if: gtfsAvailable))
    func stageComparison() throws {
        let clock = ContinuousClock()

        // Warm-up: pulls the 260 MB into the page cache, otherwise the first stage
        // measured is timing the disk and looks like the worst of the three.
        _ = try StageMemchr.indexLines(fileURL: gtfsURL)

        let t0 = clock.now
        let chunks = try StageChunks.indexLines(fileURL: gtfsURL)
        let chunksTime = clock.now - t0

        let t1 = clock.now
        let mapped = try StageMmap.indexLines(fileURL: gtfsURL)
        let mappedTime = clock.now - t1

        let t2 = clock.now
        let memchr = try StageMemchr.indexLines(fileURL: gtfsURL)
        let memchrTime = clock.now - t2

        // Again: same result, or the timings mean nothing.
        #expect(mapped == chunks)
        #expect(memchr == chunks)

        let attributes = try FileManager.default.attributesOfItem(atPath: gtfsURL.path)
        let gigabytes = Double((attributes[.size] as? Int) ?? 0) / 1_073_741_824

        func throughput(_ d: Duration) -> String {
            String(format: "%.2f GB/s", gigabytes / seconds(d))
        }

        print("""

        ── line indexing, \(chunks.count) rows ──
          1. 64 KB blocks       \(String(format: "%7.3f", seconds(chunksTime)))s   \(throughput(chunksTime))
          2. mmap               \(String(format: "%7.3f", seconds(mappedTime)))s   \(throughput(mappedTime))
          3. mmap + memchr      \(String(format: "%7.3f", seconds(memchrTime)))s   \(throughput(memchrTime))

             1 → 2: \(String(format: "%.1f", seconds(chunksTime) / seconds(mappedTime)))x
             2 → 3: \(String(format: "%.1f", seconds(mappedTime) / seconds(memchrTime)))x
             total: \(String(format: "%.1f", seconds(chunksTime) / seconds(memchrTime)))x

        """)
    }

    @Test(.enabled(if: gtfsAvailable))
    func naiveVersion() throws {
        let clock = ContinuousClock()

        // Warm-up
        let _ = try String(contentsOf: gtfsURL, encoding: .utf8)

        let t0 = clock.now
        let text = try String(contentsOf: gtfsURL, encoding: .utf8)
        let readTime = clock.now - t0

        // A — components(separatedBy:): creates a String for every row and every field
        func withComponents() -> Duration {
            let t = clock.now
            var fields = 0
            for riga in text.components(separatedBy: "\n") {
                fields += riga.components(separatedBy: ",").count
            }
            precondition(fields > 0)
            return clock.now - t
        }

        // B — split(separator:): returns Substring, which are slices without copying
        func withSplit() -> Duration {
            let t = clock.now
            var fields = 0
            for riga in text.split(separator: "\n", omittingEmptySubsequences: false) {
                fields += riga.split(separator: ",", omittingEmptySubsequences: false).count
            }
            precondition(fields > 0)
            return clock.now - t
        }

        let a1 = withComponents()
        let b1 = withSplit()
        let b2 = withSplit()
        let a2 = withComponents()

        let driftA = abs(seconds(a1) - seconds(a2)) / seconds(a1) * 100
        let driftB = abs(seconds(b1) - seconds(b2)) / seconds(b1) * 100

        print("""

        ── naive version — same 260 MB ──
          String(contentsOf:)         \(String(format: "%.3f", seconds(readTime)))s
          A. components(separatedBy:) \(String(format: "%.3f", seconds(a1)))s
          B. split(separator:)        \(String(format: "%.3f", seconds(b1)))s

          check order — A repeated \(String(format: "%.3f", seconds(a2)))s, B repeated \(String(format: "%.3f", seconds(b2)))s
          drift: A \(String(format: "%.1f", driftA))%, B \(String(format: "%.1f", driftB))%

        """)

        #expect(driftA < 10)
        #expect(driftB < 10)
    }
}

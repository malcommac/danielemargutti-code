// swift-tools-version: 6.4

import PackageDescription

// Gli stadi successivi dell'indicizzazione di FastCSV, congelati uno per target
// così che i numeri dell'articolo siano riproducibili.
//
// Ogni stadio espone la stessa identica funzione : `indexLines(fileURL:)` : e
// deve produrre lo stesso identico risultato: è il benchmark a verificarlo.
//
//   swift test -c release
//   swift test              ← per il confronto debug/release
let package = Package(
    name: "FastCSVEvolution",
    targets: [
        .target(name: "StageChunks"),
        .target(name: "StageMmap"),
        .target(name: "StageMemchr"),
        .testTarget(
            name: "EvolutionBenchmarks",
            dependencies: ["StageChunks", "StageMmap", "StageMemchr"]
        ),
    ]
)

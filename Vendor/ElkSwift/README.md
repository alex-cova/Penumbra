# ElkSwift

A pure Swift port of the [Eclipse Layout Kernel (ELK)](https://www.eclipse.org/elk/) graph layout engine.

ElkSwift runs ELK's layered layout algorithm natively in Swift — no JavaScriptCore, no bridging. It can be used for any graph layout task.

## Usage

```swift
import ElkSwift

let elk = ELK()

let graph: [String: Any] = [
    "id": "root",
    "layoutOptions": [
        "elk.algorithm": "layered",
        "elk.direction": "DOWN"
    ],
    "children": [
        ["id": "A", "width": 100, "height": 40],
        ["id": "B", "width": 100, "height": 40],
        ["id": "C", "width": 100, "height": 40]
    ],
    "edges": [
        ["id": "e1", "sources": ["A"], "targets": ["B"]],
        ["id": "e2", "sources": ["B"], "targets": ["C"]]
    ]
]

let result = try elk.layout(graph: graph)
// result contains the same graph structure with x, y positions filled in
```

### Options

Pass ELK layout options either inline on the graph/nodes, or as a separate dictionary:

```swift
let result = try elk.layout(
    graph: graph,
    options: ["elk.spacing.nodeNode": "20"]
)
```

### Timeouts

Layout calls accept an optional timeout (default: 30 seconds). Useful for preventing runaway layouts on complex graphs:

```swift
let result = try elk.layout(graph: graph, timeout: 5.0)
// Throws ELK.Error.timedOut if layout exceeds 5 seconds
```

### Thread Safety

Each `ELK` instance is independent — you can run multiple layouts concurrently on separate instances without synchronization:

```swift
let graphs: [[String: Any]] = [graph1, graph2, graph3]

DispatchQueue.concurrentPerform(iterations: graphs.count) { i in
    let elk = ELK()
    let result = try! elk.layout(graph: graphs[i])
    // ...
}
```

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lukilabs/elk-swift.git", from: "1.0.0")
]
```

Or in Xcode: File > Add Package Dependencies, then enter the repository URL.

### Requirements

- Swift 5.9+
- iOS 15+ / macOS 12+ / Mac Catalyst 15+ / visionOS 1.0+

## Supported Algorithm

Currently, only the **ELK Layered** algorithm is implemented. This covers the vast majority of use cases including flowcharts, sequence diagrams, class diagrams, state diagrams, and ER diagrams.

Supported features:
- Hierarchical/compound graphs (nested subgraphs)
- Edge labels
- Ports
- Self-loops
- Multi-edges
- Clusters

## How It Works

The ELK Java source code was transpiled to Swift, then manually refined for correctness and performance. The transpiled code lives in `Sources/ElkSwift/ELK/` and mirrors the original Java package structure (`org/eclipse/elk/`). A bridge layer in `Sources/ElkSwift/Bridge/` provides the public API and converts between JSON dictionaries and ELK's internal graph model.

## Acknowledgments

This project is a derivative work of the [Eclipse Layout Kernel (ELK)](https://www.eclipse.org/elk/), developed by the [Real-Time and Embedded Systems group](https://www.rtsys.informatik.uni-kiel.de/) at Kiel University. The layered layout algorithm is based on the work of the ELK team and their research on automatic graph drawing.

The unit tests are ported from the ELK Java test suite.

## License

This project is licensed under the [Eclipse Public License 2.0](https://www.eclipse.org/legal/epl-2.0/), the same license as the original [Eclipse ELK](https://www.eclipse.org/elk/) project.

The original ELK source code is Copyright (c) Kiel University and others. See the [LICENSE](LICENSE) file for the full license text.

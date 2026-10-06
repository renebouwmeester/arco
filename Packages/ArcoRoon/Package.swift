// swift-tools-version:5.9
// ArcoRoon — Roon's extension API in Swift: finding a Core on the network (SOOD), the MOO/1 protocol over a WebSocket,
// registering and pairing, and the services Roon expects from every extension (ping, status, pairing).
// No dependencies; usable on its own by any Swift extension.
import PackageDescription

let package = Package(
    name: "ArcoRoon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArcoRoon", targets: ["ArcoRoon"]),
    ],
    targets: [
        .target(name: "ArcoRoon"),
    ]
)

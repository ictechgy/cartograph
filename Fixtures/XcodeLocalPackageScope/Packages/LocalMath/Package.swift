// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalMath",
    products: [.library(name: "ArithmeticProduct", targets: ["ArithmeticCore"])],
    targets: [.target(name: "ArithmeticCore")]
)

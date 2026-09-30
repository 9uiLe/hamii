import Foundation

// Test fixture preparation only. Actual mutation/save remains the production CLI;
// its expected-bytes comparison rejects normalization that differs from its encoder.
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    var bytes = try JSONSerialization.data(withJSONObject: value,
        options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    bytes.append(0x0A)
    try bytes.write(to: url)
}

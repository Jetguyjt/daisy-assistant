import Foundation

enum TestLog { static var failures = 0 }
func fail(_ text: String = "Expected operation to fail", file: StaticString = #filePath, line: UInt = #line) {
    TestLog.failures += 1
    print("  FAIL \(file):\(line): \(text)")
}
func expectTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try !value() { fail("Expected true", file: file, line: line) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try value() { fail("Expected false", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows {
    let first = try a(); let second = try b()
    if first != second { fail("\(first) != \(second)", file: file, line: line) }
}
func expectLess<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(a < b) { fail("\(a) is not less than \(b)", file: file, line: line) }
}
func expectThrows<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try operation(); fail("Expected an error", file: file, line: line) } catch { }
}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a non-nil value"]) }
    return value
}

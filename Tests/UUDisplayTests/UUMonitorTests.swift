import XCTest
@testable import UUDisplay

final class UUMonitorTests: XCTestCase {
    func testConnectionDebouncesMissingSignalAndPublishesDisconnect() {
        var present = false
        var time = Date(timeIntervalSince1970: 100)
        var connects = 0
        var disconnects = 0
        var published: [Bool] = []
        let monitor = UUMonitor(connectionPresent: { present }, now: { time },
                                publishConnection: { published.append($0) })
        monitor.onConnect = { connects += 1 }
        monitor.onDisconnect = { disconnects += 1 }
        monitor.tick()
        present = true
        monitor.tick()
        monitor.tick()
        XCTAssertEqual(connects, 1)
        present = false
        time += 1
        monitor.tick()
        XCTAssertTrue(monitor.connected)
        present = true
        monitor.tick()
        present = false
        time += 1
        monitor.tick()
        XCTAssertTrue(monitor.connected)
        time += 1
        monitor.tick()
        monitor.tick()
        XCTAssertFalse(monitor.connected)
        XCTAssertEqual(disconnects, 1)
        XCTAssertEqual(published.last, false)
        present = true
        monitor.tick()
        XCTAssertEqual(connects, 2)
        XCTAssertEqual(published.last, true)
    }

    func testExistingComputerConfigurationPreservesCustomResolution() throws {
        let data = Data(#"{"name":"MacBook Pro","kind":"computer","width":3024,"height":1964,"hiDPI":true}"#.utf8)
        let config = try JSONDecoder().decode(DeviceConfig.self, from: data)
        let decoded = try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.width, 3024)
        XCTAssertEqual(decoded.height, 1964)
    }
}

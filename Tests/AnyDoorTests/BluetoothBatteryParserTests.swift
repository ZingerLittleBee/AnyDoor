import XCTest
@testable import AnyDoor

final class BluetoothBatteryParserTests: XCTestCase {
    // Mirrors the real `system_profiler SPBluetoothDataType -json` shape: a
    // `device_connected` array of single-key dicts, plus a `device_not_connected`
    // section that must be ignored. The MX Master has no battery field (Logitech
    // HID++), the AirPods carry the L/R/case triple.
    private let systemProfilerJSON = """
    {
      "SPBluetoothDataType": [
        {
          "device_connected": [
            { "EVO80 BT1": { "device_address": "CA:83:69:5F:28:CE", "device_minorType": "Keyboard", "device_batteryLevelMain": "100%" } },
            { "MX Master 3S": { "device_address": "DF:52:7C:AF:65:0C", "device_minorType": "Mouse" } },
            { "AirPods": { "device_address": "10:2F:CA:A6:38:E1", "device_minorType": "Headphones", "device_batteryLevelLeft": "95%", "device_batteryLevelRight": "90%", "device_batteryLevelCase": "80%" } }
          ],
          "device_not_connected": [
            { "Old Keyboard": { "device_address": "00:11:22:33:44:55", "device_minorType": "Keyboard" } }
          ]
        }
      ]
    }
    """

    // Real `pmset -g accps` output: internal battery first (must be skipped),
    // then the two Bluetooth accessories with a single percentage each.
    private let pmsetOutput = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=23265379)\t80%; AC attached; not charging present: true
     -EVO80 BT1 (id=38802332)\t100%;
     -MX Master 3S (id=38802333)\t55%;
    """

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - system_profiler

    func test_parseSystemProfiler_extractsConnectedOnly() {
        let devices = BluetoothBatteryParser.parseSystemProfiler(data(systemProfilerJSON))
        // device_not_connected is ignored.
        XCTAssertEqual(devices.count, 3)

        let keyboard = devices.first { $0.name == "EVO80 BT1" }
        XCTAssertEqual(keyboard?.minorType, "Keyboard")
        XCTAssertEqual(keyboard?.main, 100)
        XCTAssertNil(keyboard?.left)

        let mouse = devices.first { $0.name == "MX Master 3S" }
        XCTAssertEqual(mouse?.minorType, "Mouse")
        XCTAssertFalse(mouse?.hasAnyBattery ?? true)

        let airpods = devices.first { $0.name == "AirPods" }
        XCTAssertEqual(airpods?.left, 95)
        XCTAssertEqual(airpods?.right, 90)
        XCTAssertEqual(airpods?.caseLevel, 80)
        XCTAssertNil(airpods?.main)
    }

    func test_parseSystemProfiler_invalidJSON_returnsEmpty() {
        XCTAssertTrue(BluetoothBatteryParser.parseSystemProfiler(data("not json")).isEmpty)
        XCTAssertTrue(BluetoothBatteryParser.parseSystemProfiler(data("{}")).isEmpty)
    }

    // MARK: - pmset

    func test_parsePmsetAccessories_skipsInternalBattery() {
        let accessories = BluetoothBatteryParser.parsePmsetAccessories(pmsetOutput)
        XCTAssertEqual(accessories, [
            .init(name: "EVO80 BT1", percent: 100),
            .init(name: "MX Master 3S", percent: 55),
        ])
    }

    func test_parsePmsetAccessories_emptyOrGarbage() {
        XCTAssertTrue(BluetoothBatteryParser.parsePmsetAccessories("").isEmpty)
        XCTAssertTrue(BluetoothBatteryParser.parsePmsetAccessories("Now drawing from 'AC Power'").isEmpty)
    }

    // MARK: - merge

    func test_merge_foldsPmsetIntoSystemProfilerGaps() {
        let merged = BluetoothBatteryParser.merge(
            systemProfilerJSON: data(systemProfilerJSON),
            pmsetOutput: pmsetOutput
        )
        // All three connected devices kept; sorted by name (AirPods, EVO80, MX).
        XCTAssertEqual(merged.map(\.name), ["AirPods", "EVO80 BT1", "MX Master 3S"])

        let keyboard = merged.first { $0.name == "EVO80 BT1" }
        XCTAssertEqual(keyboard?.main, 100) // system_profiler value preserved

        // The HID++ mouse had no system_profiler battery → pmset 55% folded in,
        // while keeping the system_profiler minorType.
        let mouse = merged.first { $0.name == "MX Master 3S" }
        XCTAssertEqual(mouse?.main, 55)
        XCTAssertEqual(mouse?.minorType, "Mouse")

        let airpods = merged.first { $0.name == "AirPods" }
        XCTAssertTrue(airpods?.isEarbuds ?? false)
        XCTAssertEqual(airpods?.lowestLevel, 80)
    }

    func test_merge_dropsDevicesWithNoBatteryFromEitherSource() {
        // pmset only knows the keyboard; the mouse has no battery anywhere.
        let pmsetKeyboardOnly = """
        Now drawing from 'AC Power'
         -EVO80 BT1 (id=1)\t100%;
        """
        let merged = BluetoothBatteryParser.merge(
            systemProfilerJSON: data(systemProfilerJSON),
            pmsetOutput: pmsetKeyboardOnly
        )
        // MX Master 3S dropped (no battery from either source); AirPods + keyboard remain.
        XCTAssertEqual(merged.map(\.name), ["AirPods", "EVO80 BT1"])
    }

    func test_merge_addsPmsetOnlyDevices() {
        let pmsetExtra = """
        Now drawing from 'AC Power'
         -EVO80 BT1 (id=1)\t100%;
         -Magic Trackpad (id=2)\t60%;
        """
        let merged = BluetoothBatteryParser.merge(
            systemProfilerJSON: data(systemProfilerJSON),
            pmsetOutput: pmsetExtra
        )
        let trackpad = merged.first { $0.name == "Magic Trackpad" }
        XCTAssertNotNil(trackpad, "pmset-only device should be added")
        XCTAssertEqual(trackpad?.main, 60)
        XCTAssertNil(trackpad?.minorType)
    }

    func test_merge_bothNil_returnsEmpty() {
        XCTAssertTrue(BluetoothBatteryParser.merge(systemProfilerJSON: nil, pmsetOutput: nil).isEmpty)
    }

    func test_merge_systemProfilerOnly() {
        let merged = BluetoothBatteryParser.merge(systemProfilerJSON: data(systemProfilerJSON), pmsetOutput: nil)
        // Without pmset, the HID++ mouse has no battery and is dropped.
        XCTAssertEqual(merged.map(\.name), ["AirPods", "EVO80 BT1"])
    }

    // MARK: - model helpers

    func test_batterySymbolName_buckets() {
        XCTAssertEqual(100.batterySymbolName, "battery.100")
        XCTAssertEqual(70.batterySymbolName, "battery.75")
        XCTAssertEqual(50.batterySymbolName, "battery.50")
        XCTAssertEqual(20.batterySymbolName, "battery.25")
        XCTAssertEqual(5.batterySymbolName, "battery.0")
    }

    func test_device_symbol_byMinorType() {
        func sym(_ t: String?) -> String {
            BluetoothBatteryDevice(id: "x", name: "x", minorType: t, main: 50, left: nil, right: nil, caseLevel: nil).symbol
        }
        XCTAssertEqual(sym("Keyboard"), "keyboard")
        XCTAssertEqual(sym("Mouse"), "computermouse")
        XCTAssertEqual(sym("Magic Trackpad"), "rectangle.and.hand.point.up.left")
        XCTAssertEqual(sym("Headphones"), "airpods")
        XCTAssertEqual(sym("Headset"), "headphones")
        XCTAssertEqual(sym(nil), "dot.radiowaves.left.and.right")
    }
}

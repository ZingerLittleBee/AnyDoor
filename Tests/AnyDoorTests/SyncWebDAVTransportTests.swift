import SwiftData
import XCTest
@testable import AnyDoor

/// In-memory WebDAV server implementing just enough of PROPFIND / GET / PUT /
/// MKCOL for the transport. The HTTP executor is the sanctioned mock boundary
/// (network); everything above it — transport, engine, stores — runs real.
private final class FakeDAVServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directoryExists: Bool
    private let username: String
    private let password: String

    init(username: String = "bee", password: String = "secret", directoryExists: Bool = true) {
        self.username = username
        self.password = password
        self.directoryExists = directoryExists
    }

    var executor: SyncHTTPExecutor {
        { [self] request in handle(request) }
    }

    func file(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[name]
    }

    func setFile(_ name: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        files[name] = data
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!
        let expected = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        guard request.value(forHTTPHeaderField: "Authorization") == expected else {
            return respond(url, 401)
        }
        let name = url.lastPathComponent
        switch request.httpMethod {
        case "PROPFIND":
            guard directoryExists else { return respond(url, 404) }
            var xml = #"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">"#
            xml += "<D:response><D:href>\(url.path)/</D:href></D:response>"
            for fileName in files.keys.sorted() {
                xml += "<D:response><D:href>\(url.path)/\(fileName)</D:href></D:response>"
            }
            xml += "</D:multistatus>"
            return respond(url, 207, Data(xml.utf8))
        case "GET":
            guard let data = files[name] else { return respond(url, 404) }
            return respond(url, 200, data)
        case "PUT":
            guard directoryExists else { return respond(url, 409) }
            files[name] = request.httpBody ?? Data()
            return respond(url, 201)
        case "MKCOL":
            if directoryExists { return respond(url, 405) }
            directoryExists = true
            return respond(url, 201)
        default:
            return respond(url, 405)
        }
    }

    private func respond(_ url: URL, _ status: Int, _ data: Data = Data()) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class SyncWebDAVTransportTests: XCTestCase {

    private let baseURL = URL(string: "https://dav.example.com/AnyDoor")!

    private func makeTransport(
        server: FakeDAVServer,
        username: String = "bee",
        password: String = "secret"
    ) -> SyncWebDAVTransport {
        SyncWebDAVTransport(
            config: SyncWebDAVConfiguration(baseURL: baseURL, username: username, password: password),
            execute: server.executor
        )
    }

    private func encodedDocument(deviceID: String) throws -> Data {
        try SyncStateCodec.encode(SyncDocument(deviceID: deviceID, deviceName: deviceID))
    }

    func testListsAndReadsPeersSkippingForeignAndCorruptFiles() async throws {
        let server = FakeDAVServer()
        server.setFile(SyncStateFile.name(forDeviceID: "peer-1"), try encodedDocument(deviceID: "peer-1"))
        server.setFile(SyncStateFile.name(forDeviceID: "own-id"), try encodedDocument(deviceID: "own-id"))
        server.setFile(SyncStateFile.name(forDeviceID: "corrupt"), Data("not json".utf8))
        server.setFile("notes.txt", Data("user file".utf8))

        let documents = try await makeTransport(server: server)
            .readPeerDocuments(excludingDeviceID: "own-id")

        XCTAssertEqual(documents.map(\.deviceID), ["peer-1"])
    }

    func testWrongCredentialsThrowUnauthorized() async throws {
        let server = FakeDAVServer()
        let transport = makeTransport(server: server, password: "wrong")
        do {
            _ = try await transport.readPeerDocuments(excludingDeviceID: "own-id")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .unauthorized)
        }
    }

    func testMissingDirectoryReadsAsEmpty() async throws {
        let server = FakeDAVServer(directoryExists: false)
        let documents = try await makeTransport(server: server)
            .readPeerDocuments(excludingDeviceID: "own-id")
        XCTAssertTrue(documents.isEmpty)
    }

    func testWriteCreatesCollectionOnDemand() async throws {
        let server = FakeDAVServer(directoryExists: false)
        let data = try encodedDocument(deviceID: "own-id")

        try await makeTransport(server: server).writeOwnDocument(data, deviceID: "own-id")

        XCTAssertEqual(server.file(SyncStateFile.name(forDeviceID: "own-id")), data)
    }

    func testMultistatusParserHandlesNamespacePrefixesAndEncoding() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/AnyDoor/</d:href></d:response>
          <d:response><d:href>/dav/AnyDoor/AnyDoor-SyncState-abc.json</d:href></d:response>
          <d:response>
            <d:href>https://dav.example.com/dav/AnyDoor/AnyDoor-SyncState-x%2Dy.json</d:href>
          </d:response>
        </d:multistatus>
        """
        let names = WebDAVMultistatusParser.fileNames(from: Data(xml.utf8))
        XCTAssertEqual(names, ["AnyDoor-SyncState-abc.json", "AnyDoor-SyncState-x-y.json"])
    }

    // MARK: - Engine over WebDAV

    func testTwoEnginesConvergeOverWebDAV() async throws {
        let server = FakeDAVServer()
        var suiteNames: [String] = []
        defer {
            for name in suiteNames {
                UserDefaults.standard.removePersistentDomain(forName: name)
            }
        }
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncWebDAVTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }

        // The container must outlive the engine or its main context dangles.
        func makeDevice(_ id: String, wall: Int64) throws -> (engine: SyncEngine, container: ModelContainer) {
            let schema = Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self])
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let suiteName = "SyncWebDAVTransportTests-\(id)-\(UUID().uuidString)"
            suiteNames.append(suiteName)
            let engine = SyncEngine(
                config: SyncEngine.Configuration(deviceID: id, deviceName: id),
                context: container.mainContext,
                defaults: UserDefaults(suiteName: suiteName)!,
                transport: makeTransport(server: server),
                stateStore: SyncLocalStateStore(url: stateDir.appendingPathComponent("\(id).json")),
                appPathResolver: { _ in nil },
                reconcileRuntime: {},
                wallNow: { wall }
            )
            return (engine, container)
        }

        let (aEngine, aContainer) = try makeDevice("device-a", wall: 2_000)
        let (bEngine, bContainer) = try makeDevice("device-b", wall: 1_000)
        let a = (engine: aEngine, context: aContainer.mainContext)
        let b = (engine: bEngine, context: bContainer.mainContext)

        let quicklinkID = UUID()
        a.context.insert(Quicklink(
            id: quicklinkID, name: "GitHub", keyword: "gh",
            link: "https://github.com", openWithBundleID: nil,
            keyCode: nil, modifierFlags: nil,
            isVisible: true, displayOrder: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try a.context.save()

        await a.engine.tick()
        await b.engine.tick()

        let rows = try b.context.fetch(FetchDescriptor<Quicklink>())
        XCTAssertEqual(rows.map(\.id), [quicklinkID])
    }
}

import Security
import XCTest
@testable import CloudCodex

final class RemoteCredentialStoreTests: XCTestCase {
    private let saved = Data("test-fixture-existing".utf8)
    private let generated = Data("test-fixture-generated".utf8)

    func testSilentReadRunsOffMainAndRestoresInteraction() async throws {
        let fake = FakeCredentialKeychain(reads: [(errSecSuccess, saved)])
        let value = try await RemoteCredentialStore(keychain: fake).load(allowInteraction: false)
        XCTAssertEqual(value, "test-fixture-existing")
        XCTAssertEqual(fake.interactionChanges, [false, true])
        XCTAssertEqual(fake.addCount, 0)
        XCTAssertFalse(fake.readOnMain)
    }

    func testSilentDenialRestoresPreviouslyDisabledInteractionAndDoesNotCreate() async {
        let fake = FakeCredentialKeychain(reads: [(errSecInteractionNotAllowed, nil)], allowed: false)
        await assertError(.authorizationRequired, store: RemoteCredentialStore(keychain: fake), interactive: false)
        XCTAssertEqual(fake.interactionChanges, [false, false])
        XCTAssertEqual(fake.addCount, 0)
    }

    func testExplicitCancellationAndDenialNeverReplaceCredential() async {
        for (status, error) in [(errSecUserCanceled, RemoteCredentialError.cancelled),
                                (errSecAuthFailed, .authorizationRequired)] {
            let fake = FakeCredentialKeychain(reads: [(status, nil)])
            await assertError(error, store: RemoteCredentialStore(keychain: fake), interactive: true)
            XCTAssertEqual(fake.interactionChanges, [])
            XCTAssertEqual(fake.addCount, 0)
        }
    }

    func testSilentMissingCredentialDoesNotCreateOrAskForPermission() async {
        let fake = FakeCredentialKeychain(reads: [(errSecItemNotFound, nil)])
        await assertError(.authorizationRequired, store: RemoteCredentialStore(keychain: fake), interactive: false)
        XCTAssertEqual(fake.addCount, 0)
    }

    func testOnlyExplicitNotFoundCreatesCredential() async throws {
        let fake = FakeCredentialKeychain(reads: [(errSecItemNotFound, nil)])
        let generated = generated
        let store = RemoteCredentialStore(keychain: fake, generate: { generated })
        let value = try await store.load(allowInteraction: true)
        XCTAssertEqual(value, "test-fixture-generated")
        XCTAssertEqual(fake.addCount, 1)
        XCTAssertEqual(fake.interactionChanges, [])
    }

    func testCreateRaceReadsWinnerInsteadOfReplacingIt() async throws {
        let fake = FakeCredentialKeychain(reads: [(errSecItemNotFound, nil), (errSecSuccess, saved)],
                                         addStatus: errSecDuplicateItem)
        let generated = generated
        let value = try await RemoteCredentialStore(keychain: fake, generate: { generated }).load(allowInteraction: true)
        XCTAssertEqual(value, "test-fixture-existing")
        XCTAssertEqual(fake.readCount, 2)
        XCTAssertEqual(fake.addCount, 1)
    }

    func testInvalidOrUnavailableCredentialIsNotTreatedAsMissing() async {
        for (status, data, error) in [(errSecSuccess, Data(), RemoteCredentialError.invalidCredential),
                                      (errSecNotAvailable, nil, .keychain(errSecNotAvailable))] {
            let fake = FakeCredentialKeychain(reads: [(status, data)])
            await assertError(error, store: RemoteCredentialStore(keychain: fake), interactive: true)
            XCTAssertEqual(fake.addCount, 0)
        }
    }

    func testFailureToSuppressUIFailsClosedBeforeReading() async {
        let fake = FakeCredentialKeychain(reads: [(errSecSuccess, saved)], setStatus: errSecNotAvailable)
        await assertError(.keychain(errSecNotAvailable), store: RemoteCredentialStore(keychain: fake), interactive: false)
        XCTAssertEqual(fake.readCount, 0)
        XCTAssertEqual(fake.addCount, 0)
    }

    private func assertError(_ expected: RemoteCredentialError, store: RemoteCredentialStore, interactive: Bool) async {
        do {
            _ = try await store.load(allowInteraction: interactive)
            XCTFail("Expected a credential error")
        } catch { XCTAssertEqual(error as? RemoteCredentialError, expected) }
    }
}

// Only synthetic fixture data; none of these tests calls the system Keychain.
private final class FakeCredentialKeychain: RemoteCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [(OSStatus, Data?)]
    private var allowed: Bool
    private let addStatus: OSStatus
    private let setStatus: OSStatus
    private var changes: [Bool] = []
    private var readCalls = 0
    private var addCalls = 0
    private var mainThreadRead = false

    var interactionChanges: [Bool] { lock.withLock { changes } }
    var readCount: Int { lock.withLock { readCalls } }
    var addCount: Int { lock.withLock { addCalls } }
    var readOnMain: Bool { lock.withLock { mainThreadRead } }

    init(reads: [(OSStatus, Data?)], allowed: Bool = true,
         addStatus: OSStatus = errSecSuccess, setStatus: OSStatus = errSecSuccess) {
        self.reads = reads
        self.allowed = allowed
        self.addStatus = addStatus
        self.setStatus = setStatus
    }

    func interactionAllowed() -> (OSStatus, Bool) { lock.withLock { (errSecSuccess, allowed) } }
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        lock.withLock {
            changes.append(allowed)
            if setStatus == errSecSuccess { self.allowed = allowed }
            return setStatus
        }
    }
    func read() -> (OSStatus, Data?) {
        lock.withLock {
            readCalls += 1
            mainThreadRead = mainThreadRead || Thread.isMainThread
            return reads.isEmpty ? (errSecNotAvailable, nil) : reads.removeFirst()
        }
    }
    func add(_ data: Data) -> OSStatus { lock.withLock { addCalls += 1; return addStatus } }
}

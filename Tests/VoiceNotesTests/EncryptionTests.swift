import CryptoKit
import XCTest
@testable import VoiceNotes

final class CryptoTests: XCTestCase {
    func testSealAndOpen() throws {
        let (vault, key) = try Vault.create(passphrase: "correct horse", iterations: 1000)
        let sealed = try NoteCrypto.seal(Data("secret".utf8), key: key)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("secret"))
        XCTAssertEqual(try NoteCrypto.open(sealed, key: key), Data("secret".utf8))
        XCTAssertNotNil(vault.key(for: "correct horse"))
        XCTAssertNil(vault.key(for: "wrong horse"))
    }

    func testTamperingIsDetected() throws {
        let (_, key) = try Vault.create(passphrase: "correct horse", iterations: 1000)
        var sealed = try NoteCrypto.seal(Data("secret".utf8), key: key)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try NoteCrypto.open(sealed, key: key))
    }
}

@MainActor
final class EncryptedFolderTests: XCTestCase {
    private var folder: URL!
    private let passphrase = "correct horse battery"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        NoteFolder.keyStore = MemoryKeyStore()
    }

    override func tearDown() async throws {
        NoteFolder.keyStore = KeychainKeyStore()
    }

    private func makeStore(_ url: URL? = nil) -> NoteStore {
        NoteStore(folderURL: url ?? folder, legacyFileURL: nil, startTimer: false)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A second Mac: same folder, but no key in its keychain.
    private func otherMac() -> NoteStore {
        NoteFolder.keyStore = MemoryKeyStore()
        return makeStore()
    }

    func testEnablingEncryptsEveryNoteAndLeavesNoPlainText() throws {
        let store = makeStore()
        store.add(Note(title: "Mom's Wi-Fi", body: "Password is sunflower42", tag: "personal"))
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)

        let names = try files()
        XCTAssertTrue(names.contains(Vault.fileName))
        XCTAssertEqual(names.filter { $0.hasSuffix(".vnote") }.count, 1)
        XCTAssertTrue(names.filter { $0.hasSuffix(".json") }.isEmpty, "no plain copies left")
        for name in names {
            let text = String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
            XCTAssertFalse(text.contains("sunflower42"), name)
        }
        XCTAssertEqual(store.notes.map(\.title), ["Mom's Wi-Fi"], "still readable here")

        store.add(Note(title: "New", body: "added after", tag: "other"))
        XCTAssertTrue(try files().filter { $0.hasSuffix(".json") }.isEmpty, "new notes are encrypted too")
    }

    func testOtherMacIsLockedUntilTheRightPassphrase() throws {
        let store = makeStore()
        store.add(Note(title: "Secret", body: "", tag: "other"))
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)

        let other = otherMac()
        XCTAssertTrue(other.isLocked)
        XCTAssertTrue(other.notes.isEmpty)
        XCTAssertEqual(other.lockedCount, 1)
        XCTAssertFalse(other.unlock(passphrase: "nope"))
        XCTAssertTrue(other.unlock(passphrase: passphrase))
        XCTAssertEqual(other.notes.map(\.title), ["Secret"])
    }

    func testLockedMacNeverWritesPlainTextIntoTheFolder() throws {
        let store = makeStore()
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)
        let other = otherMac()
        other.add(Note(title: "Typed while locked", body: "", tag: "other"))
        XCTAssertNotNil(other.saveError)
        XCTAssertTrue(try files().filter { $0.hasSuffix(".json") }.isEmpty)

        XCTAssertTrue(other.unlock(passphrase: passphrase))
        XCTAssertNil(other.saveError, "kept in memory and saved once unlocked")
        XCTAssertEqual(try files().filter { $0.hasSuffix(".vnote") }.count, 1)
    }

    func testTurningOffDecryptsEverything() throws {
        let store = makeStore()
        store.add(Note(title: "A", body: "", tag: "other"))
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)
        XCTAssertThrowsError(try store.disableEncryption(passphrase: "wrong"))
        try store.disableEncryption(passphrase: passphrase)

        let names = try files()
        let marker = try JSONDecoder().decode(Vault.self, from: Data(contentsOf: folder.appendingPathComponent(Vault.fileName)))
        XCTAssertTrue(marker.isDisabled, "an authenticated 'turned off' marker replaces the vault")
        XCTAssertFalse(store.isEncrypted)
        XCTAssertTrue(names.filter { $0.hasSuffix(".vnote") }.isEmpty)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(makeStore().notes.map(\.title), ["A"])
    }

    func testOtherMacSeesEncryptionTurnedOnWhileRunning() throws {
        let store = makeStore()
        store.add(Note(title: "A", body: "", tag: "other"))
        let otherKeys = MemoryKeyStore()
        NoteFolder.keyStore = otherKeys
        let other = makeStore()
        XCTAssertFalse(other.isLocked)

        NoteFolder.keyStore = MemoryKeyStore()
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)
        NoteFolder.keyStore = otherKeys
        other.reload()
        XCTAssertTrue(other.isLocked)
        XCTAssertEqual(other.notes.map(\.title), ["A"], "what it already had stays visible")
    }

    func testEncryptedFolderNeedsItsPassphraseToSwitchTo() throws {
        let shared = folder.appendingPathComponent("shared")
        let otherMacStore = makeStore(shared)
        otherMacStore.add(Note(title: "From other Mac", body: "", tag: "other"))
        try otherMacStore.enableEncryption(passphrase: passphrase, iterations: 1000)

        NoteFolder.keyStore = MemoryKeyStore()
        let local = makeStore(folder.appendingPathComponent("local"))
        local.add(Note(title: "Local", body: "", tag: "other"))
        XCTAssertThrowsError(try local.changeFolder(to: shared)) {
            XCTAssertEqual($0 as? NoteCryptoError, .needsPassphrase)
        }
        XCTAssertThrowsError(try local.changeFolder(to: shared, passphrase: "wrong"))
        try local.changeFolder(to: shared, passphrase: passphrase)
        XCTAssertEqual(Set(local.notes.map(\.title)), ["Local", "From other Mac"])
        let names = try FileManager.default.contentsOfDirectory(atPath: shared.path)
        XCTAssertTrue(names.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    func testMovingEncryptedNotesKeepsThemEncrypted() throws {
        let store = makeStore()
        store.add(Note(title: "Private", body: "", tag: "other"))
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)
        let destination = folder.appendingPathComponent("moved")
        try store.changeFolder(to: destination)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertTrue(names.contains(Vault.fileName))
        XCTAssertTrue(names.filter { $0.hasSuffix(".json") }.isEmpty)
        XCTAssertEqual(store.notes.map(\.title), ["Private"])
    }

    // MARK: Downgrade protection

    func testDeletedVaultFileDoesNotTurnOffEncryption() throws {
        let store = makeStore()
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(Vault.fileName))

        let restarted = makeStore() // e.g. after a relaunch, with the vault file gone or evicted
        XCTAssertTrue(restarted.isEncrypted)
        restarted.add(Note(title: "Still secret", body: "sunflower42", tag: "other"))
        XCTAssertTrue(try files().filter { $0.hasSuffix(".json") }.isEmpty, "no plain text written")
    }

    func testForgedTurnOffMarkerIsIgnored() throws {
        let store = makeStore()
        try store.enableEncryption(passphrase: passphrase, iterations: 1000)
        var forged = try JSONDecoder().decode(Vault.self, from: Data(contentsOf: folder.appendingPathComponent(Vault.fileName)))
        forged.disabled = true // no valid proof: whoever wrote this doesn't have the key
        try JSONEncoder().encode(forged).write(to: folder.appendingPathComponent(Vault.fileName))

        store.reload()
        XCTAssertTrue(store.isEncrypted)
        XCTAssertFalse(store.isLocked)
        store.add(Note(title: "Still secret", body: "", tag: "other"))
        XCTAssertTrue(try files().filter { $0.hasSuffix(".json") }.isEmpty)
    }

    func testGenuineTurnOffOnAnotherMacIsFollowed() throws {
        let macA = makeStore()
        macA.add(Note(title: "A", body: "", tag: "other"))
        try macA.enableEncryption(passphrase: passphrase, iterations: 1000)
        let macB = makeStore() // same key store: B is unlocked
        XCTAssertFalse(macB.isLocked)

        try macA.disableEncryption(passphrase: passphrase)
        macB.reload()
        XCTAssertFalse(macB.isEncrypted)
        macB.add(Note(title: "B", body: "", tag: "other"))
        XCTAssertEqual(try files().filter { $0.hasSuffix(".json") }.count, 2)
    }

    func testLockedMacConfirmsTurnOffWithThePassphrase() throws {
        let macA = makeStore()
        macA.add(Note(title: "A", body: "", tag: "other"))
        try macA.enableEncryption(passphrase: passphrase, iterations: 1000)
        let macB = otherMac() // never unlocked
        XCTAssertTrue(macB.isLocked)

        NoteFolder.keyStore = MemoryKeyStore()
        try macA.disableEncryption(passphrase: passphrase)
        macB.reload()
        XCTAssertTrue(macB.isLocked, "can't verify the turn-off without the key")
        XCTAssertTrue(macB.unlock(passphrase: passphrase))
        XCTAssertFalse(macB.isEncrypted)
        XCTAssertEqual(macB.notes.map(\.title), ["A"])
    }
}

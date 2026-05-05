import XCTest
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behaviour tests for MarkdownPanel's edit-mode buffer state machine.
/// Covers save round-trip, encoding preservation, session restore, and
/// the quit-flush path that AppDelegate relies on at termination.
final class MarkdownPanelEditModeTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testFlushSaveWritesBufferToDisk() throws {
        let url = temporaryRoot.appendingPathComponent("note.md")
        try "# original\n".write(to: url, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        XCTAssertEqual(panel.content, "# original\n")
        XCTAssertFalse(panel.isDirty)

        panel.updateBuffer("# edited\n")
        XCTAssertTrue(panel.isDirty)
        try panel.flushSave()
        XCTAssertFalse(panel.isDirty)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "# edited\n")
        XCTAssertEqual(panel.content, "# edited\n")
    }

    @MainActor
    func testFlushSaveIsNoOpWhenClean() throws {
        let url = temporaryRoot.appendingPathComponent("clean.md")
        try "stable\n".write(to: url, atomically: true, encoding: .utf8)
        let originalAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalDate = originalAttrs[.modificationDate] as? Date
        XCTAssertNotNil(originalDate)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        // Sleep long enough that any save would change the mtime.
        Thread.sleep(forTimeInterval: 0.05)
        try panel.flushSave()

        let afterAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(afterAttrs[.modificationDate] as? Date, originalDate)
    }

    @MainActor
    func testUpdateBufferToContentClearsDirty() throws {
        let url = temporaryRoot.appendingPathComponent("idempotent.md")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)

        panel.updateBuffer("y\n")
        XCTAssertTrue(panel.isDirty)
        panel.updateBuffer("x\n")
        XCTAssertFalse(panel.isDirty)
    }

    @MainActor
    func testDiscardEditsBumpsRevertToken() throws {
        let url = temporaryRoot.appendingPathComponent("discard.md")
        try "original\n".write(to: url, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        let beforeToken = panel.bufferRevertToken

        panel.updateBuffer("scratch\n")
        XCTAssertTrue(panel.isDirty)
        panel.discardEdits()

        XCTAssertFalse(panel.isDirty)
        XCTAssertNotEqual(panel.bufferRevertToken, beforeToken)
    }

    @MainActor
    func testFocusBumpsTokenOnlyInEditMode() throws {
        let url = temporaryRoot.appendingPathComponent("focus.md")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        let initialToken = panel.focusRequestToken

        panel.focus()
        XCTAssertEqual(panel.focusRequestToken, initialToken, "preview mode focus should not bump")

        panel.editMode = true
        panel.focus()
        XCTAssertNotEqual(panel.focusRequestToken, initialToken, "edit mode focus should bump")
    }

    @MainActor
    func testEncodingPreservationLatin1RoundTrip() throws {
        let url = temporaryRoot.appendingPathComponent("latin1.md")
        // Byte 0xE9 is "é" in Latin-1 but invalid as a standalone UTF-8 sequence.
        let latin1Bytes = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0xE9, 0x0A]) // hello é\n
        try latin1Bytes.write(to: url)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        XCTAssertFalse(panel.isFileUnavailable)
        XCTAssertTrue(panel.content.hasPrefix("hello"), "expected Latin-1 fallback decode, got \(panel.content)")

        // Append a character that's representable in both encodings.
        panel.updateBuffer(panel.content + "!\n")
        try panel.flushSave()

        let bytesAfter = try Data(contentsOf: url)
        // The save path should preserve the original Latin-1 encoding so the
        // existing 0xE9 byte round-trips intact rather than being silently
        // promoted to UTF-8 multi-byte form.
        XCTAssertTrue(bytesAfter.contains(0xE9), "Latin-1 byte should round-trip without UTF-8 promotion")
    }

    @MainActor
    func testSessionRoundTripPreservesEditMode() throws {
        let url = temporaryRoot.appendingPathComponent("persistent.md")
        try "# persisted\n".write(to: url, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(inPane: paneId, filePath: url.path, focus: true)
        )
        panel.editMode = true

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.markdownPanel(for: restoredPanelId))

        XCTAssertEqual(restoredPanel.filePath, url.path)
        XCTAssertTrue(restoredPanel.editMode)
    }

    @MainActor
    func testQuitFlushWritesPendingMarkdownEdits() throws {
        let url = temporaryRoot.appendingPathComponent("quit-flush.md")
        try "before\n".write(to: url, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(inPane: paneId, filePath: url.path, focus: false)
        )
        panel.updateBuffer("after\n")
        XCTAssertTrue(panel.isDirty)

        // Simulate the AppDelegate quit-flush rail.
        workspace.flushDirtyMarkdownBuffers()

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "after\n")
        XCTAssertFalse(panel.isDirty)
    }

    @MainActor
    func testFlushSaveOnUnboundPanelIsNoOp() throws {
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: nil)
        panel.updateBuffer("nowhere\n")
        // Buffer is held but no destination. flushSave must not throw.
        XCTAssertNoThrow(try panel.flushSave())
    }
}

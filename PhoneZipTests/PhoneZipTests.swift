import ImageIO
import UniformTypeIdentifiers
import XCTest
import zlib
@testable import PhoneZip

/// The paths that decide whether an original may be deleted, and the failures
/// that are hard to produce by hand (a damaged zip, a bad copy on the drive).
final class PhoneZipTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: What may be deleted

    func testPhotoIsDeletableOnlyWhenEveryFileWasExportedAndChecked() {
        var manifest = ExportManifest()
        manifest.expectedFiles = ["live": 2, "split": 2, "plain": 1, "shrunk": 1, "skipped": 1]
        manifest.assetPaths = [
            "live": ["a.HEIC", "a.MOV"],
            // The export stopped between two parts: the still got out, the video never did.
            "split": ["b.HEIC"],
            "plain": ["c.JPG"],
            "shrunk": ["d.HEIC"],
            "skipped": ["e.JPG"],
        ]
        manifest.shrunkAssets = ["shrunk"]
        manifest.incompleteAssets = ["skipped"]
        let all: Set<String> = ["a.HEIC", "a.MOV", "b.HEIC", "c.JPG", "d.HEIC", "e.JPG"]

        XCTAssertEqual(Set(DriveTransfer.deletableAssets(manifest, verified: all)), ["live", "plain"])
        // One of a photo's files failed its check on the drive.
        XCTAssertEqual(Set(DriveTransfer.deletableAssets(manifest, verified: all.subtracting(["a.MOV"]))), ["plain"])
        XCTAssertTrue(DriveTransfer.deletableAssets(manifest, verified: []).isEmpty)
    }

    func testPhotoWithNoExpectedCountIsNeverDeletable() {
        var manifest = ExportManifest()
        manifest.assetPaths = ["x": ["x.JPG"]]
        XCTAssertTrue(DriveTransfer.deletableAssets(manifest, verified: ["x.JPG"]).isEmpty)
    }

    func testMergingPartsKeepsAPhotoSplitAcrossThemWhole() {
        var whole = ExportManifest()
        whole.expectedFiles = ["live": 2]
        var part1 = ExportManifest(), part2 = ExportManifest()
        part1.assetPaths = ["live": ["a.HEIC"]]
        part2.assetPaths = ["live": ["a.MOV"]]

        whole.merge(part1)
        XCTAssertTrue(DriveTransfer.deletableAssets(whole, verified: ["a.HEIC"]).isEmpty)
        whole.merge(part2)
        XCTAssertEqual(DriveTransfer.deletableAssets(whole, verified: ["a.HEIC", "a.MOV"]), ["live"])
    }

    func testDocumentExportedTwiceIsDeletedOnce() {
        var manifest = ExportManifest()
        let url = URL(fileURLWithPath: "/docs/a.txt")
        manifest.files = ["Documents/One/a.txt": url, "Documents/Two/a.txt": url]
        XCTAssertEqual(DriveTransfer.deletableFiles(manifest, verified: Set(manifest.files.keys)), [url])
    }

    func testChangedSinceExport() {
        let then = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(DriveTransfer.isNewer(then, than: then))
        XCTAssertTrue(DriveTransfer.isNewer(then.addingTimeInterval(5), than: then))
        XCTAssertFalse(DriveTransfer.isNewer(then, than: nil))
        XCTAssertFalse(DriveTransfer.isNewer(nil, than: then))
    }

    func testDeletingKeepsChangedDocumentsAndOnesWhoseCopyIsGone() async throws {
        let source = temp.appendingPathComponent("source"), drive = temp.appendingPathComponent("drive")
        for dir in [source, drive] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        var manifest = ExportManifest()
        for name in ["same.txt", "edited.txt", "nocopy.txt"] {
            let file = source.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            manifest.files[name] = file
            manifest.fileDates[name] = FolderSource.modificationDate(file)
            if name != "nocopy.txt" { try Data(name.utf8).write(to: drive.appendingPathComponent(name)) }
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: source.appendingPathComponent("edited.txt").path)

        let report = await DriveTransfer.deleteOriginals(manifest, verified: Set(manifest.files.keys), on: drive)

        XCTAssertEqual(report.filesDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("same.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("edited.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("nocopy.txt").path))
        XCTAssertEqual(report.problems.count, 2, "\(report.problems)")
    }

    // MARK: Names a drive can store

    func testNamesAreMadeSafeForExFATDrives() {
        XCTAssertEqual(ZipPathAllocator.portable("Documents/Notes: 1/What? *draft*.txt"), "Documents/Notes_ 1/What_ _draft_.txt")
        XCTAssertEqual(ZipPathAllocator.portable("a/b<c>|\"d\"\\e"), "a/b_c___d__e")
        XCTAssertEqual(ZipPathAllocator.portable("Folder ./file."), "Folder__/file_")
        XCTAssertEqual(ZipPathAllocator.portable("Photo Library/Photos/2024/2024-05/IMG_0001.HEIC"),
                       "Photo Library/Photos/2024/2024-05/IMG_0001.HEIC")
        XCTAssertEqual(ZipPathAllocator.portable("Café/naïve — résumé.pdf"), "Café/naïve — résumé.pdf")
    }

    func testNamesThatBecomeEqualStayApart() {
        var paths = ZipPathAllocator()
        XCTAssertEqual(paths.unique("Documents/a?.txt"), "Documents/a_.txt")
        XCTAssertEqual(paths.unique("Documents/a*.txt"), "Documents/a_ (2).txt")
    }

    // MARK: A damaged zip, a bad copy

    func testCheckingAZipFindsADamagedFile() throws {
        let zip = temp.appendingPathComponent("damaged.zip")
        try writeZip([("good.txt", Data("all fine".utf8)), ("bad.txt", Data("about to be damaged".utf8))],
                     to: zip, damaging: "bad.txt")
        XCTAssertEqual(try DriveTransfer.verifyZip(zip) { _, _, _ in }, ["good.txt"])
    }

    func testBadCopyIsNotLeftOnTheDriveAndTheZipIsKept() throws {
        let zip = temp.appendingPathComponent("damaged.zip"), drive = temp.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try writeZip([("Photos/good.txt", Data("all fine".utf8)), ("Photos/bad.txt", Data("about to be damaged".utf8))],
                     to: zip, damaging: "Photos/bad.txt")

        let copy = try DriveTransfer.copy(zip: zip, into: drive) { _, _, _ in }

        XCTAssertEqual(copy.verified, ["Photos/good.txt"])
        XCTAssertEqual(copy.failed.count, 1)
        XCTAssertFalse(copy.zipRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertEqual(try Data(contentsOf: drive.appendingPathComponent("Photos/good.txt")), Data("all fine".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.appendingPathComponent("Photos/bad.txt").path))
    }

    func testCleanCopyIsCheckedAndTheZipRemoved() throws {
        let zip = temp.appendingPathComponent("clean.zip"), drive = temp.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try writeZip([("a.txt", Data("one".utf8)), ("sub/b.txt", Data("two".utf8))], to: zip)

        let copy = try DriveTransfer.copy(zip: zip, into: drive) { _, _, _ in }

        XCTAssertEqual(copy.verified, ["a.txt", "sub/b.txt"])
        XCTAssertTrue(copy.failed.isEmpty)
        XCTAssertTrue(copy.zipRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
    }

    func testFileAlreadyOnTheDriveIsNeitherReplacedNorCounted() throws {
        let zip = temp.appendingPathComponent("clash.zip"), drive = temp.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("was here first".utf8).write(to: drive.appendingPathComponent("a.txt"))
        try writeZip([("a.txt", Data("from the phone".utf8))], to: zip)

        let copy = try DriveTransfer.copy(zip: zip, into: drive) { _, _, _ in }

        XCTAssertTrue(copy.verified.isEmpty)
        XCTAssertEqual(copy.failed.count, 1)
        XCTAssertEqual(try Data(contentsOf: drive.appendingPathComponent("a.txt")), Data("was here first".utf8))
    }

    // MARK: Listing documents

    func testFolderListingSkipsHiddenFilesAndKeepsSubfolders() throws {
        let root = temp.appendingPathComponent("Work")
        for dir in ["sub/.cache", "other", "last"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        // A hidden file used to make the walker skip a whole neighbouring folder.
        for name in ["a.txt", "sub/b.txt", ".DS_Store", "sub/.cache/junk", "sub/.hidden", "other/c.txt",
                     "other/.DS_Store", "last/d.txt", "what?.txt"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        var paths = ZipPathAllocator()
        let items = FolderSource.items(in: [PickedFolder(url: root)], paths: &paths)

        let names = Set(items.map { ($0.pathInZip as NSString).lastPathComponent })
        XCTAssertEqual(names, ["a.txt", "b.txt", "c.txt", "d.txt", "what_.txt"])
        XCTAssertTrue(items.contains { $0.pathInZip.hasSuffix("Work/sub/b.txt") })
        XCTAssertTrue(items.allSatisfy { $0.pathInZip.hasPrefix("Documents/") })
    }

    func testPhoneZipsOwnFolderIsNeverExported() throws {
        let marker = Exporter.documents.appendingPathComponent("test-marker-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        var paths = ZipPathAllocator()
        XCTAssertTrue(FolderSource.items(in: [PickedFolder(url: Exporter.documents)], paths: &paths).isEmpty)
    }

    func testDeletingRemovesEmptiedSubfoldersButNotThePickedFolder() async throws {
        let root = temp.appendingPathComponent("Picked"), drive = temp.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("kept"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        var manifest = ExportManifest()
        manifest.fileRoots = [root]
        let file = root.appendingPathComponent("sub/deeper/x.txt")
        try Data("x".utf8).write(to: file)
        try Data("stays".utf8).write(to: root.appendingPathComponent("kept/not-exported.txt"))
        try Data("x".utf8).write(to: drive.appendingPathComponent("x.txt"))
        manifest.files["x.txt"] = file

        let report = await DriveTransfer.deleteOriginals(manifest, verified: ["x.txt"], on: drive)

        XCTAssertEqual(report.filesDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sub").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("kept/not-exported.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testNothingIsDeletedWhenTheDriveIsGone() async throws {
        let file = temp.appendingPathComponent("doc.txt")
        try Data("doc".utf8).write(to: file)
        var manifest = ExportManifest()
        manifest.files["doc.txt"] = file

        let report = await DriveTransfer.deleteOriginals(manifest, verified: ["doc.txt"],
                                                         on: temp.appendingPathComponent("unplugged"))

        XCTAssertEqual(report.filesDeleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(report.problems.count, 1)
    }

    // MARK: The drive going away, or the user cancelling

    func testCopyStopsWhenTheDriveIsNotThere() throws {
        let zip = temp.appendingPathComponent("a.zip")
        try writeZip([("a.txt", Data("one".utf8))], to: zip)
        XCTAssertThrowsError(try DriveTransfer.copy(zip: zip, into: temp.appendingPathComponent("unplugged")) { _, _, _ in }) {
            XCTAssertTrue($0 is DriveTransfer.DriveGone)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    }

    func testCancelledCopyLeavesNothingHalfDoneOnTheDrive() async throws {
        let zip = temp.appendingPathComponent("a.zip"), drive = temp.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("an earlier part".utf8).write(to: drive.appendingPathComponent("earlier.txt"))
        try writeZip([("p/a.txt", Data("one".utf8)), ("p/b.txt", Data("two".utf8)), ("p/c.txt", Data("three".utf8))], to: zip)

        let task = Task.detached {
            try DriveTransfer.copy(zip: zip, into: drive) { done, _, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("the copy should have been cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // Only what this zip added is taken away; an earlier part stays.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drive.path), ["earlier.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    }

    // MARK: Save Space

    func testAnimatedImageIsNotFlattenedToAStill() throws {
        let gif = temp.appendingPathComponent("animated.gif")
        try writeImage(frames: 3, type: .gif, to: gif)
        XCTAssertThrowsError(try Shrinker.shrinkPhoto(gif, to: temp.appendingPathComponent("out.HEIC")))
    }

    func testStillPhotoIsReEncodedAsHEIC() throws {
        let png = temp.appendingPathComponent("still.png"), heic = temp.appendingPathComponent("still.HEIC")
        try writeImage(frames: 1, type: .png, to: png)
        do {
            try Shrinker.shrinkPhoto(png, to: heic)
        } catch let error as Shrinker.Failed where error.reason.contains("HEIC") {
            throw XCTSkip("This simulator can't encode HEIC: \(error.reason)")
        }
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(heic as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.heic.identifier)
    }

    // MARK: Helpers

    /// A solid-color image with the given number of frames.
    private func writeImage(frames: Int, type: UTType, to url: URL) throws {
        let out = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: CGFloat(frame) / 3, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(out, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(out))
    }

    /// Writes a plain (stored) zip by hand, so a byte of one file can be
    /// flipped afterwards: the checksum in the zip then no longer matches.
    private func writeZip(_ files: [(path: String, data: Data)], to url: URL, damaging damaged: String? = nil) throws {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var zip = Data(), directory = Data()
        var flip: Int?
        for file in files {
            let name = Data(file.path.utf8)
            let crc = file.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))) }
            let size = UInt32(file.data.count)
            // version, flags (UTF-8 names), stored, time, date, crc, sizes, name length, extra length
            let fields = le(UInt16(20)) + le(UInt16(0x0800)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0x5821))
                + le(crc) + le(size) + le(size) + le(UInt16(name.count)) + le(UInt16(0))
            let offset = UInt32(zip.count)
            zip += le(UInt32(0x04034b50)) + fields + name
            if file.path == damaged { flip = zip.count }
            zip += file.data
            directory += le(UInt32(0x02014b50)) + le(UInt16(20)) + fields
                + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(offset) + name
        }
        let start = UInt32(zip.count)
        zip += directory
        zip += le(UInt32(0x06054b50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(files.count)) + le(UInt16(files.count))
            + le(UInt32(directory.count)) + le(start) + le(UInt16(0))
        if let flip { zip[flip] ^= 0xFF }
        try zip.write(to: url)
    }

    func testDeviceNameMatchesTheDevice() {
        // Shown in every message about where the originals stay.
        XCTAssertTrue(["iPhone", "iPad", "iPod touch", "Mac"].contains(Device.name), Device.name)
    }
}

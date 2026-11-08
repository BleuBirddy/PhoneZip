import Photos
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var exporter = Exporter()
    @Environment(\.scenePhase) private var scenePhase

    @State private var photoStatus = PhotoSource.status
    @State private var counts = (photos: 0, videos: 0)
    @State private var includePhotos = true
    @State private var includeVideos = true
    @State private var folders: [PickedFolder] = []
    @State private var exports: [URL] = Exporter.existingExports()
    /// The drive picked last time, when it is plugged in.
    @State private var drive: PickedFolder?

    /// One Files picker serves both jobs; SwiftUI only honors one
    /// fileImporter per view.
    private enum PickerJob { case sourceFolders, drive }
    @State private var pickerJob = PickerJob.sourceFolders
    @State private var showingPicker = false
    @State private var pickerError: String?
    @State private var confirmingDelete = false

    /// Save Space: re-encode photos (and videos, unless kept) to shrink the
    /// export. Lossy, so starting one always asks first.
    @State private var saveSpace = false
    @State private var keepOriginalVideos = false
    private enum ExportJob { case zipOnly, drive(PickedFolder) }
    @State private var pendingExport: ExportJob?

    private var canSeePhotos: Bool { photoStatus == .authorized || photoStatus == .limited }
    private var exportsPhotoLibrary: Bool {
        canSeePhotos && (includePhotos && counts.photos > 0 || includeVideos && counts.videos > 0)
    }
    /// Shrinking applies only when something would actually be re-encoded.
    private var saver: SpaceSaver? {
        guard saveSpace, exportsPhotoLibrary else { return nil }
        if keepOriginalVideos && !includePhotos { return nil }
        return SpaceSaver(keepOriginalVideos: keepOriginalVideos || !includeVideos)
    }
    private var hasSomethingToExport: Bool {
        (canSeePhotos && (includePhotos && counts.photos > 0 || includeVideos && counts.videos > 0)) || !folders.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                switch exporter.state {
                case .preparing, .running, .moving, .deleting:
                    progressSection
                case .finished(let result):
                    finishedSection(result)
                case .moved(let summary):
                    movedSection(summary)
                case .cleaned(let report):
                    cleanedSection(report)
                case .idle, .failed:
                    if case .failed(let message) = exporter.state {
                        Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                    photosSection
                    foldersSection
                    saveSpaceSection
                    driveSection
                    Section {
                        Button {
                            requestExport(.zipOnly)
                        } label: {
                            Label("Create Zip Only", systemImage: "archivebox").frame(maxWidth: .infinity)
                        }
                        .disabled(!hasSomethingToExport)
                    } footer: {
                        Text("Keeps one zip on this iPhone, so it needs free space about the size of everything you export.")
                    }
                }
                if !exports.isEmpty && !exporter.isBusy {
                    exportsSection
                }
            }
            .navigationTitle("PhoneZip")
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder],
                          allowsMultipleSelection: pickerJob == .sourceFolders) { result in
                switch result {
                case .success(let urls): picked(urls)
                case .failure(let error): pickerError = error.localizedDescription
                }
            }
            .alert("Couldn't use that folder", isPresented: isPresent($pickerError)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pickerError ?? "")
            }
            .alert("Couldn't copy to the drive", isPresented: isPresent($exporter.notice)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exporter.notice ?? "")
            }
            .alert("Export at Lower Quality?", isPresented: isPresent($pendingExport), presenting: pendingExport) { job in
                Button("Yes, Lower the Quality", role: .destructive) { run(job) }
                // Return on a hardware keyboard presses this one, never Yes.
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { _ in
                Text(lowQualityWarning)
            }
            .alert("Delete from this iPhone?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    if case .moved(let summary) = exporter.state {
                        exporter.deleteOriginals(summary)
                    }
                }
                // Return on a hardware keyboard presses this one, never Delete.
                Button("Keep Them", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(deleteWarning)
            }
        }
        .task { refreshPhotos(); refreshDrive() }
        // Access can change in Settings, and drives get plugged in, while
        // the app is in the background.
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshPhotos(); refreshDrive() } }
        .onChange(of: exporter.isBusy) { _, busy in
            if !busy { exports = Exporter.existingExports(); refreshPhotos(); refreshDrive() }
        }
    }

    // MARK: Choosing what to export

    private var photosSection: some View {
        Section {
            switch photoStatus {
            case .notDetermined:
                Button("Allow Photo Access") {
                    Task { photoStatus = await PhotoSource.requestAccess(); refreshPhotos() }
                }
            case .denied, .restricted:
                Text("PhoneZip can't see your photos.")
                Button("Open Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            default:
                Toggle("Photos (\(counts.photos.formatted()))", isOn: $includePhotos)
                Toggle("Videos (\(counts.videos.formatted()))", isOn: $includeVideos)
            }
        } header: {
            Text("Photo Library")
        } footer: {
            if photoStatus == .limited {
                Text("You gave access to selected photos only, so only those will be exported. Choose \"Full Access\" in Settings > PhoneZip > Photos to export everything.")
            } else if canSeePhotos {
                Text("Includes edits (with their originals), Live Photo videos, and hidden photos. Photos kept only in iCloud are downloaded first, which can take a while.")
            }
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(folders) { folder in
                Label(folder.name, systemImage: "folder")
            }
            .onDelete { folders.remove(atOffsets: $0) }
            Button("Add Folder…") { openPicker(.sourceFolders) }
        } header: {
            Text("Documents")
        } footer: {
            Text("iOS doesn't let apps read all your files. Pick folders instead, like \"On My iPhone\" or iCloud Drive, and everything inside them goes in the zip. App folders (the ones with an app icon) are separate, so add each one you want.")
        }
    }

    private var saveSpaceSection: some View {
        Section {
            Toggle("Save Space (Lower Quality)", isOn: $saveSpace.animation())
            if saveSpace {
                Toggle("Keep Original-Quality Videos", isOn: $keepOriginalVideos)
            }
        } header: {
            Text("Size")
        } footer: {
            if !saveSpace {
                Text("Off: every photo and video goes out exactly as it is on this iPhone, at full quality.")
            } else if keepOriginalVideos {
                Text("Photos are re-encoded as smaller HEICs (about half the size, some fine detail lost). Videos stay at full quality, so the export shrinks much less. Shrunk photos are never deleted from this iPhone.")
                    .foregroundStyle(.orange)
            } else {
                Text("Photos are re-encoded as smaller HEICs and videos as 1080p HEVC. A 3.4 GB export with lots of 4K video typically ends up under 1 GB, but quality is lost for good. Shrunk photos and videos are never deleted from this iPhone.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var driveSection: some View {
        Section {
            if let drive {
                Button {
                    requestExport(.drive(drive))
                } label: {
                    Label("Copy to \(drive.name)", systemImage: "externaldrive.fill").frame(maxWidth: .infinity)
                }
                .disabled(!hasSomethingToExport)
                Button("Choose Another Drive…") { openPicker(.drive) }
            } else {
                Button("Choose Drive…") { openPicker(.drive) }
            }
        } header: {
            Text("USB Drive")
        } footer: {
            Text("Goes in parts of up to 500 items (fewer when the iPhone runs low on space): each part is zipped, unzipped onto the drive, checked and removed from the iPhone before the next one. Keep PhoneZip open and the drive plugged in until it's done; the screen stays on.")
        }
    }

    // MARK: Progress

    @ViewBuilder
    private var progressSection: some View {
        Section {
            switch exporter.state {
            case .running(let part, let done, let total, let current) where total > 0:
                let verb = saver != nil ? "shrinking and zipping" : "zipping"
                progress(part > 0 ? "Part \(part): \(verb)" : verb.prefix(1).uppercased() + verb.dropFirst(),
                         done, total, current)
            case .moving(let part, let done, let total, let current) where total > 0:
                progress(part > 0 ? "Part \(part): copying to drive and checking" : "Copying to drive and checking",
                         done, total, current)
            case .moving:
                ProgressView("Opening the drive…")
            case .deleting:
                ProgressView("Deleting originals…")
            default:
                ProgressView("Finding files…")
            }
            if case .deleting = exporter.state {} else {
                Button("Cancel", role: .destructive) { exporter.cancel() }
            }
        } footer: {
            if case .moving = exporter.state {
                Text("Keep PhoneZip open and the drive plugged in. Every file is read back from the drive to make sure it copied correctly.")
            } else if case .deleting = exporter.state {
                Text("Only files that were checked on the drive are deleted.")
            } else if case .running(let part, _, _, _) = exporter.state, part > 0 {
                Text("Keep PhoneZip open and the drive plugged in. Parts already copied stay on the drive if you cancel.")
            } else {
                Text("Keep PhoneZip open. If you switch apps, iOS may pause the export.")
            }
        }
    }

    private func progress(_ title: String, _ done: Int, _ total: Int, _ current: String) -> some View {
        ProgressView(value: Double(done), total: Double(total)) {
            Text("\(title): \(done.formatted()) of \(total.formatted())")
        } currentValueLabel: {
            Text(current).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: After the zip

    private func finishedSection(_ result: Exporter.Result) -> some View {
        Section {
            Label(result.zip.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
            if result.skipped > 0 {
                Text("\(result.skipped) item(s) couldn't be read. Their names are in \"Skipped files.txt\" inside the zip.")
                    .foregroundStyle(.orange)
            }
            if let drive {
                Button {
                    exporter.move(result, to: drive)
                } label: {
                    Label("Move to \(drive.name)", systemImage: "externaldrive.fill")
                }
                Button("Choose Another Drive…") { openPicker(.drive) }
            } else {
                Button {
                    openPicker(.drive)
                } label: {
                    Label("Move to Drive…", systemImage: "externaldrive")
                }
            }
            ShareLink(item: result.zip) { Label("Share or Save…", systemImage: "square.and.arrow.up") }
            Button("Done") { exporter.reset() }
        } header: {
            Text("Zip Created")
        } footer: {
            Text("Move to Drive unzips everything onto a USB drive and checks every file, then offers to delete the originals from this iPhone. Plug the drive in first, then choose it (or a folder on it) under Locations.")
        }
    }

    private func movedSection(_ summary: Exporter.DriveSummary) -> some View {
        let photos = DriveTransfer.deletableAssets(summary.manifest, verified: summary.verified).count
        let files = DriveTransfer.deletableFiles(summary.manifest, verified: summary.verified).count
        return Section {
            if let stopped = summary.stopped {
                Label(stopped, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label("Copied and checked", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            LabeledContent("Folder on drive", value: summary.folder.lastPathComponent)
            if summary.parts > 1 {
                LabeledContent("Parts", value: summary.parts.formatted())
            }
            LabeledContent("Photos and videos", value: photos.formatted())
            LabeledContent("Files", value: files.formatted())
            if summary.skipped > 0 {
                Text("\(summary.skipped) item(s) couldn't be read, so they weren't copied and stay on this iPhone. Their names are in \"Skipped files.txt\".")
                    .foregroundStyle(.orange)
            }
            if !summary.failed.isEmpty {
                Text("\(summary.failed.count) file(s) didn't copy correctly. Their originals stay on this iPhone.")
                    .foregroundStyle(.orange)
            }
            if !summary.manifest.shrunkAssets.isEmpty {
                Text("\(summary.manifest.shrunkAssets.count.formatted()) photos and videos went to the drive at lower quality (Save Space), so their full-quality originals stay on this iPhone and can't be deleted here.")
                    .foregroundStyle(.orange)
            }
            Button("Delete Originals from iPhone…", role: .destructive) { confirmingDelete = true }
                .disabled(photos + files == 0)
            Button("Keep Them") { exporter.reset() }
        } header: {
            Text("On the Drive")
        } footer: {
            if summary.stopped != nil {
                Text("Only what was copied and checked can be deleted. Run it again later for the rest; it starts a new folder on the drive.")
            } else if summary.zipsKept > 0 {
                Text("\(summary.zipsKept == 1 ? "A zip was" : "\(summary.zipsKept) zips were") kept on this iPhone because some of their files didn't copy correctly.")
            } else {
                Text("No zips were left on this iPhone; the drive has everything unzipped.")
            }
        }
    }

    /// What Save Space does, spelled out before anything is re-encoded.
    private var lowQualityWarning: String {
        let shrinksVideos = saver.map { !$0.keepOriginalVideos } ?? false
        var lines = ["If you tap Yes, this export will NOT be a full-quality backup:"]
        if includePhotos {
            lines.append("• Every photo is re-encoded as a smaller HEIC. It looks about the same on a phone, but fine detail is thrown away, and RAW photos become ordinary HEICs that can no longer be edited as RAW.")
        }
        if shrinksVideos {
            lines.append("• Every video, including Live Photo videos, is re-encoded to 1080p HEVC. 4K, 60 fps and high-bitrate footage permanently loses resolution and sharpness.")
        } else {
            lines.append("• Videos are copied exactly as they are, at full quality.")
        }
        lines.append("• The lost quality can never be recovered from this export. The only full-quality copies are the originals on this iPhone (and in iCloud Photos, if it's on).")
        lines.append("• Because of that, PhoneZip will never offer to delete anything it shrank. If you delete those photos or videos yourself later, the full-quality versions are gone forever.")
        lines.append("• Re-encoding is much slower than a normal export and uses a lot of battery. Documents from folders are never changed.")
        return lines.joined(separator: "\n\n")
    }

    /// What deleting will do, spelled out before anything happens.
    private var deleteWarning: String {
        guard case .moved(let summary) = exporter.state else { return "" }
        let photos = DriveTransfer.deletableAssets(summary.manifest, verified: summary.verified).count
        let files = DriveTransfer.deletableFiles(summary.manifest, verified: summary.verified).count
        return """
        \(photos.formatted()) photos and videos and \(files.formatted()) files are safely on the drive and will be deleted from this iPhone.

        If iCloud Photos is on, the photos are also removed from iCloud and your other devices. Files from iCloud Drive are removed from iCloud too.

        Deleted photos stay in Photos › Recently Deleted for 30 days, and only free up space once that's emptied. Albums, favorites and captions aren't part of the copy.
        """
    }

    private func cleanedSection(_ report: DeleteReport) -> some View {
        Section {
            if report.photosDeleted > 0 {
                Label("Deleted \(report.photosDeleted.formatted()) photos and videos", systemImage: "trash")
            }
            if report.photosDeclined > 0 {
                Label("Kept \(report.photosDeclined.formatted()) photos and videos", systemImage: "photo")
            }
            if report.filesDeleted > 0 {
                Label("Deleted \(report.filesDeleted.formatted()) files", systemImage: "trash")
            }
            ForEach(report.problems, id: \.self) { problem in
                Text(problem).foregroundStyle(.orange)
            }
            Button("Done") { exporter.reset() }
        } header: {
            Text("Cleaned Up")
        } footer: {
            if report.photosDeleted > 0 {
                Text("To free the space now, empty Photos › Recently Deleted. Until then they can still be recovered.")
            }
        }
    }

    private var exportsSection: some View {
        Section {
            ForEach(exports, id: \.self) { url in
                ShareLink(item: url) {
                    LabeledContent(url.deletingPathExtension().lastPathComponent,
                                   value: ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file))
                }
            }
            .onDelete { offsets in
                for url in offsets.map({ exports[$0] }) { try? FileManager.default.removeItem(at: url) }
                exports = Exporter.existingExports()
                exporter.reset()
            }
        } header: {
            Text("Saved Zips")
        } footer: {
            Text("Swipe to delete a zip once it's safely copied off. They take up as much space as what's inside.")
        }
    }

    // MARK: Helpers

    /// Starts right away at full quality; in Save Space mode, only after the
    /// lower-quality warning is accepted.
    private func requestExport(_ job: ExportJob) {
        if saver != nil {
            pendingExport = job
        } else {
            run(job)
        }
    }

    private func run(_ job: ExportJob) {
        let photos = canSeePhotos && includePhotos
        let videos = canSeePhotos && includeVideos
        switch job {
        case .zipOnly:
            exporter.start(photos: photos, videos: videos, folders: folders, saver: saver)
        case .drive(let drive):
            exporter.exportToDrive(photos: photos, videos: videos, folders: folders, saver: saver, drive: drive)
        }
    }

    private func openPicker(_ job: PickerJob) {
        pickerJob = job
        showingPicker = true
    }

    private func picked(_ urls: [URL]) {
        switch pickerJob {
        case .sourceFolders:
            folders += urls.map(PickedFolder.init)
        case .drive:
            guard let url = urls.first else { return }
            if DriveStore.isOnThisPhone(url) {
                pickerError = "That folder is on this iPhone, so it wouldn't be a copy off the phone. Plug in your USB drive and choose it under Locations."
                return
            }
            let folder = PickedFolder(url: url)
            DriveStore.remember(url)
            drive = folder
            if case .finished(let result) = exporter.state {
                exporter.move(result, to: folder)
            }
        }
    }

    private func refreshPhotos() {
        photoStatus = PhotoSource.status
        if canSeePhotos { counts = PhotoSource.counts() }
    }

    private func refreshDrive() {
        drive = DriveStore.recall()
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

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
    @State private var pickingFolder = false
    @State private var pickerError: String?
    @State private var exports: [URL] = Exporter.existingExports()

    private var canSeePhotos: Bool { photoStatus == .authorized || photoStatus == .limited }
    private var hasSomethingToExport: Bool {
        (canSeePhotos && (includePhotos && counts.photos > 0 || includeVideos && counts.videos > 0)) || !folders.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if exporter.isBusy {
                    progressSection
                } else if case .finished(let zip, let bytes, let skipped) = exporter.state {
                    finishedSection(zip: zip, bytes: bytes, skipped: skipped)
                } else {
                    if case .failed(let message) = exporter.state {
                        Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                    photosSection
                    foldersSection
                    Section {
                        Button {
                            exporter.start(photos: canSeePhotos && includePhotos,
                                           videos: canSeePhotos && includeVideos,
                                           folders: folders)
                        } label: {
                            Label("Create Zip", systemImage: "archivebox").frame(maxWidth: .infinity)
                        }
                        .disabled(!hasSomethingToExport)
                    } footer: {
                        Text("Needs free space about the size of everything you export. Keep PhoneZip open until it's done; the screen stays on.")
                    }
                }
                if !exports.isEmpty && !exporter.isBusy {
                    exportsSection
                }
            }
            .navigationTitle("PhoneZip")
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): folders += urls.map(PickedFolder.init)
                case .failure(let error): pickerError = error.localizedDescription
                }
            }
            .alert("Couldn't add folder", isPresented: Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pickerError ?? "")
            }
        }
        .task { refreshPhotos() }
        // Access can change in Settings while the app is in the background.
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshPhotos() } }
        .onChange(of: exporter.isBusy) { _, busy in if !busy { exports = Exporter.existingExports() } }
    }

    // MARK: Sections

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
                Text("Includes edits, Live Photo videos, and hidden photos. Photos kept only in iCloud are downloaded first, which can take a while.")
            }
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(folders) { folder in
                Label(folder.name, systemImage: "folder")
            }
            .onDelete { folders.remove(atOffsets: $0) }
            Button("Add Folder…") { pickingFolder = true }
        } header: {
            Text("Documents")
        } footer: {
            Text("iOS doesn't let apps read all your files. Pick folders instead, like \"On My iPhone\" or iCloud Drive, and everything inside them goes in the zip. App folders (the ones with an app icon) are separate, so add each one you want.")
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        Section {
            if case .running(let done, let total, let current) = exporter.state, total > 0 {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("\(done.formatted()) of \(total.formatted())")
                } currentValueLabel: {
                    Text(current).lineLimit(1).truncationMode(.middle)
                }
            } else {
                ProgressView("Finding files…")
            }
            Button("Cancel", role: .destructive) { exporter.cancel() }
        } footer: {
            Text("Keep PhoneZip open. If you switch apps, iOS may pause the export.")
        }
    }

    private func finishedSection(zip: URL, bytes: Int64, skipped: Int) -> some View {
        Section {
            Label(zip.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            if skipped > 0 {
                Text("\(skipped) item(s) couldn't be read. Their names are in \"Skipped files.txt\" inside the zip.")
                    .foregroundStyle(.orange)
            }
            ShareLink(item: zip) { Label("Share or Save…", systemImage: "square.and.arrow.up") }
            Button("Done") { exporter.reset() }
        } footer: {
            Text("The zip is also in Files > On My iPhone > PhoneZip. For big exports, plug into a Mac and drag it out in Finder, or AirDrop it.")
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

    private func refreshPhotos() {
        photoStatus = PhotoSource.status
        if canSeePhotos { counts = PhotoSource.counts() }
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

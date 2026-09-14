#if DEBUG
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The OCR spike's page in Settings: the switch, what has been recorded, and
/// the way to get it off the phone.
///
/// Built for reading in the office, on the phone, straight after a capture.
/// The question of the day is whether the table came back as a table, and a
/// row here answers it without a Mac: tap a dump and its reading is on screen.
/// The archive is for afterwards, when the dumps become fixtures.
///
/// Debug builds only; it never ships, and neither does the section in
/// Settings that links to it.
struct SpikeDumpsScreen: View {

    @State private var enabled = SpikeDump.isEnabled
    @State private var dumps: [URL] = []
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Toggle("Record every capture", isOn: $enabled)
                    .onChange(of: enabled) { _, new in SpikeDump.isEnabled = new }
            } footer: {
                Text(
                    "While this is on, every image the app reads — shared, "
                        + "photographed or picked — is kept here with what the "
                        + "reader made of it, so a page that reads badly can "
                        + "become a test."
                )
            }

            Section {
                if dumps.isEmpty {
                    Text("Nothing recorded yet.")
                        .foregroundStyle(Palette.secondary)
                }
                ForEach(dumps, id: \.self) { dump in
                    NavigationLink(dump.lastPathComponent) {
                        SpikeReadingScreen(dump: dump)
                    }
                }
            } header: {
                Text(Self.dumpsTitle(count: dumps.count))
            }

            if !dumps.isEmpty {
                Section {
                    ShareLink(
                        item: SpikeArchive(),
                        preview: SharePreview("Office Daze spike dumps")
                    ) {
                        Label("Share all as a zip", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete all dumps", role: .destructive) {
                        do {
                            try SpikeDump.deleteAll()
                            dumps = []
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                } footer: {
                    Text(
                        "The zip holds every dump: the image as it arrived, "
                            + "Vision's full result, and the reduced reading in JSON "
                            + "and as text. Share it to a Mac before deleting."
                    )
                }
            }
        }
        .navigationTitle("OCR spike")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { dumps = SpikeDump.dumps() }
        .alert(
            "Not deleted",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// `Dumps · 3`, or `Dumps` when there is nothing to count.
    static func dumpsTitle(count: Int) -> String {
        count == 0 ? "Dumps" : "Dumps · \(count)"
    }
}

/// One dump's reading, as Vision saw it, in a monospaced block a table row
/// can be read across.
struct SpikeReadingScreen: View {
    let dump: URL

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(SpikeDump.rendered(of: dump))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.screenPadding)
        }
        .navigationTitle(dump.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every dump as one zip, made when the share sheet asks for it rather than
/// when the screen appears — the zip of a day's photographs is not something
/// to build on every visit to the page.
struct SpikeArchive: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { _ in
            SentTransferredFile(try SpikeDump.archive())
        }
    }
}
#endif

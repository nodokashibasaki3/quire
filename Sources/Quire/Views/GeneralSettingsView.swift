import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @Environment(PageFileStore.self) private var pageStore
    @Environment(TodoStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Daily pages folder")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.inkSecondary)

                HStack(spacing: 8) {
                    Text(pageStore.folderURL.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.rule, lineWidth: 1)
                        )

                    Button("Choose…") { chooseFolder() }
                    Button("Reveal") { reveal() }
                }

                Text("Each day's outline is saved as `YYYY-MM-DD.md` in this folder. " +
                     "You can sync the folder via iCloud / Dropbox / Git, or open the files in any editor.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTertiary)
                    .padding(.top, 2)
            }

            Spacer()
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("General")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.ink)
            Text("Where your data lives on disk.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSecondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to store your daily pages"
        panel.prompt = "Use This Folder"
        panel.directoryURL = pageStore.folderURL
        if panel.runModal() == .OK, let url = panel.url {
            pageStore.setFolderURL(url)
            store.reloadCurrentPage()
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([pageStore.folderURL])
    }
}

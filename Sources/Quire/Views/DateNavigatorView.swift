import SwiftUI

struct DateNavigatorView: View {
    @Environment(TodoStore.self) private var store
    @State private var showPicker = false
    @State private var pickerDate = Date()

    var body: some View {
        HStack(spacing: 14) {
            navButton(systemName: "chevron.left", action: store.goToPrev)
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous day  ⌘[")

            Button {
                pickerDate = DateHelpers.parseDay(store.currentDate) ?? Date()
                showPicker.toggle()
            } label: {
                Text(currentLabel)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .tracking(0.4)
                    .foregroundStyle(Color.inkSecondary)
                    .textCase(.uppercase)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .top) {
                DatePicker("", selection: $pickerDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(14)
                    .onChange(of: pickerDate) { _, newDate in
                        store.goTo(date: DateHelpers.formatDay(newDate))
                        showPicker = false
                    }
            }

            navButton(systemName: "chevron.right", action: store.goToNext)
                .keyboardShortcut("]", modifiers: .command)
                .help("Next day  ⌘]")

            Spacer()

            if !store.isToday {
                Button {
                    store.goToToday()
                } label: {
                    Text("Today")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.rule, lineWidth: 1)
                )
                .keyboardShortcut("t", modifiers: .command)
                .help("Jump to today  ⌘T")
            }
        }
    }

    private var currentLabel: String {
        if let relative = DateHelpers.relativeLabel(for: store.currentDate) {
            return "\(relative) · \(DateHelpers.shortLabel(for: store.currentDate))"
        }
        return DateHelpers.longLabel(for: store.currentDate)
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

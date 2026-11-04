import SwiftUI
#if os(macOS)
import AppKit
#endif

// Controls that grow with the style's text (docs/UI.md, 7). Text fields, buttons and checkboxes take
// the font the views set, but on the Mac menus, segmented controls and date fields keep the system's
// size whatever the font. At the standard size these are the system's own controls; once the text
// is noticeably larger or smaller, they're drawn here in the style's font.

extension FutureStyle.Fonts {
    /// Whether the text is near enough the standard size for the system's own controls to fit in.
    var usesSystemControls: Bool { (0.9..<1.15).contains(layoutScale) }
}

/// A menu of choices, as `Picker` with its label hidden. `current` is the chosen item's title,
/// shown on the button when the menu is drawn in the style's font.
struct FuturePicker<Value: Hashable, Content: View>: View {
    @Environment(\.futureStyle.fonts) private var fonts
    let title: String
    @Binding var selection: Value
    let current: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, selection: Binding<Value>, current: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _selection = selection
        self.current = current
        self.content = content
    }

    var body: some View {
        if fonts.usesSystemControls {
            Picker(title, selection: $selection, content: content)
                .labelsHidden()
        } else {
            Menu {
                // Inline, the choices are the menu's items, with a tick on the chosen one.
                Picker(title, selection: $selection, content: content)
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                HStack(spacing: fonts.scaled(6)) {
                    Text(current)
                        .font(fonts.font(size: FutureStyle.Fonts.standardSize))
                        .lineLimit(1)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(fonts.font(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, fonts.scaled(8))
                .padding(.vertical, fonts.scaled(4))
                .background(Theme.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: fonts.scaled(6)))
                .contentShape(RoundedRectangle(cornerRadius: fonts.scaled(6)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(title)
            .accessibilityValue(current)
        }
    }
}

/// A few choices side by side, as a segmented `Picker` with its label hidden.
struct FutureSegmentedPicker<Value: Hashable>: View {
    @Environment(\.futureStyle.fonts) private var fonts
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        if fonts.usesSystemControls {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    let chosen = option.value == selection
                    Button { if !chosen { selection = option.value } } label: {
                        Text(option.title)
                            .font(fonts.font(size: FutureStyle.Fonts.standardSize, weight: chosen ? .medium : .regular))
                            .lineLimit(1)
                            .foregroundStyle(chosen ? Theme.text : Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, fonts.scaled(4))
                            .background(chosen ? Theme.ink.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: fonts.scaled(5)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: fonts.scaled(7)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }
}

/// A date typed into a field, as `DatePicker` in its field style with its label hidden. It takes
/// the calendar and time zone from the environment, as `DatePicker` does.
struct FutureDatePicker: View {
    @Environment(\.futureStyle.fonts) private var fonts
    let title: String
    @Binding var selection: Date
    var earliest: Date?
    /// With the time of day as well as the date.
    var showsTime = false

    var body: some View {
        #if os(macOS)
        if fonts.usesSystemControls {
            systemPicker
        } else {
            ScaledDateField(selection: $selection, earliest: earliest, showsTime: showsTime,
                            font: fonts.measuringFont(size: FutureStyle.Fonts.standardSize))
                .fixedSize()
                .accessibilityLabel(title)
        }
        #else
        systemPicker
        #endif
    }

    @ViewBuilder private var systemPicker: some View {
        let components: DatePickerComponents = showsTime ? [.date, .hourAndMinute] : .date
        Group {
            if let earliest {
                DatePicker(title, selection: $selection, in: earliest..., displayedComponents: components)
            } else {
                DatePicker(title, selection: $selection, displayedComponents: components)
            }
        }
        .datePickerStyle(.field)
        .labelsHidden()
    }
}

#if os(macOS)
/// AppKit's date field, which draws in any font.
private struct ScaledDateField: NSViewRepresentable {
    @Binding var selection: Date
    let earliest: Date?
    let showsTime: Bool
    let font: CTFont

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        let elements: NSDatePicker.ElementFlags = showsTime ? [.yearMonthDay, .hourMinute] : .yearMonthDay
        if picker.datePickerElements != elements { picker.datePickerElements = elements }
        let font = font as NSFont
        if picker.font != font { picker.font = font }
        if picker.calendar != context.environment.calendar { picker.calendar = context.environment.calendar }
        if picker.timeZone != context.environment.timeZone { picker.timeZone = context.environment.timeZone }
        if picker.minDate != earliest { picker.minDate = earliest }
        if picker.dateValue != selection { picker.dateValue = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Date>
        init(selection: Binding<Date>) { self.selection = selection }

        @MainActor @objc func changed(_ sender: NSDatePicker) {
            if selection.wrappedValue != sender.dateValue { selection.wrappedValue = sender.dateValue }
        }
    }
}
#endif

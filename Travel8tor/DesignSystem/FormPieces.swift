import SwiftUI

/// The input side of the design system, which stages 1–5 never needed: every
/// screen up to now was a readout.
///
/// The awkward one is dates. SwiftUI's compact `DatePicker` is a rounded pill
/// and its graphical style is a rounded card, and rounded corners are the one
/// thing the brief calls load-bearing. The wheel has no corners of its own, so
/// it goes inside a hard rectangle like everything else.

/// A labelled text field. The label sits above at cell-label size, exactly as
/// the read-only `CellGrid` does, so a form reads as the same object as the
/// screens it feeds.
struct FieldRow: View {
    let label: String
    @Binding var value: String
    var placeholder: String = ""
    var required: Bool = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .t8(.cellLabel)
                    .foregroundStyle(Palette.bone.opacity(0.4))
                Spacer(minLength: 0)
                if required && value.trimmed.isEmpty {
                    Text("REQUIRED")
                        .t8(.cellLabel)
                        .foregroundStyle(Palette.desk.opacity(0.8))
                }
            }

            // The placeholder is an overlay rather than TextField's `prompt`.
            // SwiftUI draws the prompt in its own secondary grey and ignores
            // the foregroundStyle put on it, which lands close enough to real
            // data that an empty required field reads as a filled one.
            TextField("", text: $value)
                .font(.custom(T8Fonts.bold, size: 12.5))
                .foregroundStyle(Palette.bone)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(.top, 7)
                .overlay(alignment: .leading) {
                    if value.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .font(.custom(T8Fonts.regular, size: 12.5))
                            .foregroundStyle(Palette.bone.opacity(0.18))
                            .padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(required && value.trimmed.isEmpty ? Palette.desk.opacity(0.05) : .clear)
        .overlay {
            Rectangle().strokeBorder(
                required && value.trimmed.isEmpty
                    ? Palette.desk.opacity(0.55) : Palette.rail.opacity(0.25),
                lineWidth: Metrics.hairline
            )
        }
    }
}

/// A date, a time, or both, on a wheel inside a hard rectangle.
struct DateRow: View {
    let label: String
    @Binding var value: Date
    var components: DatePickerComponents = [.date]

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack {
                    Text(label)
                        .t8(.cellLabel)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                    Spacer(minLength: 8)
                    Text(formatted)
                        .t8(.fieldValueLarge)
                        .foregroundStyle(Palette.bone)
                        .monospacedDigit()
                    Text(open ? "×" : "▾")
                        .t8(.cellLabel)
                        .foregroundStyle(Palette.rail.opacity(0.7))
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if open {
                DatePicker("", selection: $value, displayedComponents: components)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
            }
        }
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline) }
    }

    /// Formatted here rather than by the picker, so the row reads in the app's
    /// own vocabulary — `FRI 11.09`, `09:00` — instead of the system's.
    private var formatted: String {
        let day = Day(of: value, in: .current)
        if components == [.hourAndMinute] {
            return TimeDisplay.local(value, in: .current)
        }
        if components.contains(.hourAndMinute) {
            return "\(TimeDisplay.dayStamp(day)) \(TimeDisplay.local(value, in: .current))"
        }
        return TimeDisplay.dayStamp(day)
    }
}

/// The square radio the arrival settings screen established, extracted so the
/// manual-entry screen's kind selector is the same control rather than a
/// lookalike.
struct SquareRadio: View {
    let title: String
    let selected: Bool
    var colour: Color = Palette.desk
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Rectangle().strokeBorder(
                        selected ? colour : Palette.bone.opacity(0.25),
                        lineWidth: Metrics.hairline
                    )
                    if selected {
                        Rectangle().fill(colour).frame(width: 8, height: 8)
                    }
                }
                .frame(width: 16, height: 16)

                Text(title)
                    .t8(.typeCode)
                    .foregroundStyle(selected ? Palette.bone : Palette.bone.opacity(0.6))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? colour.opacity(0.07) : .clear)
            .overlay {
                Rectangle().strokeBorder(
                    selected ? colour.opacity(0.5) : Palette.rail.opacity(0.25),
                    lineWidth: Metrics.hairline
                )
            }
        }
        .buttonStyle(.plain)
    }
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A blank field is an absence, not an empty string. Everything downstream
    /// stores `nil` rather than `""` — the never-guess rule's smaller cousin.
    var nilIfBlank: String? { trimmed.isEmpty ? nil : trimmed }
}

// A keys instrument's setup and its keyboard: the range of notes, how many are sampled, and a keyboard showing which keys are sampled
// (a dot) and which sampled note each key plays (the zones, in alternating shades). A click plays a key.
import SwiftUI
import TuneGodSamplerKit

struct KeysSettings: View {
    @Bindable var model: MakerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Lowest note").foregroundStyle(.secondary)
                        NoteStepper(model: model, note: $model.keys.lowest, end: .lowest)
                    }
                    GridRow {
                        Text("Highest note").foregroundStyle(.secondary)
                        NoteStepper(model: model, note: $model.keys.highest, end: .highest)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Samples").foregroundStyle(.secondary)
                        Picker("Samples", selection: $model.keys.notesPerOctave) {
                            ForEach(NOTES_PER_OCTAVE_CHOICES, id: \.self) { Text(perOctaveLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("How many notes of each octave are sampled. More notes sound closer to the plugin and make a larger instrument; the keys between them play the nearest sampled note, repitched.")
                    }
                    GridRow {
                        Text("Velocity layers").foregroundStyle(.secondary)
                        Stepper("\(model.keys.layerCount)", value: $model.keys.layers, in: 1...MAX_KEY_LAYERS)
                            .help("How many strengths each note is recorded at.")
                    }
                    GridRow {
                        Text("Hold").foregroundStyle(.secondary)
                        Stepper(value: $model.keys.holdSeconds, in: KEY_HOLD_RANGE, step: 0.5) {
                            Text("\(model.keys.holdLength.formatted(.number.precision(.fractionLength(0...1)))) s").monospacedDigit()
                        }
                        .help("How long each note is held before it is let go. On the phone a key held longer plays the plugin\u{2019}s release and ends.")
                    }
                }
            }
            KeyboardView(model: model)
            Text(mapping)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func perOctaveLabel(_ n: Int) -> String {
        switch n {
        case 12: return "12 an octave (every key)"
        case 1: return "1 an octave"
        default: return "\(n) an octave (every \(ordinal(12 / n)) key)"
        }
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    /// Which notes are sampled, and how the keys are given to them.
    private var mapping: String {
        let roots = model.keys.roots
        let first = roots.first.map(noteName) ?? "", last = roots.last.map(noteName) ?? ""
        let notes = roots.count == 1 ? "1 note is sampled (\(first))" : "\(roots.count) notes are sampled, \(first) to \(last)"
        return "\(notes). Each key plays the nearest one, repitched; keys outside the range play the lowest or highest."
    }
}

/// A note with a stepper and Learn (the next key played on a MIDI keyboard).
private struct NoteStepper: View {
    @Bindable var model: MakerModel
    @Binding var note: Int
    let end: MakerModel.RangeEnd

    var body: some View {
        HStack(spacing: 8) {
            Stepper(value: $note, in: 0...127) {
                Text("\(note) · \(noteName(note))").monospacedDigit().frame(width: 72, alignment: .leading)
            }
            Toggle(model.learningRange == end ? "Play a key\u{2026}" : "Learn", isOn: Binding(
                get: { model.learningRange == end },
                set: { model.learningRange = $0 ? end : nil }))
                .toggleStyle(.button)
                .help("Sets this note to the next key played on a MIDI keyboard.")
        }
    }
}

/// The keyboard from the C at or below the lowest note to the B at or above the highest.
struct KeyboardView: View {
    @Bindable var model: MakerModel
    @State private var held: Int?

    static let height: CGFloat = 64

    private static let blackInOctave: Set<Int> = [1, 3, 6, 8, 10]
    static func isBlack(_ note: Int) -> Bool { blackInOctave.contains(((note % 12) + 12) % 12) }

    /// The notes shown, whole octaves.
    private var shown: ClosedRange<Int> {
        let r = model.keys.range
        return (r.lowerBound - r.lowerBound % 12)...min(127, r.upperBound + 11 - r.upperBound % 12)
    }

    /// Each note's rectangle in a keyboard `width` wide.
    private func layout(width: CGFloat) -> [(note: Int, rect: CGRect)] {
        let whites = shown.filter { !Self.isBlack($0) }
        let w = width / CGFloat(max(1, whites.count))
        var out: [(Int, CGRect)] = []
        var x: CGFloat = 0
        for note in shown {
            if Self.isBlack(note) {
                out.append((note, CGRect(x: x - w * 0.3, y: 0, width: w * 0.6, height: Self.height * 0.6)))
            } else {
                out.append((note, CGRect(x: x, y: 0, width: w, height: Self.height)))
                x += w
            }
        }
        return out
    }

    /// The key under `point`: a black key above a white one.
    private func note(at point: CGPoint, width: CGFloat) -> Int? {
        let keys = layout(width: width)
        return keys.first { Self.isBlack($0.note) && $0.rect.contains(point) }?.note
            ?? keys.first { !Self.isBlack($0.note) && $0.rect.contains(point) }?.note
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let keys = layout(width: width)
            let roots = model.keys.roots
            let zones = keyZones(roots: roots)
            let range = model.keys.range
            Canvas { context, _ in
                let zoneOf = { (note: Int) in keyZoneIndex(topKeys: zones.map(\.topKey), key: note) }
                for pass in [false, true] {
                    for key in keys where Self.isBlack(key.note) == pass {
                        let path = Path(roundedRect: key.rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 2)
                        let inRange = range.contains(key.note)
                        var fill: Color = pass ? Color(white: 0.15) : .white
                        if !inRange { fill = pass ? Color(white: 0.35) : Color(white: 0.85) }
                        context.fill(path, with: .color(fill))
                        if inRange {
                            let shade = zoneOf(key.note) % 2 == 0 ? 0.22 : 0.42
                            context.fill(path, with: .color(Color.accentColor.opacity(shade)))
                        }
                        if model.lit.contains(key.note) { context.fill(path, with: .color(Color.accentColor.opacity(0.8))) }
                        context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
                        if roots.contains(key.note) {
                            let d = min(7, key.rect.width * 0.5)
                            let dot = CGRect(x: key.rect.midX - d / 2, y: key.rect.maxY - d - 5, width: d, height: d)
                            context.fill(Path(ellipseIn: dot), with: .color(pass ? .white : .black))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let now = note(at: value.location, width: width)
                    guard now != held else { return }
                    if let held { model.keyUp(held) }
                    held = now
                    if let now { model.keyDown(now) }
                }
                .onEnded { _ in
                    if let held { model.keyUp(held) }
                    held = nil
                })
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard, \(noteName(model.keys.range.lowerBound)) to \(noteName(model.keys.range.upperBound))")
        .accessibilityHint("Plays the keys. A MIDI keyboard plays them too.")
    }
}

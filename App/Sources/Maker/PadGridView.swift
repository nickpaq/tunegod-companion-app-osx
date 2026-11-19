// The sixteen pads, laid out as on the phone: four rows of four from the top left. A click plays a pad and selects it; the keys
// 1234 / QWER / ASDF / ZXCV play the rows.
import SwiftUI
import TuneGodSamplerKit

/// The keys that play the pads, row by row from the top left.
let PAD_KEYS = Array("1234qwerasdfzxcv")

/// A pad's colour by its sound Type; the phone gives a Type its own colour from the chosen scheme.
func padTint(_ type: String?) -> Color {
    switch type.flatMap(CategoryId.init(rawValue:)) {
    case .kick: return .red
    case .snare: return .orange
    case .clap: return .yellow
    case .closedHat: return .green
    case .openHat: return .teal
    case .cymbal: return .blue
    case .perc: return .purple
    default: return .gray
    }
}

struct PadGridView: View {
    @Bindable var model: MakerModel
    @FocusState private var focused: Bool

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { column in
                        PadCell(model: model, index: row * 4 + column) { focused = true }
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .up]) { press in
            guard press.modifiers.isEmpty, let key = press.characters.lowercased().first, let index = PAD_KEYS.firstIndex(of: key) else { return .ignored }
            if press.phase == .down { model.padDown(index) } else { model.padUp(index) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pads")
    }
}

private struct PadCell: View {
    @Bindable var model: MakerModel
    let index: Int
    let pressed: () -> Void
    @State private var down = false

    var body: some View {
        let pad = model.setup.pads[index]
        let selected = model.selectedPad == index
        let lit = model.lit.contains(index)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            if let pad {
                shape.fill(padTint(pad.type).opacity(lit ? 0.75 : 0.28))
                VStack(spacing: 2) {
                    Text(pad.label.isEmpty ? "Pad \(index + 1)" : pad.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(pad.note) · \(noteName(pad.note))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            } else {
                shape.strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Text("Empty").font(.caption).foregroundStyle(.tertiary)
            }
            Text(String(PAD_KEYS[index]).uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(5)
        }
        .frame(width: 84, height: 84)
        .overlay { if selected { shape.strokeBorder(Color.accentColor, lineWidth: 2) } }
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !down else { return }
                down = true
                pressed()
                model.selectedPad = index
                model.padDown(index)
            }
            .onEnded { _ in
                down = false
                model.padUp(index)
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pad.map { "\($0.label), pad \(index + 1), note \($0.note)" } ?? "Pad \(index + 1), empty")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            model.selectedPad = index
            model.padDown(index)
            model.padUp(index)
        }
    }
}

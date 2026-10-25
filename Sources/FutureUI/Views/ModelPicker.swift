import SwiftUI
import FutureEngine
import FutureFormula

/// The model picker (docs/UI.md, 5.7): opened from an empty slot chip to add a model, or from
/// Change… in the Slot tab to give a slot a different one.
struct ModelPicker: View {
    let store: ScenarioStore
    let request: ScenarioStore.PickerRequest

    @State private var query = ""
    @State private var category = ModelTemplate.Category.money
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    static let size = CGSize(width: 720, height: 460)

    private var templates: [ModelTemplate] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? ModelLibrary.all.filter { $0.category == category }
            : ModelLibrary.search(query)
    }

    private var selected: ModelTemplate? {
        let list = templates
        return list.first { $0.id == selection } ?? list.first
    }

    /// The slot being changed, when changing.
    private var changingIndex: Int? {
        guard case .change(let id) = request else { return nil }
        return store.slots.firstIndex { $0.id == id }
    }

    private var title: String {
        switch request {
        case .add(let position): return "Add a model to slot \(position + 1)"
        case .change: return "Change \(changingIndex.map { store.slots[$0].title } ?? "the slot")'s model"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit(choose)
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            HStack(spacing: 0) {
                categories.frame(width: 128)
                Divider()
                list.frame(width: 250)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .presentationBackground(Theme.panel)
        .foregroundStyle(Theme.text)
        .onAppear {
            searchFocused = true
            // Changing a model starts on the slot's current one.
            if let index = changingIndex, let current = ModelLibrary.all.first(where: { $0.name == store.slots[index].model }) {
                category = current.category
                selection = current.id
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ModelTemplate.Category.allCases) { item in
                let active = query.isEmpty && item == category
                Button {
                    category = item
                    query = ""
                    selection = nil
                } label: {
                    Text(item.title)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(active ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer()
        }
        .padding(8)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if templates.isEmpty {
                    Text(query.isEmpty && category == .plugins
                         ? "Plug-ins will appear here once the WebAssembly host is built (milestone M4). Lua and Python scripts will follow."
                         : "No models match “\(query)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(10)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(templates) { template in
                    let active = template.id == selected?.id
                    Button {
                        selection = template.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(template.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                KindBadge(kind: template.kind)
                            }
                            Text(template.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(active ? Theme.proposal.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Theme.proposal.opacity(0.5) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let template = selected {
            TemplateDetail(template: template, start: store.start, color: color, warning: warning(for: template),
                           actionTitle: actionTitle, action: choose)
                .id(template.id)
        } else {
            Color.clear
        }
    }

    private var color: Color {
        switch request {
        case .add(let position): return Color(hex: SlotPalette.color(forSlotAt: position))
        case .change: return changingIndex.map { store.slots[$0].color } ?? Theme.proposal
        }
    }

    private var actionTitle: String {
        switch request {
        case .add(let position): return "Add to slot \(position + 1)"
        case .change: return "Use for \(changingIndex.map { store.slots[$0].title } ?? "this slot")"
        }
    }

    private func warning(for template: ModelTemplate) -> String? {
        guard let index = changingIndex else { return nil }
        return store.eventsThatWontApply(inSlotAt: index, with: template)
    }

    private func choose() {
        guard let template = selected else { return }
        switch request {
        case .add(let position): store.addModel(template, atPosition: position)
        case .change: if let index = changingIndex { store.changeModel(ofSlotAt: index, to: template) }
        }
    }
}

struct KindBadge: View {
    let kind: ModelKind

    var body: some View {
        Text(kind.title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.chipBorder))
    }
}

/// What the picker shows about one model: a preview of its line, its parameters and what it
/// handles, reads and sends.
private struct TemplateDetail: View {
    let template: ModelTemplate
    let start: Date
    let color: Color
    let warning: String?
    let actionTitle: String
    let action: () -> Void

    @State private var preview: [Sample]?

    private var facts: TemplateFacts { TemplateFacts.of(template) }

    var body: some View {
        let facts = self.facts
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name).font(.system(size: 16, weight: .semibold))
                Text(facts.line).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let reads = facts.reads {
                    Text("Reads \(reads), so it has no preview on its own.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                } else if let preview {
                    Sparkline(samples: preview, color: color)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
                }
            }
            .frame(height: 64)
            .accessibilityLabel("Preview of \(template.name) over 20 years")
            Text("20 years from \(DateText.monthYear(start)), with its defaults")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    values("Parameters", facts.parameters)
                    values("Starting values", facts.starting)
                }
            }
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(actionTitle, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(facts.error != nil)
            }
        }
        .padding(14)
        .task(id: template.id) {
            guard facts.reads == nil else { return }
            preview = await TemplatePreview.samples(for: template, start: start)
        }
    }

    @ViewBuilder
    private func values(_ title: String, _ list: [SlotValue]) -> some View {
        if !list.isEmpty {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.top, 4)
            ForEach(list) { value in
                HStack {
                    Text(value.label).font(.system(size: 12))
                    Spacer()
                    Text(value.value.map(value.text) ?? "From formula")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
            }
        }
    }
}

/// A small line chart for the picker's preview.
private struct Sparkline: View {
    let samples: [Sample]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let finite = samples.filter { $0.value.isFinite }
            guard let first = finite.first, let last = finite.last, last.time > first.time else { return }
            var low = finite.map(\.value).min()!, high = finite.map(\.value).max()!
            if !(high > low) { low -= 1; high += 1 }
            let span = last.time.timeIntervalSince(first.time)
            var path = Path()
            for (offset, sample) in finite.enumerated() {
                let x = CGFloat(sample.time.timeIntervalSince(first.time) / span) * size.width
                let y = (1 - CGFloat((sample.value - low) / (high - low))) * (size.height - 6) + 3
                if offset == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.hairline))
        }
    }
}

/// What a library model declares, worked out once per model.
@MainActor
struct TemplateFacts {
    let line: String
    let reads: String?
    let parameters: [SlotValue]
    let starting: [SlotValue]
    let error: String?

    private static var cache: [String: TemplateFacts] = [:]

    static func of(_ template: ModelTemplate) -> TemplateFacts {
        if let facts = cache[template.id] { return facts }
        let facts = make(template)
        cache[template.id] = facts
        return facts
    }

    private static func make(_ template: ModelTemplate) -> TemplateFacts {
        let model: FormulaModel
        do {
            model = try FormulaModel(template.formula, name: template.slotName)
        } catch {
            return TemplateFacts(line: template.kind.title, reads: nil, parameters: [], starting: [], error: String(describing: error))
        }
        let descriptor = model.descriptor
        func value(_ variable: Variable) -> SlotValue {
            SlotValue(name: variable.name, label: variable.label ?? variable.name, quantity: variable.quantity ?? .number,
                      minimum: variable.minimum, maximum: variable.maximum, increment: variable.increment,
                      value: model.startingValues[variable.name], defaultValue: model.declaredDefaults[variable.name],
                      isChanged: false)
        }
        var parts = [template.kind.title, descriptor.stepRate.adverb]
        if !model.handledEventKinds.isEmpty { parts.append("handles " + model.handledEventKinds.joined(separator: ", ")) }
        if !descriptor.emits.isEmpty { parts.append("sends " + descriptor.emits.joined(separator: ", ")) }
        let reads = descriptor.inputs.compactMap { $0.source.map { "\($0.slot).\($0.variable)" } }
        return TemplateFacts(
            line: parts.joined(separator: " · "),
            reads: reads.isEmpty ? nil : reads.joined(separator: ", "),
            parameters: descriptor.variables.filter { $0.causality == .parameter }.map(value),
            starting: model.startingValueNames.compactMap { descriptor.variable(named: $0) }.map(value),
            error: nil)
    }
}

/// Computes a model's line for the picker on a background thread: the main thread never computes.
enum TemplatePreview {
    static func samples(for template: ModelTemplate, start: Date, years: Int = 20) async -> [Sample] {
        await Task.detached(priority: .userInitiated) {
            guard let model = try? FormulaModel(template.formula, name: template.slotName),
                  model.descriptor.inputs.isEmpty, model.descriptor.subscriptions.isEmpty else { return [Sample]() }
            let scenario = Scenario(start: start)
            guard let id = try? scenario.addSlot(template.slotName, model: model) else { return [] }
            let end = CivilDate.date(year: CivilDate(start).year + years, month: CivilDate(start).month, day: 1)
            return (try? scenario.series(template.variable, of: id, from: start, through: end)) ?? []
        }.value
    }
}

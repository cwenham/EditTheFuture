import Foundation
import FutureDocument
import FutureEngine
import FutureVisuals

/// What a slot draws behind its graph (docs/DESIGN.md, 9.6). scenario.md's reader checks how it's
/// written (`BackdropSetting`).
public typealias BackdropBinding = BackdropSetting

extension BackdropSetting {
    /// The field it draws from this model: the one named, else the first whose geometry the
    /// backdrop draws. Nil for points, and when there's none.
    func field(in descriptor: ModelDescriptor?, catalog: BackdropCatalog) -> FieldDescriptor? {
        guard !isPoint, let descriptor, let backdrop = catalog.backdrop(id: id) else { return nil }
        if let field { return descriptor.field(named: field).flatMap { backdrop.draws(geometry: $0.geometry) ? $0 : nil } }
        return descriptor.fields.first { backdrop.draws(geometry: $0.geometry) }
    }
}

/// One choice in the Slot tab's Backdrop menu.
public struct BackdropChoice: Hashable, Sendable, Identifiable {
    public let binding: BackdropBinding
    /// "World map: Share infected", "Parts of a whole: Where everyone is", "World map: Position".
    public let title: String

    public var id: String { binding.text }
}

extension ScenarioStore {
    /// What the slot can draw behind its graph: each backdrop with each field it draws, and a position
    /// on any that draws points when the slot has the two values it looks for: latitude and longitude
    /// (or lat and lon) on the world map, declination and right ascension (or dec and ra) on the sky.
    public func backdropChoices(forSlotAt index: Int) -> [BackdropChoice] {
        guard descriptors.indices.contains(index), let descriptor = descriptors[index] else { return [] }
        var choices: [BackdropChoice] = []
        for field in descriptor.fields {
            for backdrop in configuration.backdrops.drawing(geometry: field.geometry) {
                choices.append(BackdropChoice(binding: BackdropBinding(id: backdrop.id, field: field.name),
                                              title: "\(backdrop.name): \(field.label ?? field.name)"))
            }
        }
        let names = Set(descriptor.readable.map(\.name))
        for backdrop in configuration.backdrops.backdrops where backdrop.drawsPoints {
            guard let (latitude, longitude) = backdrop.pointNames.first(where: { names.contains($0.0) && names.contains($0.1) }) else {
                continue
            }
            choices.append(BackdropChoice(binding: BackdropBinding(id: backdrop.id, latitude: latitude, longitude: longitude),
                                          title: "\(backdrop.name): Position"))
        }
        return choices
    }

    /// Draws a backdrop behind the slot's graph, or none, as one change that undo takes back.
    public func setBackdrop(_ binding: BackdropBinding?, inSlotAt index: Int) {
        guard isSlot(index), configs[index].backdrop != binding else { return }
        var config = configs[index]
        config.backdrop = binding
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
    }
}

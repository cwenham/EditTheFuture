#if os(macOS)
import AppKit
import SwiftUI

/// Writes the visible timeline to the pasteboard in several formats at once, so each app
/// pastes the one it understands (DESIGN.md, section 11).
@MainActor
public enum SnapshotExporter {
    public static let tabularText = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
    public static let snapshotType = NSPasteboard.PasteboardType(SnapshotData.typeIdentifier)

    public enum Contents {
        /// Image, PDF, table and the app's own format.
        case everything
        /// Table and the app's own format only.
        case dataOnly
    }

    /// The data for each pasteboard type.
    public static func payload(state: PanelState, data: SnapshotData, contents: Contents) throws -> [NSPasteboard.PasteboardType: Data] {
        var payload: [NSPasteboard.PasteboardType: Data] = [:]
        let table = data.tsv()
        payload[.string] = Data(table.utf8)
        payload[tabularText] = Data(table.utf8)
        payload[snapshotType] = try data.json()
        if contents == .everything {
            let view = SnapshotView(state: state)
            if let png = renderPNG(view) { payload[.png] = png }
            if let pdf = renderPDF(view) { payload[.pdf] = pdf }
        }
        return payload
    }

    /// Writes to `pasteboard` and returns a short description of what was copied.
    @discardableResult
    public static func copy(state: PanelState, data: SnapshotData, contents: Contents,
                            to pasteboard: NSPasteboard = .general) throws -> String {
        let payload = try payload(state: state, data: data, contents: contents)
        let order: [NSPasteboard.PasteboardType] = [.png, .pdf, tabularText, .string, snapshotType]
        let types = order.filter { payload[$0] != nil }
        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)
        for type in types {
            pasteboard.setData(payload[type], forType: type)
        }
        return contents == .everything ? "Copied image, PDF, table and snapshot" : "Copied table and snapshot"
    }

    static func renderPNG<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func renderPDF<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        let data = NSMutableData()
        var succeeded = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            succeeded = true
        }
        return succeeded ? data as Data : nil
    }
}
#endif

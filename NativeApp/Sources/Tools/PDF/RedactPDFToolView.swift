import PDFKit
import SwiftUI

/// PDF schwärzen (Phase 4, L3): Begriffe suchen, Treffer markiert ansehen, dann echt schwärzen.
/// Betroffene Seiten werden als Bild neu aufgebaut, der Text darunter ist danach nicht mehr in der Datei.
@MainActor
struct RedactPDFToolView: View {
    let session: ToolSession
    @State private var document: PDFDocument?
    @State private var error: String?
    @State private var terms = ""
    @State private var hits: [Int: [CGRect]] = [:]

    private var termList: [String] {
        terms.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var areaCount: Int { hits.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        ToolShell(session: session, saveTitle: "Redact and save copy", saveEnabled: !hits.isEmpty, onSave: save) {
            if let document {
                PDFHitView(document: document, hits: hits)
            } else {
                LoadingOrError(error: error)
            }
        } sidebar: {
            SidebarSection(title: "Words to remove") {
                TextEditor(text: $terms)
                    .font(.body)
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("One word or phrase per line, for example a name, an IBAN or an address.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: hits.isEmpty ? "Matches" : "Matches (\(areaCount))") {
                if termList.isEmpty {
                    Text("Matches appear here and are outlined in the preview.").font(.caption2).foregroundStyle(.secondary)
                } else if hits.isEmpty {
                    Text("Not found. Scanned pages without a text layer cannot be searched.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(hits.keys.sorted(), id: \.self) { page in
                        HStack {
                            Text("Page \(page + 1)").font(.callout)
                            Spacer()
                            Text("\(hits[page]?.count ?? 0)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SidebarSection(title: "What happens") {
                Text("Pages with matches become images with black bars, so the hidden text is gone for good. Those pages can no longer be searched or edited. Title, author and bookmarks are removed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            do { document = try PDFOps.document(session.primary) } catch { self.error = error.localizedDescription }
        }
        .onChange(of: terms) { _ in search() }
    }

    private func search() {
        guard let document else { return }
        hits = PDFOps.redactionHits(in: document, terms: termList)
    }

    private func save() {
        let terms = termList
        let source = session.primary
        let destination = session.outputURL(suffix: "redacted", ext: "pdf")
        session.run(title: "Redacting", detail: source.lastPathComponent) { progress in
            try PDFOps.redact(source, terms: terms, to: destination, progress: progress)
            return [destination]
        }
    }
}

/// PDF-Vorschau mit umrandeten Treffern (nur Anzeige, nichts wird verändert).
private struct PDFHitView: NSViewRepresentable {
    let document: PDFDocument
    let hits: [Int: [CGRect]]

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Markierungen als vorübergehende Anmerkungen einer Kopie, damit das Original unberührt bleibt
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == "OpenTangerineHit" { page.removeAnnotation(annotation) }
            for rect in hits[index] ?? [] {
                let mark = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
                mark.color = NSColor.systemOrange
                mark.interiorColor = NSColor.systemOrange.withAlphaComponent(0.25)
                mark.userName = "OpenTangerineHit"
                page.addAnnotation(mark)
            }
        }
        view.setNeedsDisplay(view.bounds)
    }
}

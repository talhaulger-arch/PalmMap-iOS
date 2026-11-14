import CoreText
import SwiftUI
import UIKit

struct PalmTraces: View {
    let hands: [HandReading]
    let language: PalmLanguage

    var body: some View {
        if !hands.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(hands) { hand in
                    PalmCard {
                        Text(hand.side.title(language)).font(.footnote.weight(.semibold))
                        Canvas { context, size in
                            let grid = stride(from: 0.2, through: 0.81, by: 0.2)
                            var guide = Path()
                            for value in grid {
                                guide.move(to: CGPoint(x: size.width * CGFloat(value), y: 0))
                                guide.addLine(to: CGPoint(x: size.width * CGFloat(value), y: size.height))
                                guide.move(to: CGPoint(x: 0, y: size.height * CGFloat(value)))
                                guide.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(value)))
                            }
                            context.stroke(guide, with: .color(PalmStyle.gold.opacity(0.11)), lineWidth: 0.5)
                            for line in hand.traces {
                                var trace = Path()
                                trace.addLines(line.points.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) })
                                let color: Color = switch line.kind {
                                case .heart: Color(red: 0.94, green: 0.51, blue: 0.55)
                                case .head: Color(red: 0.48, green: 0.85, blue: 0.77)
                                case .life: PalmStyle.gold
                                }
                                context.stroke(trace, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .background(PalmStyle.night.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(hand.traces.map { $0.kind.title(language) }.joined(separator: ", "))
                    }
                }
            }
        }
    }
}

struct ArchiveScreen: View {
    let language: PalmLanguage
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var commerce: PalmCommerce
    @EnvironmentObject private var readings: PalmReadings
    @State private var showAccount = false
    @State private var loading = false
    @State private var message = ""
    @State private var opened: OwnedReading?

    var body: some View {
        PalmScreen {
            PalmTitle(title: language.text("Raporlarım", "My reports"), subtitle: "")
            if let uid = account.uid {
                if let pending = readings.pending {
                    PalmCard {
                        Text(language.text("Bekleyen rapor", "Pending reading")).font(.headline)
                        Text(pending.names.joined(separator: " & "))
                        Button(language.text("Raporu açmayı sürdür", "Continue opening report")) {
                            Task {
                                await run {
                                    opened = try await readings.finish(pending, uid: uid)
                                    try? await commerce.refresh(uid)
                                }
                            }
                        }.buttonStyle(PalmActionStyle()).disabled(readings.working)
                        NavigationLink(language.text("Ücretler ve paketler", "Pricing and plans")) { ShopScreen(language: language) }
                    }
                }
                ForEach(readings.reports) { report in
                    NavigationLink {
                        ReportScreen(reading: report, language: language)
                    } label: {
                        PalmCard {
                            Text(report.names.isEmpty
                                 ? language.text("Kişisel okuma", "Personal reading")
                                 : report.names.joined(separator: " & ")).font(.headline)
                            Text(report.isRelationship ? language.text("İlişki analizi", "Relationship reading") : language.text("Kişisel okuma", "Personal reading"))
                                .font(.footnote).foregroundStyle(PalmStyle.muted)
                        }
                    }.buttonStyle(.plain)
                }
                if readings.reports.isEmpty {
                    Text(language.text("Bu cihazda kayıtlı rapor yok.", "There are no saved reports on this device."))
                        .foregroundStyle(PalmStyle.muted)
                }
                Button(language.text("Son kişisel raporu hesabımdan getir", "Restore latest personal reading")) {
                    Task {
                        await run {
                            opened = try await readings.restoreLatest(uid)
                            if opened == nil { message = language.text("Hesabında kayıtlı bir kişisel rapor bulunamadı.", "No personal reading was found on your account.") }
                        }
                    }
                }.buttonStyle(.bordered).disabled(loading)
            } else {
                Button(language.text("Hesaba giriş yap", "Sign in")) { showAccount = true }.buttonStyle(PalmActionStyle())
            }
            if loading { ProgressView() }
            if !message.isEmpty { PalmMessage(value: message) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { ReportScreen(reading: $0, language: language) }
        .sheet(isPresented: $showAccount) { AccountSheet(language: language) }
    }

    private func run(_ work: () async throws -> Void) async {
        loading = true
        message = ""
        defer { loading = false }
        do { try await work() } catch { message = PalmAPI.message(error, language) }
    }
}

struct ReportScreen: View {
    let reading: OwnedReading
    let language: PalmLanguage
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var readings: PalmReadings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false
    @State private var flagOpen = false
    @State private var feedbackOpen = false
    @State private var message = ""
    @State private var pdf: ReadingPDF?

    private var l: PalmLanguage { reading.language }
    private var reportTitle: String { reading.isRelationship ? l.text("İlişki raporunuz", "Your relationship reading") : l.text("Kişisel okuman", "Your personal reading") }

    var body: some View {
        PalmScreen {
            PalmTitle(title: reportTitle, subtitle: reading.names.joined(separator: " & "))
            if reading.isRelationship && !opened {
                Image("RelationshipArt").resizable().scaledToFit().frame(maxHeight: 310)
                    .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
                Button(l.text("Mührü aç", "Open the seal")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { opened = true }
                }.buttonStyle(PalmActionStyle())
            } else {
                if let value = reading.personal { personal(value) }
                if let value = reading.relationship { relationship(value) }
                Text(l.text("Geleneksel el yorumuna dayalıdır ve eğlence amaçlıdır. Yıl kartları sembolik temaları gösterir.",
                            "Inspired by traditional palm reading and offered for entertainment. Year cards describe symbolic themes."))
                    .font(.footnote).foregroundStyle(PalmStyle.muted)
                ShareLink(item: sharedText) {
                    Label(language.text("Raporu paylaş", "Share reading"), systemImage: "square.and.arrow.up")
                }.buttonStyle(.bordered)
                Button(language.text("PDF paylaş", "Share PDF")) {
                    do { pdf = try ReadingPDF.make(from: sharedText) }
                    catch { message = PalmAPI.message(error, language) }
                }.buttonStyle(.bordered)
                if account.uid != nil {
                    Button(language.text("İçeriği bildir", "Report content")) { flagOpen = true }
                    if !reading.isRelationship {
                        Button(language.text("Geri bildirim ver", "Give feedback")) { feedbackOpen = true }
                    }
                }
                if !message.isEmpty { PalmMessage(value: message) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(language.text("Bildirim nedeni", "Reason for reporting"), isPresented: $flagOpen, titleVisibility: .visible) {
            Button(language.text("Rahatsız edici içerik", "Harmful or offensive")) { flag("harmful_or_offensive") }
            Button(language.text("Yanıltıcı yorum", "Misleading or upsetting")) { flag("misleading_or_upsetting") }
            Button(language.text("Diğer", "Other")) { flag("other") }
        }
        .sheet(isPresented: $feedbackOpen) { FeedbackSheet(reading: reading, language: language) }
        .sheet(item: $pdf) { document in
            PDFShareSheet(url: document.url)
                .onDisappear { try? FileManager.default.removeItem(at: document.url.deletingLastPathComponent()) }
        }
    }

    @ViewBuilder
    private func personal(_ value: PersonalReading) -> some View {
        if let impact = value.impactLine, !impact.isEmpty {
            Text(impact).font(.system(.title2, design: .serif, weight: .medium)).foregroundStyle(PalmStyle.gold)
        }
        if let overview = value.overview, !overview.isEmpty { paragraph(l.text("Genel okuma", "Overview"), overview) }
        PalmTraces(hands: reading.hands, language: l)
        if let comparison = value.leftRight, !comparison.isEmpty {
            paragraph(l.text("İki avuç birlikte", "Both palms together"), comparison)
        }
        ForEach(value.sections ?? []) { item in
            PalmCard {
                Text(reading.titles[item.key] ?? sectionTitle(item.key)).font(.system(.title3, design: .serif, weight: .semibold))
                Text(item.narrative)
                if let use = item.use, !use.isEmpty { Text(use).foregroundStyle(PalmStyle.gold) }
                if let watch = item.watch, !watch.isEmpty { Text(watch).font(.subheadline).foregroundStyle(PalmStyle.muted) }
            }
        }
        ForEach(value.futureProjections ?? []) { item in
            PalmCard {
                Text(item.title).font(.system(.title3, design: .serif, weight: .semibold))
                if let year = reading.years[item.domain] {
                    Text(String(year)).foregroundStyle(PalmStyle.gold).font(.title2.monospacedDigit())
                }
                Text(item.outlook)
                Text(item.positive).foregroundStyle(PalmStyle.gold)
                if let caution = item.caution, !caution.isEmpty { Text(caution).foregroundStyle(PalmStyle.muted) }
            }
        }
        outlook(value.nearTermOutlook)
        if let closing = value.closing, !closing.isEmpty { Text(closing).foregroundStyle(PalmStyle.muted) }
    }

    @ViewBuilder
    private func relationship(_ value: RelationshipReading) -> some View {
        paragraph(l.text("Ortak okuma", "Your shared reading"), value.overview)
        ForEach(value.sections) { item in
            PalmCard {
                Text(reading.titles[item.code] ?? item.code).font(.system(.title3, design: .serif, weight: .semibold))
                Text(item.narrative)
                Text(item.opportunity).foregroundStyle(PalmStyle.gold)
                Text(item.attention).foregroundStyle(PalmStyle.muted)
                Text(item.practice).font(.subheadline)
            }
        }
        outlook(value.nearTermOutlook)
    }

    @ViewBuilder
    private func outlook(_ reading: NearTermReading?) -> some View {
        if let reading, (3...8).contains(reading.months), !reading.paragraphs.isEmpty {
            PalmCard {
                Text(l.text("Önündeki \(reading.months) ay", "Your next \(reading.months) months"))
                    .font(.system(.title3, design: .serif, weight: .semibold))
                ForEach(Array(reading.paragraphs.enumerated()), id: \.offset) { _, value in Text(value) }
            }
        }
    }

    private func paragraph(_ title: String, _ value: String) -> some View {
        PalmCard {
            Text(title).font(.system(.title3, design: .serif, weight: .semibold))
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ key: String) -> String {
        switch key {
        case "head_line": return PalmLineKind.head.title(l)
        case "heart_line": return PalmLineKind.heart.title(l)
        case "life_line": return PalmLineKind.life.title(l)
        default: return l.text("El bulgusu", "Palm finding")
        }
    }

    private var sharedText: String {
        var parts = ["PalmMap · \(reportTitle)", reading.names.joined(separator: " & ")]
        if let value = reading.personal {
            parts += [value.overview ?? ""]
            parts += (value.sections ?? []).map(\.narrative)
            parts += (value.futureProjections ?? []).map { "\($0.title)\n\($0.outlook)" }
            parts += value.nearTermOutlook?.paragraphs ?? []
        }
        if let value = reading.relationship {
            parts += [value.overview]
            parts += value.sections.map { "\(reading.titles[$0.code] ?? $0.code)\n\($0.narrative)" }
            parts += value.nearTermOutlook?.paragraphs ?? []
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func flag(_ reason: String) {
        guard let uid = account.uid else { return }
        Task {
            do {
                try await readings.flag(reading, reason: reason, uid: uid)
                message = language.text("İçerik bildirimin alındı.", "Your report was received.")
            } catch { message = PalmAPI.message(error, language) }
        }
    }
}

private struct ReadingPDF: Identifiable {
    let url: URL
    var id: URL { url }

    @MainActor
    static func make(from text: String) throws -> ReadingPDF {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let copy = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor(red: 0.08, green: 0.19, blue: 0.17, alpha: 1),
            .paragraphStyle: paragraph
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(copy as CFAttributedString)
        let margin = CGPath(rect: page.insetBy(dx: 46, dy: 50), transform: nil)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            var index = 0
            while index < copy.length {
                context.beginPage()
                let graphics = context.cgContext
                graphics.saveGState()
                graphics.textMatrix = .identity
                graphics.translateBy(x: 0, y: page.height)
                graphics.scaleBy(x: 1, y: -1)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: index, length: 0), margin, nil)
                CTFrameDraw(frame, graphics)
                let length = CTFrameGetVisibleStringRange(frame).length
                graphics.restoreGState()
                guard length > 0 else { break }
                index += length
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("PalmMap.pdf")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return ReadingPDF(url: url)
    }
}

private struct PDFShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct FeedbackSheet: View {
    let reading: OwnedReading
    let language: PalmLanguage
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var readings: PalmReadings
    @Environment(\.dismiss) private var dismiss
    @State private var rating: String?
    @State private var suggestion = ""
    @State private var message = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            PalmScreen {
                PalmTitle(title: language.text("Rapor geri bildirimi", "Reading feedback"), subtitle: "")
                HStack {
                    Button(language.text("Beğendim", "Liked it")) { rating = "like" }
                        .buttonStyle(.bordered).tint(rating == "like" ? PalmStyle.gold : PalmStyle.muted)
                    Button(language.text("Geliştirilebilir", "Could improve")) { rating = "dislike" }
                        .buttonStyle(.bordered).tint(rating == "dislike" ? PalmStyle.gold : PalmStyle.muted)
                }
                TextField(language.text("Önerin", "Your suggestion"), text: $suggestion, axis: .vertical)
                    .lineLimit(3...5).textFieldStyle(.roundedBorder)
                    .onChange(of: suggestion) { _, new in if new.count > 500 { suggestion = String(new.prefix(500)) } }
                Button(language.text("Gönder", "Submit")) {
                    guard let uid = account.uid else { return }
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            try await readings.feedback(reading, rating: rating, suggestion: suggestion, uid: uid)
                            dismiss()
                        } catch { message = PalmAPI.message(error, language) }
                    }
                }.buttonStyle(PalmActionStyle())
                    .disabled(working || (rating == nil && suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if !message.isEmpty { PalmMessage(value: message) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("Kapat", "Close")) { dismiss() }
                }
            }
        }
    }
}

import AVFoundation
import CryptoKit
import PhotosUI
import SwiftUI
import UIKit

struct CaptureFlow: View {
    let language: PalmLanguage
    let relationship: Bool
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var commerce: PalmCommerce
    @EnvironmentObject private var readings: PalmReadings
    @State private var first: [HandReading] = []
    @State private var second: [HandReading] = []
    @State private var fingerprints: Set<Data> = []
    @State private var profile = PalmProfile()
    @State private var partnerName = ""
    @State private var camera = false
    @State private var selection: PhotosPickerItem?
    @State private var analyzing = false
    @State private var message = ""
    @State private var draft: PendingReport?
    @State private var finished: OwnedReading?
    @State private var dateField: DateField?
    @State private var showConsent = false
    @State private var showAccount = false
    @State private var rewardOnly = false
    @State private var analysisTask: Task<Void, Never>?

    private enum DateField: String, Identifiable {
        case birth, marriage
        var id: String { rawValue }
    }

    private var takingSecond: Bool { relationship && first.count == 2 }
    private var complete: Bool { first.count == 2 && (!relationship || second.count == 2) }
    private var side: PalmSide { (takingSecond ? second : first).isEmpty ? .left : .right }

    var body: some View {
        PalmScreen {
            if let draft {
                preview(draft)
            } else if complete {
                profileFields
            } else {
                capture
            }
            if !message.isEmpty { PalmMessage(value: message) }
        }
        .navigationTitle(relationship ? language.text("İlişki analizi", "Relationship reading") : language.text("Kişisel okuma", "Personal reading"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $camera) {
            PalmCamera { data in
                camera = false
                if let data { start(data) }
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $showAccount) { AccountSheet(language: language) }
        .sheet(isPresented: $showConsent) {
            AIConsent(language: language, relationship: relationship) {
                showConsent = false
                Task { await generate() }
            }
        }
        .sheet(item: $dateField) { field in
            let current = field == .birth ? profile.birthDate : profile.marriageDate
            let years = field == .birth ? -30 : -4
            let defaultDate = Calendar.current.date(byAdding: .year, value: years, to: Date()) ?? Date()
            DateSelection(language: language, selected: current ?? defaultDate, minimum: field == .marriage ? profile.birthDate : nil) { date in
                if field == .birth { profile.birthDate = date } else { profile.marriageDate = date }
            }
        }
        .navigationDestination(item: $finished) { ReportScreen(reading: $0, language: language) }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            selection = nil
            analysisTask?.cancel()
            let capturedSide = side
            let partner = takingSecond
            analyzing = true
            message = ""
            analysisTask = Task {
                do {
                    guard let bytes = try await item.loadTransferable(type: Data.self) else { throw ScanError.image }
                    try await consume(bytes, side: capturedSide, partner: partner)
                } catch {
                    if !Task.isCancelled { message = PalmAPI.message(error, language) }
                }
                if !Task.isCancelled { analyzing = false }
            }
        }
        .onDisappear {
            analysisTask?.cancel()
            analyzing = false
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 16) {
            PalmTitle(title: side.title(language),
                      subtitle: relationship ? (takingSecond ? language.text("Partnerin", "Your partner") : language.text("Sen", "You")) :
                        language.text("Bileğin ve parmakların kadrajda olsun.", "Keep your wrist and fingertips in the frame."))
            Image(language == .tr ? "CaptureGuideTR" : "CaptureGuideEN")
                .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 390)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel(language.text("Avuç içini ışığa doğru açık tut.", "Hold your open palm in even light."))
            if analyzing {
                ProgressView(language.text("Avuç çizgileri inceleniyor…", "Reading palm lines…")).tint(PalmStyle.gold)
            }
            Button {
                Task { await openCamera() }
            } label: {
                Label(language.text("Fotoğraf çek", "Take photo"), systemImage: "camera")
            }
            .buttonStyle(PalmActionStyle())
            .disabled(analyzing)
            PhotosPicker(selection: $selection, matching: .images) {
                Label(language.text("Fotoğraf seç", "Choose photo"), systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .disabled(analyzing)
            Text(takingSecond
                 ? language.text("Partnerinin izniyle fotoğraf çek veya seç. Fotoğraflar bu cihazda işlenir.", "Take or choose photos with your partner’s permission. Photos are processed on this device.")
                 : language.text("Fotoğraflar bu cihazda işlenir.", "Photos are processed on this device."))
                .font(.footnote).foregroundStyle(PalmStyle.muted)
        }
    }

    private var profileFields: some View {
        VStack(alignment: .leading, spacing: 17) {
            PalmTitle(title: language.text("Okumanı kişiselleştir", "Personalize your reading"),
                      subtitle: language.text("İsim ve tarihler cihazında kalır.", "Names and dates stay on your device."))
            PalmCard {
                TextField(relationship ? language.text("Adın", "Your name") : language.text("Adın ve soyadın", "Your first and last name"), text: $profile.displayName)
                    .textContentType(.name)
                    .textFieldStyle(.roundedBorder)
                if relationship {
                    TextField(language.text("Partnerinin adı", "Your partner’s name"), text: $partnerName)
                        .textFieldStyle(.roundedBorder)
                } else {
                    dateButton(.birth, title: language.text("Doğum tarihi", "Date of birth"), value: profile.birthDate)
                    Toggle(language.text("Evliyim", "I’m married"), isOn: $profile.married)
                    if profile.married {
                        dateButton(.marriage, title: language.text("Evlilik tarihi", "Marriage date"), value: profile.marriageDate)
                    }
                }
            }
            Button(language.text("Ön izlemeyi aç", "Open preview")) { buildDraft() }
                .buttonStyle(PalmActionStyle())
                .disabled(!relationship && !profile.canAnalyze)
            Button(language.text("Fotoğrafları yeniden çek", "Retake photos"), action: reset)
                .buttonStyle(.bordered)
        }
    }

    private func dateButton(_ field: DateField, title: String, value: Date?) -> some View {
        Button {
            dateField = field
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: language.locale))
                     ?? language.text("Seç", "Select"))
                    .foregroundStyle(PalmStyle.gold)
            }.frame(minHeight: 37)
        }.buttonStyle(.plain)
    }

    private func preview(_ draft: PendingReport) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            PalmTitle(title: relationship ? language.text("Ortak okumanız", "Your shared reading") : language.text("El haritan", "Your palm map"),
                      subtitle: draft.names.joined(separator: " & "))
            if let personal = draft.personal {
                PalmCard { Text(personal.previewAnchor).font(.body).fixedSize(horizontal: false, vertical: true) }
                PalmTraces(hands: draft.hands, language: language)
                ForEach(personal.futureFactors.filter { $0.year != nil }) { factor in
                    PalmCard {
                        Text(factor.title).font(.subheadline)
                        if let year = factor.year {
                            Text(String(year)).font(.system(.title2, design: .serif, weight: .semibold)).foregroundStyle(PalmStyle.gold)
                        }
                    }
                }
            }
            if let relationship = draft.relationship {
                PalmCard {
                    let titles = ReadingEngine.relationshipTitles(language)
                    ForEach(relationship.sections) { section in
                        Label(titles[section.code] ?? section.code, systemImage: "heart.text.square")
                    }
                }
            }
            Button(language.text("Tam raporu aç", "Open full reading")) { requestGeneration(reward: false) }
                .buttonStyle(PalmActionStyle()).disabled(readings.working)
            if commerce.entitlement.rewardCredits > 0 {
                Button(language.text("Reklamdan kazandığım hakkı kullan", "Use an ad-earned credit")) { requestGeneration(reward: true) }
                    .buttonStyle(.bordered).disabled(readings.working)
            }
            NavigationLink(language.text("Ücretler ve paketler", "Pricing and plans")) { ShopScreen(language: language) }
                .buttonStyle(.bordered)
            if readings.working { ProgressView(language.text("Rapor hazırlanıyor…", "Preparing your report…")) }
            Button(language.text("Yeni fotoğraflarla başla", "Start with new photos"), action: reset)
                .buttonStyle(.plain).disabled(readings.working)
        }
    }

    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            message = language.text("Bu cihazda kamera açılamıyor. Bir fotoğraf seçebilirsin.", "The camera isn’t available on this device. You can choose a photo.")
            return
        }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        if granted { camera = true }
        else { message = language.text("Kamerayı iPhone ayarlarından açabilir veya fotoğraf seçebilirsin.",
                                       "You can enable the camera in iPhone Settings or choose a photo.") }
    }

    private func start(_ data: Data) {
        let capturedSide = side
        let partner = takingSecond
        analysisTask?.cancel()
        analyzing = true
        message = ""
        analysisTask = Task {
            do { try await consume(data, side: capturedSide, partner: partner) }
            catch { if !Task.isCancelled { message = PalmAPI.message(error, language) } }
            if !Task.isCancelled { analyzing = false }
        }
    }

    private func consume(_ data: Data, side: PalmSide, partner: Bool) async throws {
        let digest = Data(SHA256.hash(data: data))
        guard !fingerprints.contains(digest) else { throw ScanError.repeated }
        let reading = try await PalmVision.shared.read(data, side: side)
        try Task.checkCancellation()
        fingerprints.insert(digest)
        if partner { second.append(reading) } else { first.append(reading) }
    }

    private func buildDraft() {
        do {
            let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if relationship {
                let context = try ReadingEngine.relationship(first: first, second: second, language: language)
                let names = [name.isEmpty ? language.text("Sen", "You") : String(name.prefix(90)),
                             partnerName.isEmpty ? language.text("Partnerin", "Your partner") : String(partnerName.prefix(90))]
                draft = PendingReport(id: UUID(), personal: nil, relationship: context, names: names, hands: [], rewardOnly: false)
            } else {
                let context = try ReadingEngine.personal(hands: first, profile: profile, language: language)
                draft = PendingReport(id: UUID(), personal: context, relationship: nil, names: [name], hands: first, rewardOnly: false)
            }
            message = ""
        } catch { message = PalmAPI.message(error, language) }
    }

    private func requestGeneration(reward: Bool) {
        guard account.uid != nil else { showAccount = true; return }
        rewardOnly = reward
        showConsent = true
    }

    private func generate() async {
        guard let uid = account.uid, let draft else { return }
        message = ""
        do {
            let value = PendingReport(id: draft.id, personal: draft.personal, relationship: draft.relationship,
                                      names: draft.names, hands: draft.hands, rewardOnly: rewardOnly)
            finished = try await readings.finish(value, uid: uid)
            try? await commerce.refresh(uid)
        } catch { message = PalmAPI.message(error, language) }
    }

    private func reset() {
        analysisTask?.cancel()
        analyzing = false
        first = []
        second = []
        fingerprints = []
        profile = PalmProfile()
        partnerName = ""
        draft = nil
        message = ""
    }
}

struct AIConsent: View {
    let language: PalmLanguage
    let relationship: Bool
    let accept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PalmScreen {
                PalmTitle(title: language.text("Rapor için veri paylaşımı", "Sharing data for your report"), subtitle: "")
                Text(relationship
                     ? language.text("İki avuçtan çıkarılan ilişki bulguları, rapor metnini oluşturmak için PalmMap sunucusu üzerinden OpenAI ile paylaşılır. İsimler ve fotoğraflar cihazında kalır.",
                                     "Relationship findings derived from the two palm maps are sent through PalmMap’s server to OpenAI to write the report. Names and photos stay on your device.")
                     : language.text("El bulguların, yaşın ve seçilen yıl kartları, rapor metnini oluşturmak için PalmMap sunucusu üzerinden OpenAI ile paylaşılır. Fotoğraflar, isim ve doğum tarihi cihazında kalır.",
                                     "Palm findings, your age and selected year cards are sent through PalmMap’s server to OpenAI to write the report. Photos, your name and full date of birth stay on your device."))
                if relationship {
                    Text(language.text("Devam ederek partnerinin de bu paylaşıma onay verdiğini belirtirsin.",
                                       "By continuing, you confirm that your partner agreed to this sharing."))
                        .font(.footnote).foregroundStyle(PalmStyle.muted)
                }
                Button(language.text("Onayla ve raporu oluştur", "Allow and create report"), action: accept)
                    .buttonStyle(PalmActionStyle())
                Button(language.text("Vazgeç", "Cancel")) { dismiss() }.buttonStyle(.bordered)
            }
        }
    }
}

private struct DateSelection: View {
    let language: PalmLanguage
    @State var selected: Date
    let minimum: Date?
    let choose: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PalmScreen {
                let earliest = minimum ?? Calendar.current.date(byAdding: .year, value: -111, to: Date()) ?? Date()
                DatePicker(language.text("Tarih", "Date"), selection: $selected, in: earliest...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel).labelsHidden()
                Button(language.text("Tarihi kullan", "Use date")) {
                    choose(selected)
                    dismiss()
                }.buttonStyle(PalmActionStyle())
            }
        }
        .onAppear { if let minimum, selected < minimum { selected = minimum } }
    }
}

private struct PalmCamera: UIViewControllerRepresentable {
    let complete: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.cameraFlashMode = .off
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let complete: (Data?) -> Void
        init(complete: @escaping (Data?) -> Void) { self.complete = complete }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, image.size.width > 0, image.size.height > 0 else {
                complete(nil)
                return
            }
            let scale = min(1, 1800 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            complete(renderer.jpegData(withCompressionQuality: 0.92) { _ in image.draw(in: CGRect(origin: .zero, size: size)) })
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { complete(nil) }
    }
}

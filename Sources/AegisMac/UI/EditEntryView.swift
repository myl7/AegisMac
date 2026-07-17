import SwiftUI
import AppKit

// MARK: - OTP type for the editor

enum OtpType: String, CaseIterable, Identifiable {
    case totp, hotp, steam, yandex, motp
    var id: String { rawValue }
    var display: String {
        switch self {
        case .totp: return "TOTP"
        case .hotp: return "HOTP"
        case .steam: return "Steam"
        case .yandex: return "Yandex"
        case .motp: return "mOTP"
        }
    }
    var usesPeriod: Bool { self == .totp || self == .steam }
    var usesCounter: Bool { self == .hotp }
    var usesPin: Bool { self == .yandex || self == .motp }
    var fixedAlgo: String? {
        switch self {
        case .steam: return "SHA1"
        case .yandex: return "SHA256"
        case .motp: return "MD5"
        default: return nil
        }
    }
}

// MARK: - Edit / Add sheet

struct EditEntryView: View {
    /// nil = add a new entry; otherwise edit the given entry (keeping its uuid).
    let entry: VaultEntry?

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var type: OtpType = .totp
    @State private var issuer = ""
    @State private var name = ""
    @State private var note = ""
    @State private var secret = ""
    @State private var algo = "SHA1"
    @State private var digits = 6
    @State private var period = 30
    @State private var counter: Int64 = 0
    @State private var pin = ""
    @State private var favorite = false
    @State private var selectedGroups: Set<UUID> = []

    @State private var iconBytes: Data?    // downscaled PNG bytes
    @State private var validationError: String?

    private let uuid: UUID

    init(entry: VaultEntry?) {
        self.entry = entry
        self.uuid = entry?.uuid ?? UUID()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry == nil ? "New entry" : "Edit entry").font(.title2).bold().padding()
            Divider()
            ScrollView {
                Form {
                    Section {
                        Picker("Type", selection: $type) {
                            ForEach(OtpType.allCases) { Text($0.display).tag($0) }
                        }
                        .onChange(of: type) { _, newType in
                            if let fixed = newType.fixedAlgo { algo = fixed }
                            if newType == .steam { digits = 5 }
                            if newType == .yandex { digits = 8; period = 30 }
                            if newType == .motp { period = 10; digits = 6 }
                        }
                        TextField("Issuer", text: $issuer)
                        TextField("Account name", text: $name)
                        TextField("Note", text: $note)
                    }

                    Section("Secret") {
                        TextField("Secret (Base32)", text: $secret)
                            .font(.system(.body, design: .monospaced))
                        if type.usesPin {
                            SecureField("PIN", text: $pin)
                        }
                    }

                    Section("Algorithm") {
                        Picker("Hash", selection: $algo) {
                            ForEach(["SHA1", "SHA256", "SHA512", "MD5"], id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(type.fixedAlgo != nil)

                        Stepper("Digits: \(digits)", value: $digits, in: 1...10)
                            .disabled(type == .steam || type == .yandex)

                        if type.usesPeriod {
                            Stepper("Period: \(period) s", value: $period, in: 1...300)
                        }
                        if type.usesCounter {
                            HStack {
                                Text("Counter")
                                Spacer()
                                TextField("Counter", value: $counter, format: .number)
                                    .frame(width: 100).multilineTextAlignment(.trailing)
                            }
                        }
                    }

                    Section {
                        Toggle("Favorite", isOn: $favorite)
                        iconRow
                        if !app.allGroups.isEmpty {
                            groupsPicker
                        }
                    }

                    if let err = validationError {
                        Text(err).foregroundColor(palette.errorColor)
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 620)
        .background(palette.backgroundColor)
        .onAppear(perform: prefill)
    }

    // MARK: Icon

    @ViewBuilder private var iconRow: some View {
        HStack {
            Text("Icon")
            Spacer()
            EntryIconView(iconData: iconBytes, issuer: issuer, name: name, size: 40)
            Button("Choose…") { chooseIcon() }
            if iconBytes != nil {
                Button("Remove") { iconBytes = nil }
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            iconBytes = IconHelper.pngData(fromImageAt: url)
        }
    }

    // MARK: Groups

    @ViewBuilder private var groupsPicker: some View {
        VStack(alignment: .leading) {
            Text("Groups").font(.caption).foregroundColor(palette.onSurfaceDimColor)
            ForEach(app.allGroups, id: \.uuid) { group in
                Toggle(group.name, isOn: Binding(
                    get: { selectedGroups.contains(group.uuid) },
                    set: { on in
                        if on { selectedGroups.insert(group.uuid) } else { selectedGroups.remove(group.uuid) }
                    }
                ))
            }
        }
    }

    // MARK: Prefill from existing entry

    private func prefill() {
        guard let entry = entry else { return }
        issuer = entry.issuer
        name = entry.name
        note = entry.note
        favorite = entry.favorite
        selectedGroups = entry.groups
        iconBytes = entry.icon?.bytes

        let info = entry.info
        secret = Base32.encode(info.secret)
        algo = info.algorithm
        digits = info.digits
        switch info.typeId {
        case "hotp": type = .hotp
        case "steam": type = .steam
        case "yandex": type = .yandex
        case "motp": type = .motp
        default: type = .totp
        }
        if let totp = info as? TotpInfo { period = totp.period }
        if let hotp = info as? HotpInfo { counter = hotp.counter }
        if let motp = info as? MotpInfo { pin = motp.pin ?? "" }
        if let yandex = info as? YandexInfo { pin = yandex.pin ?? "" }
    }

    // MARK: Save (build JSON, validate, round-trip through the model)

    private func save() {
        validationError = nil
        let cleanSecret = secret.uppercased().filter { !$0.isWhitespace }

        // Validate the Base32 secret.
        do { _ = try Base32.decode(cleanSecret) }
        catch { validationError = "Invalid Base32 secret"; return }

        if type.usesPin && pin.isEmpty {
            validationError = "A PIN is required for \(type.display) entries"
            return
        }

        // Build the info JSON.
        var infoObj: JSONObject = [
            "secret": cleanSecret,
            "algo": type.fixedAlgo ?? algo,
            "digits": digits
        ]
        if type.usesPeriod { infoObj["period"] = period }
        if type == .yandex || type == .motp { infoObj["period"] = period }
        if type.usesCounter { infoObj["counter"] = NSNumber(value: counter) }
        if type.usesPin { infoObj["pin"] = pin }

        // Build the entry JSON.
        var obj: JSONObject = [
            "type": type.rawValue,
            "uuid": uuid.uuidString.lowercased(),
            "name": name,
            "issuer": issuer,
            "note": note,
            "favorite": favorite,
            "info": infoObj,
            "groups": selectedGroups.map { $0.uuidString.lowercased() }
        ]
        if let iconBytes = iconBytes {
            let mime = "image/png"
            obj["icon"] = iconBytes.base64EncodedString()
            obj["icon_mime"] = mime
            obj["icon_hash"] = IconHelper.hexLower(IconHelper.hash(mime: mime, bytes: iconBytes))
        } else {
            obj["icon"] = NSNull()
        }

        do {
            let built = try VaultEntry.fromJson(obj)
            if entry == nil {
                app.addEntry(built)
            } else {
                app.updateEntry(built)
            }
            dismiss()
        } catch {
            validationError = (error as? AegisError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Assign groups sheet

struct AssignGroupsView: View {
    let entry: VaultEntry
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var selected: Set<UUID> = []
    @State private var newGroupName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign groups").font(.title2).bold()
            if app.allGroups.isEmpty {
                Text("No groups yet.").foregroundColor(palette.onSurfaceDimColor)
            } else {
                ForEach(app.allGroups, id: \.uuid) { group in
                    Toggle(group.name, isOn: Binding(
                        get: { selected.contains(group.uuid) },
                        set: { on in
                            if on { selected.insert(group.uuid) } else { selected.remove(group.uuid) }
                        }
                    ))
                }
            }
            Divider()
            HStack {
                TextField("New group", text: $newGroupName)
                Button("Add") {
                    let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { app.addGroup(name: trimmed); newGroupName = "" }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    app.setGroups(selected, for: entry)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(palette.backgroundColor)
        .onAppear { selected = entry.groups }
    }
}

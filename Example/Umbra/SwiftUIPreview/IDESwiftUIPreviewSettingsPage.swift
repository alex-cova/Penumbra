import SwiftUI

extension IDEPreferencesDomain {
    static let swiftUIPreview = IDEPreferencesDomain(
        id: "swiftUIPreview", title: "SwiftUI Preview", symbol: "eye",
        searchTerms: ["preview", "canvas", "simulator", "ios", "device", "runtime", "idle", "xcode", "iphone", "ipad"]
    )
}

/// The devices Umbra created for iOS previews, as Settings lists them. Reads and removes through
/// the simulator service, which refuses a device a preview is using.
@MainActor
@Observable
final class IDESimulatorDevicesModel {
    private(set) var devices: [IDESimulatorOwnDevice] = []
    private(set) var isLoading = false
    private(set) var message: String?
    @ObservationIgnored private let service: IDESimulatorService

    init(service: IDESimulatorService = .shared) {
        self.service = service
    }

    var totalBytes: Int64 { devices.compactMap(\.bytes).reduce(0, +) }

    func reload() async {
        isLoading = true
        let listed = await service.ownDevices()
        devices = listed
        isLoading = false
        // Sizes take a walk over each device's folder: after the list is on screen.
        let udids = listed.map(\.udid)
        let sizes = await Task.detached(priority: .utility) { udids.map { IDESimulatorService.sizeOnDisk(udid: $0) } }.value
        for (index, udid) in udids.enumerated() {
            if let position = devices.firstIndex(where: { $0.udid == udid }) { devices[position].bytes = sizes[index] }
        }
    }

    func remove(_ udids: [String]) async {
        let failures = await service.removeOwnDevices(udids: udids)
        message = failures.isEmpty ? nil : failures.values.sorted().joined(separator: "\n")
        await reload()
    }

    func removeAll() async {
        await remove(devices.filter { !$0.isInUse }.map(\.udid))
    }
}

/// Settings ▸ SwiftUI Preview: both hosts' idle time, the simulator's start and device menu, and the
/// devices Umbra created.
struct IDESwiftUIPreviewSettingsPage: View {
    @AppStorage(IDESwiftUIPreviewSettings.idleMinutesKey) private var idleMinutes = IDESwiftUIPreviewSettings.defaultIdleMinutes
    @AppStorage(IDESwiftUIPreviewSettings.startsSimulatorWithBuildKey) private var startsWithBuild = true
    @AppStorage(IDESwiftUIPreviewSettings.offersPhonesKey) private var offersPhones = true
    @AppStorage(IDESwiftUIPreviewSettings.offersTabletsKey) private var offersTablets = true
    @State private var model = IDESimulatorDevicesModel()
    @State private var confirmsRemoveAll = false

    var body: some View {
        IDESettingsSection(
            "Idle",
            footer: "A preview nobody has used for this long stops its host and keeps the last frame; Refresh starts it again "
                + "without a build. A simulator device Umbra started is shut down after the same time with no preview using it, "
                + "and when Umbra quits. 0 keeps them until the panel is closed."
        ) {
            IDEPreferencesIntStepper(
                title: "Stop an Unused Preview After", value: $idleMinutes,
                range: IDESwiftUIPreviewSettings.idleMinutesRange, step: 5, valueWidth: 72,
                valueSuffix: idleMinutes == 0 ? " (never)" : " min"
            )
        }

        IDESettingsSection(
            "iOS Simulator",
            footer: "An iOS target is previewed in the iOS Simulator, on a device of its own that Umbra creates; "
                + "your own devices and their apps are never touched."
        ) {
            Picker("Start the Simulator", selection: $startsWithBuild) {
                Text("While the project builds").tag(true)
                Text("After the build").tag(false)
            }
            IDESettingsToggle("Offer iPhones", isOn: $offersPhones)
            IDESettingsToggle("Offer iPads", isOn: $offersTablets)
            HStack {
                Button("Open Xcode") { Task { await IDEXcodeLauncher.openSelectedXcode() } }
                Text("Runtimes are installed in Xcode ▸ Settings ▸ Components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        IDESettingsSection(
            "Devices Umbra Created",
            footer: model.devices.isEmpty ? nil : "Total \(Self.format(model.totalBytes)). A removed device is made again, empty, by the next iOS preview."
        ) {
            if model.devices.isEmpty {
                Text(model.isLoading ? "Looking…" : "None.").foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name.replacingOccurrences(of: IDESimulatorCatalog.deviceNamePrefix, with: ""))
                        Text(Self.detail(of: device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { Task { await model.remove([device.udid]) } }
                        .disabled(device.isInUse)
                        .help(device.isInUse ? "A preview is using this device." : "Delete this device and its data.")
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Refresh") { Task { await model.reload() } }
                Button("Remove All…") { confirmsRemoveAll = true }
                    .disabled(model.devices.allSatisfy(\.isInUse))
            }
        }
        .task { await model.reload() }
        .confirmationDialog("Remove the devices Umbra created?", isPresented: $confirmsRemoveAll) {
            Button("Remove All", role: .destructive) { Task { await model.removeAll() } }
        } message: {
            Text("Their data goes with them. Devices a preview is using are kept.")
        }

        IDESettingsSection(
            "About This Feature",
            footer: "A preview builds your project and runs its code in a process of its own, and an iOS preview runs it in the "
                + "iOS Simulator, which shares this Mac's file system and network. It needs a build of Umbra that is not "
                + "sandboxed, so it is not part of a Mac App Store build."
        ) {
            EmptyView()
        }
    }

    private static func detail(of device: IDESimulatorOwnDevice) -> String {
        var parts = [device.runtimeName]
        parts.append(device.isAvailable ? device.state : "Unavailable: its runtime was removed")
        if let bytes = device.bytes { parts.append(format(bytes)) }
        if device.isInUse { parts.append("in use") }
        return parts.joined(separator: " · ")
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Opens the Xcode `xcode-select` points at.
enum IDEXcodeLauncher {
    @MainActor
    static func openSelectedXcode(runner: any IDESwiftUIPreviewProcessRunning = IDESwiftUIPreviewSubprocessRunner()) async {
        let result = await runner.run(
            executable: "/usr/bin/xcode-select", arguments: ["-p"], workingDirectory: nil, onOutput: { _ in }
        )
        let developer = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = developer.range(of: "/Contents/Developer"),
           FileManager.default.fileExists(atPath: String(developer[..<range.lowerBound])) {
            NSWorkspace.shared.open(URL(fileURLWithPath: String(developer[..<range.lowerBound])))
        } else if let url = URL(string: "https://apps.apple.com/app/xcode/id497799835") {
            NSWorkspace.shared.open(url)
        }
    }
}

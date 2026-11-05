import Foundation
import SwiftUI

/// Python in Umbra's chrome. The intelligence is `pylsp` through ``IDEPythonServer`` (there is
/// no native Python index), so the module only carries the server definition and its Settings
/// page; everything else is the per-module default.
struct IDEPythonModule: IDELanguageModule {
    static let id = "python"
    var id: String { Self.id }

    var languageServers: [IDELanguageServerDefinition] { [IDEPythonServer.definition()] }

    var preferencePanes: [IDEPreferencesPane] {
        [IDEPreferencesPane(domain: .python) { _, _ in AnyView(IDEPythonServerSettings()) }]
    }
}

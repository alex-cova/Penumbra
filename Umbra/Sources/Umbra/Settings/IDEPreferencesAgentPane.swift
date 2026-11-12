import Penumbra
import SwiftUI

/// Settings ▸ Agent: the same form as the agent panel's sheet, plus the limits and protected files.
struct IDEPreferencesAgentPane: View {
    let agent: IDEAgentController
    @State private var isModelsPresented = false

    var body: some View {
        IDEAgentSettingsView(
            settings: agent.settings, agent: agent, isFullPane: true, width: nil,
            manageModels: { isModelsPresented = true })
            .sheet(isPresented: $isModelsPresented) { IDELocalModelsView(store: .shared, settings: agent.settings) }
    }
}

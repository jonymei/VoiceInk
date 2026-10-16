import SwiftUI

struct CustomDecisionModelsSection: View {
    @ObservedObject private var manager = CustomDecisionModelManager.shared
    let onEdit: (CustomDecisionModel?) -> Void
    @State private var deleting: CustomDecisionModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom Decision Models").font(.system(size: 15, weight: .semibold))
                Spacer()
                AddIconButton(helpText: "Add decision model") {
                    onEdit(nil)
                }
            }
            if manager.models.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 32)).symbolRenderingMode(.hierarchical)
                    Text("No Custom Decision Models").font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 20)
                .background(ProviderSurface(cornerRadius: 10))
            }
            ForEach(manager.models) { model in
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.system(size: 13, weight: .semibold))
                        Text(model.model).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { onEdit(model) } label: { Image(systemName: "pencil") }
                    Button { deleting = model } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless).padding(14)
                .background(ProviderSurface(cornerRadius: 10))
            }
        }
        .alert("Delete Custom Decision Model?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { manager.remove(deleting) }
                deleting = nil
            }
        }
    }
}

struct CustomDecisionModelEditor: View {
    let model: CustomDecisionModel?
    @ObservedObject var manager: CustomDecisionModelManager
    let onClose: () -> Void
    @State private var name = ""
    @State private var endpoint = "https://api.example.com/v1/systemone"
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var format = DecisionAPIFormat.systemOne
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        QuickPanelScaffold {
            ScrollView {
              VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 12) {
                TextField("Display Name", text: $name)
                Picker("API Format", selection: $format) {
                    ForEach(DecisionAPIFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("API Endpoint", text: $endpoint)
                TextField("Model ID", text: $modelName)
                SecureField("API Key", text: $apiKey)
                }
                .textFieldStyle(.roundedBorder)
                .padding(12).background(ProviderSurface(cornerRadius: 10))
                if let status { Text(status).font(.caption).textSelection(.enabled) }
                HStack {
                Button("Test") { testConnection() }.disabled(testing || !canSave)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                }
              }
              .padding(.horizontal, 20).padding(.top, 76).padding(.bottom, 20)
            }
        } header: {
            AppPanelHeader(title: "Custom Decision Model", onClose: onClose)
        } footer: {
            HStack {
                Button("Cancel") { onClose() }
                Spacer()
                Button("Save") {
                    let config = configuration
                    if manager.save(config, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        onClose()
                    } else { status = String(localized: "Unable to save. Check the HTTPS endpoint, model ID and API key.") }
                }
                .disabled(testing || !canSave).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).frame(height: QuickPanelMetrics.footerHeight)
        }
        .onAppear {
            if let model {
                name = model.name; endpoint = model.endpoint; modelName = model.model; format = model.format
                apiKey = APIKeyManager.shared.getCustomAIProviderAPIKey(forProviderId: model.id) ?? ""
            }
        }
    }

    private var configuration: CustomDecisionModel {
        CustomDecisionModel(id: model?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines), format: format)
    }

    private var canSave: Bool {
        !configuration.name.isEmpty && !configuration.model.isEmpty && !apiKey.isEmpty
            && URL(string: configuration.endpoint)?.scheme == "https"
    }

    private func testConnection() {
        let config = configuration
        guard let url = URL(string: config.endpoint) else { return }
        let key = apiKey
        testing = true
        status = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                _ = try await BailianDecisionClient().needsPolish(
                    text: "We meet tomorrow at three.", instructions: "Clean up this dictation.",
                    apiKey: key, endpoint: url, model: config.model, format: config.format)
                status = String(localized: "Test successful")
            } catch { status = error.localizedDescription }
        }
    }
}

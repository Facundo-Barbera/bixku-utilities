import BixkuDock
import BixkuDockSettings
import SwiftUI

/// Form editor for the selected mode: identity, dock layout, notification policy
/// and transitions. Fields the form does not show (attention rules, notification
/// rules) are kept as they are and can be edited in the JSON view.
struct ModeFormView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let form: ModeForm

    var body: some View {
        Form {
            identitySection
            dockSection
            notificationsSection
            transitionsSection
        }
        .formStyle(.grouped)
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<ModeForm, Value>, key: String) -> Binding<Value> {
        Binding(
            get: { (viewModel.form ?? form)[keyPath: keyPath] },
            set: { newValue in viewModel.editForm(key: key) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Binding to a field of the transition at `index`; tolerates the index
    /// disappearing while SwiftUI still holds the binding (a row was just removed).
    private func transitionBinding<Value>(
        _ index: Int,
        _ keyPath: WritableKeyPath<TransitionForm, Value>
    ) -> Binding<Value> {
        let key = "transition\(index).\(keyPath.hashValue)"
        return Binding(
            get: {
                let transitions = (viewModel.form ?? form).transitions
                return transitions.indices.contains(index) ? transitions[index][keyPath: keyPath] : TransitionForm()[keyPath: keyPath]
            },
            set: { newValue in
                viewModel.editForm(key: key) {
                    if $0.transitions.indices.contains(index) { $0.transitions[index][keyPath: keyPath] = newValue }
                }
            }
        )
    }

    // MARK: Sections

    private var identitySection: some View {
        Section("Mode") {
            TextField("Name", text: binding(\.name, key: "name"))
            TextField("Identifier", text: binding(\.id, key: "id"))
                .disabled(!viewModel.isNewMode)
                .help(viewModel.isNewMode
                    ? "Lowercase letters, digits and hyphens. It names the file the mode is stored in."
                    : "The identifier of a saved mode cannot change. Duplicate the mode to use another one.")
            HStack {
                TextField("Symbol", text: binding(\.symbol, key: "symbol"))
                Image(systemName: form.symbol)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Menu("Suggestions") {
                    ForEach(ModeTemplates.suggestedSymbols, id: \.self) { symbol in
                        Button {
                            viewModel.editForm(key: "symbol-pick") { $0.symbol = symbol }
                        } label: {
                            Label(symbol, systemImage: symbol)
                        }
                    }
                }
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: binding(\.summary, key: "summary"))
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("Shown to you and given to the model as the mode's intent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dockSection: some View {
        Section("Dock") {
            ListEditor(
                title: "Prioritized apps",
                hint: "Bundle identifiers shown first, in order. One per line.",
                items: binding(\.prioritized, key: "prioritized")
            )
            ListEditor(
                title: "Hidden apps",
                hint: "Bundle identifiers to hide. `com.example.*` matches a prefix. One per line.",
                items: binding(\.hidden, key: "hidden")
            )
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Picker("When nothing else matches", selection: binding(\.defaultAction, key: "default-action")) {
                ForEach(NotificationAction.allCases, id: \.self) { action in
                    Text(Self.label(for: action)).tag(action)
                }
            }
            Toggle("Always deliver from the app in front", isOn: binding(\.allowFromFocusedApp, key: "focused-app"))
            Toggle("Let time-sensitive notifications through", isOn: binding(\.honorTimeSensitive, key: "time-sensitive"))
            ListEditor(
                title: "Urgent keywords",
                hint: "A notification containing one of these is always delivered. One per line.",
                items: binding(\.urgentKeywords, key: "urgent-keywords")
            )
            Text("Per-app rules and exceptions are edited in the JSON view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transitionsSection: some View {
        Section {
            ForEach(Array(form.transitions.indices), id: \.self) { index in
                TransitionEditor(
                    trigger: transitionBinding(index, \.trigger),
                    apps: transitionBinding(index, \.apps),
                    categories: transitionBinding(index, \.categories),
                    titleKeywords: transitionBinding(index, \.titleKeywords),
                    urlHosts: transitionBinding(index, \.urlHosts),
                    secondsText: transitionBinding(index, \.secondsText),
                    from: transitionBinding(index, \.from),
                    priorityText: transitionBinding(index, \.priorityText),
                    onRemove: {
                        viewModel.editForm(key: "remove-transition") {
                            if $0.transitions.indices.contains(index) { $0.transitions.remove(at: index) }
                        }
                    }
                )
            }
            Button {
                viewModel.editForm(key: "add-transition") { $0.transitions.append(TransitionForm()) }
            } label: {
                Label("Add rule", systemImage: "plus")
            }
        } header: {
            Text("Switch to this mode automatically")
        } footer: {
            Text("The first rule that holds for its duration switches to this mode. Higher priority wins when several rules fire.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func label(for action: NotificationAction) -> String {
        switch action {
        case .allow: return "Deliver now"
        case .hold: return "Hold until the mode ends"
        case .summarize: return "Fold into the digest"
        case .silence: return "Silence"
        }
    }
}

/// One automatic-entry rule.
private struct TransitionEditor: View {
    @Binding var trigger: ModeTrigger
    @Binding var apps: [String]
    @Binding var categories: [ActivityCategory]
    @Binding var titleKeywords: [String]
    @Binding var urlHosts: [String]
    @Binding var secondsText: String
    @Binding var from: [String]
    @Binding var priorityText: String
    let onRemove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("When", selection: $trigger) {
                        Text("An activity is in front").tag(ModeTrigger.activity)
                        Text("I am idle").tag(ModeTrigger.idle)
                    }
                    Spacer()
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                }
                if trigger == .activity {
                    DisclosureGroup("Categories (\(categories.count))") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                            ForEach(ActivityCategory.allCases, id: \.self) { category in
                                Toggle(category.rawValue.capitalized, isOn: Binding(
                                    get: { categories.contains(category) },
                                    set: { isOn in
                                        if isOn {
                                            if !categories.contains(category) { categories.append(category) }
                                        } else {
                                            categories.removeAll { $0 == category }
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    ListEditor(title: "Apps", hint: "Bundle identifiers. One per line.", items: $apps)
                    ListEditor(title: "Window title contains", hint: "One per line.", items: $titleKeywords)
                    ListEditor(title: "Website hosts", hint: "For example github.com. One per line.", items: $urlHosts)
                }
                HStack {
                    TextField("For (seconds)", text: $secondsText)
                        .frame(maxWidth: 200)
                    TextField("Priority", text: $priorityText)
                        .frame(maxWidth: 140)
                }
                ListEditor(title: "Only from modes", hint: "Mode identifiers. Leave empty to switch from any mode.", items: $from)
            }
            .padding(4)
        }
    }
}

/// A multi-line text box editing a list of strings, one per line. It keeps its own
/// text while typing so a trailing newline is not swallowed, and follows the list
/// when it changes underneath (undo).
private struct ListEditor: View {
    let title: String
    let hint: String
    @Binding var items: [String]

    @State private var text: String

    init(title: String, hint: String, items: Binding<[String]>) {
        self.title = title
        self.hint = hint
        _items = items
        _text = State(initialValue: ListText.format(items.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { text },
                set: { newText in
                    text = newText
                    let parsed = ListText.parse(newText)
                    if parsed != items { items = parsed }
                }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 48, maxHeight: 96)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: items) { newItems in
            if ListText.parse(text) != newItems { text = ListText.format(newItems) }
        }
    }
}

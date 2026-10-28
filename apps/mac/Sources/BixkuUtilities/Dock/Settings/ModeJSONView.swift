import AppKit
import BixkuDock
import SwiftUI

/// The raw JSON of the selected mode with live validation. Edits that decode are
/// applied to the draft immediately; Save stays disabled while the text has problems.
struct ModeJSONView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            JSONTextView(text: Binding(
                get: { viewModel.jsonText },
                set: { viewModel.setJSONText($0) }
            ))
            Divider()
            IssueListView(issues: viewModel.issues, validMessage: "Valid mode document.")
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Validation problems in red, or a green confirmation when there are none.
struct IssueListView: View {
    let issues: [ModeValidationIssue]
    let validMessage: String

    var body: some View {
        if issues.isEmpty {
            Label(validMessage, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        Text("\(issue.path): \(issue.message)")
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .font(.callout)
                }
            }
        }
    }
}

/// A plain-text editor for code. Unlike SwiftUI's `TextEditor` it turns off smart
/// quotes, dashes and text replacement, which would silently corrupt JSON.
struct JSONTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

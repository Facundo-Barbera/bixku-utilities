import BixkuDock
import Foundation

/// The outcome of reading the raw JSON the user typed.
public struct ModeJSONResult: Sendable, Equatable {
    /// The decoded definition, or `nil` when the text is not a readable mode document
    /// (broken JSON, wrong types, missing required fields).
    public var definition: ModeDefinition?
    /// Everything wrong with the text: decoding problems, or validation issues of a
    /// definition that did decode.
    public var issues: [ModeValidationIssue]

    public var isValid: Bool {
        definition != nil && issues.isEmpty
    }
}

/// Reading and writing the raw JSON view of a mode, with the same checks the store
/// applies on save so problems show up while typing.
public enum ModeJSON {
    /// Pretty, key-sorted JSON of `definition`.
    public static func text(for definition: ModeDefinition) -> String {
        guard let data = try? JSONModeStore.encode(definition) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses and validates `text`.
    ///
    /// - Parameters:
    ///   - knownModes: ids a transition's `from` may reference, or `nil` to skip that check.
    ///   - lockedID: when editing an existing mode, its id; changing it in the text is
    ///     reported (it would silently create a second mode instead of renaming).
    public static func parse(_ text: String, knownModes: Set<ModeID>? = nil, lockedID: ModeID? = nil) -> ModeJSONResult {
        let definition: ModeDefinition
        do {
            definition = try ModeMigrator().decode(Data(text.utf8)).definition
        } catch let error as ModeDocumentError {
            return ModeJSONResult(definition: nil, issues: [ModeValidationIssue(path: "(document)", message: error.description)])
        } catch {
            return ModeJSONResult(definition: nil, issues: [ModeValidationIssue(path: "(document)", message: "\(error)")])
        }
        var issues = ModeValidator().issues(in: definition, knownModes: knownModes)
        if let lockedID, definition.id != lockedID {
            issues.insert(
                ModeValidationIssue(path: "id", message: "must stay '\(lockedID)'; duplicate the mode to use another id"),
                at: 0
            )
        }
        return ModeJSONResult(definition: definition, issues: issues)
    }
}

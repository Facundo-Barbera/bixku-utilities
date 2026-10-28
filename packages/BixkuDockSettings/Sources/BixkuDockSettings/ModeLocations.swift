import Foundation

/// Where the Dock keeps the user's mode documents. Always derived at runtime from
/// the user's own Application Support directory; nothing is hard-coded.
public enum ModeLocations {
    /// The app's folder name inside Application Support (shared with the module host).
    public static let appFolderName = "BixkuUtilities"

    /// `<Application Support>/BixkuUtilities/dock/modes`, or the same folder inside
    /// `dataDirectory` when the user configured one (`general.data_dir`).
    public static func modesDirectory(
        dataDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let root: URL
        if let dataDirectory {
            root = dataDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            root = base.appendingPathComponent(appFolderName, isDirectory: true)
        }
        return root
            .appendingPathComponent("dock", isDirectory: true)
            .appendingPathComponent("modes", isDirectory: true)
    }
}

import BixkuCore

/// The modules this build of the app ships with. Add new modules here.
enum KnownModules {
    @MainActor
    static func all() -> [ModuleRegistration] {
        let hello = HelloModule()
        return [
            ModuleRegistration(module: hello, ui: HelloModuleUI(module: hello)),
        ]
    }
}

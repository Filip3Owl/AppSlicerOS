import Foundation

/// Resolved once from the user's preferred languages, with English as the fallback.
private let localizedBundle: Bundle = {
    let languages = Bundle.preferredLocalizations(
        from: Bundle.module.localizations,
        forPreferences: Locale.preferredLanguages
    )
    return languages.first
        .flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }
        .flatMap(Bundle.init(path:)) ?? Bundle.module
}()

func L(_ key: String) -> String {
    localizedBundle.localizedString(forKey: key, value: nil, table: nil)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: arguments)
}

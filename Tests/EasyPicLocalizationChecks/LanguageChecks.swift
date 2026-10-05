import Foundation

@main
struct LanguageChecks {
    @MainActor static func main() throws {
        let domain = "EasyPic.LanguageChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppLanguageSettings(defaults: defaults)
        precondition(settings.language == .english, "Fresh settings must default to English")
        settings.language = .chinese
        precondition(defaults.string(forKey: L10n.preferenceKey) == "zh-Hans")
        precondition(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        precondition(AppLanguageSettings(defaults: defaults).language == .chinese)
        settings.language = .english
        precondition(AppLanguageSettings(defaults: defaults).language == .english)
        print("PASS · English default and persistent English/Chinese preference")

        for (key, english) in L10n.english {
            precondition(L10n.render(key, language: .english) == english)
            precondition(L10n.render(key, language: .chinese) == key)
            precondition(english.unicodeScalars.allSatisfy { !(0x3400...0x9FFF).contains($0.value) }, "Untranslated English entry: " + key)
        }
        print("PASS · Both languages cover all \(L10n.english.count) labels and app messages")

        precondition(L10n.render("硬度 {0}%", arguments: ["65"], language: .english) == "Hardness 65%")
        precondition(L10n.render("{0} 像素", arguments: ["file-{1}"], language: .english) == "file-{1} pixels")
        precondition(L10n.render("硬度 {0}%", arguments: ["65"], language: .chinese) == "硬度 65%")
        precondition(L10n.render("filename.png", language: .english) == "filename.png")
        print("PASS · Numeric substitutions and literal user content")
    }
}

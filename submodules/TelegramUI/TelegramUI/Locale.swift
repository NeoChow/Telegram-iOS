import Foundation
import TelegramPresentationData

private let systemLocaleRegionSuffix: String = {
    let identifier = Locale.current.identifier
    if let range = identifier.range(of: "_") {
        return String(identifier[range.lowerBound...])
    } else {
        return ""
    }
}()

let usEnglishLocale = Locale(identifier: "en_US")

func localeWithStrings(_ strings: PresentationStrings) -> Locale {
    let languageCode = strings.baseLanguageCode
    let code = languageCode + systemLocaleRegionSuffix
    return Locale(identifier: code)
}

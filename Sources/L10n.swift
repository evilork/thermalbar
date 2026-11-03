// L10n.swift - Russian and English strings. The exhaustive switch makes a missing translation
// a compile error. Formatting helpers keep numbers in the language's own style (1,5 vs 1.5).
import Foundation

enum Lang: String, Equatable {
    case ru
    case en

    static func resolve(_ pref: LanguagePref, preferred: [String] = Locale.preferredLanguages) -> Lang {
        switch pref {
        case .russian: return .ru
        case .english: return .en
        case .system:
            let first = preferred.first?.lowercased() ?? "en"
            return first.hasPrefix("ru") ? .ru : .en
        }
    }
}

enum K: CaseIterable {
    // Menu bar captions
    case capCPU, capGPU, capWatt, capMem, capFan
    // Panel status
    case statusCalm, statusWarm, statusHot, statusThrottling, statusMemory, statusGPUStuck, statusStarting
    // Tiles
    case tileCPU, tileGPU, tilePower, tileMemory, todayMax, pressure
    // Detail rows
    case rowFans, rowGPUClock, rowHeat, rowMemory, rowPowerSplit
    case gpuClockValue, memoryValue, swapNone
    case thermalNominal, thermalModerate, thermalHeavy, thermalCritical
    case lowPower
    // Hints
    case hintGPUStuck, hintThrottle, hintMemory, hintMemoryNoApp
    // Top apps
    case topApps, byCPU, byMemory, noData, webPages
    // Games
    case lastGame, noGameYet, gameNow, gameStats, gameThrottled, gameNoThrottle, gameGPUStuck
    // Footer
    case settings, quit
    // Units and durations
    case unitW, unitMHz, unitGB, unitRPM, durHM, durM, durLessMinute
    // Settings
    case settingsTitle, tabMenuBar, tabThresholds, tabAlerts, tabGeneral
    case showCPU, showGPU, showPower, showMemory, showFans, showLabels
    case layout, layoutSingle, layoutTwo, colorMode, colorWhenHot, colorAlways, menuBarPreviewNote
    case thresholdsNote, warnFrom, highFrom, criticalFrom
    case sectionCPU, sectionGPU, sectionPower, resetDefaults, memoryNote, fanNote
    case notifyMemory, notifyThrottle, notifyGPUStuck, notifyTest, notifyDenied, notifyNote
    case language, langSystem, interval, intervalValue, transparency, launchAtLogin, version, projectPage
    // Notifications
    case nMemoryTitle, nMemoryBody, nMemoryBodyNoApp, nThrottleTitle, nThrottleBody
    case nGPUStuckTitle, nGPUStuckBody, nTestTitle, nTestBody
}

struct Strings: Equatable {
    let lang: Lang

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func t(_ key: K) -> String {
        let ru = lang == .ru
        switch key {
        case .capCPU: return ru ? "ЦП" : "CPU"
        case .capGPU: return ru ? "ГП" : "GPU"
        case .capWatt: return ru ? "Вт" : "W"
        case .capMem: return ru ? "ПАМ" : "MEM"
        case .capFan: return ru ? "ВЕН" : "FAN"

        case .statusCalm: return ru ? "Всё спокойно" : "All calm"
        case .statusWarm: return ru ? "Тепло" : "Warm"
        case .statusHot: return ru ? "Горячо" : "Hot"
        case .statusThrottling: return ru ? "Mac снижает частоты" : "Mac is throttling"
        case .statusMemory: return ru ? "Мало памяти" : "Memory is tight"
        case .statusGPUStuck: return ru ? "Видеокарта на низкой частоте" : "GPU stuck at low clock"
        case .statusStarting: return ru ? "Читаю датчики…" : "Reading sensors…"

        case .tileCPU: return ru ? "Процессор" : "CPU"
        case .tileGPU: return ru ? "Видеокарта" : "GPU"
        case .tilePower: return ru ? "Питание" : "Power"
        case .tileMemory: return ru ? "Память" : "Memory"
        case .todayMax: return ru ? "сегодня до %@" : "today up to %@"
        case .pressure: return ru ? "нагрузка" : "pressure"

        case .rowFans: return ru ? "Вентиляторы" : "Fans"
        case .rowGPUClock: return ru ? "Частота ГП" : "GPU clock"
        case .rowHeat: return ru ? "Нагрев" : "Thermal state"
        case .rowMemory: return ru ? "Память" : "Memory"
        case .rowPowerSplit: return ru ? "Из них" : "Of which"
        case .gpuClockValue: return ru ? "%@ из %@ МГц · занята %@" : "%@ of %@ MHz · busy %@"
        case .memoryValue: return ru ? "%@ из %@ ГБ · подкачка %@" : "%@ of %@ GB · swap %@"
        case .swapNone: return ru ? "нет" : "none"
        case .thermalNominal: return ru ? "Норма" : "Normal"
        case .thermalModerate: return ru ? "Тепло, частоты могут снижаться" : "Warm, clocks may drop"
        case .thermalHeavy: return ru ? "Частоты снижены из-за нагрева" : "Clocks reduced by heat"
        case .thermalCritical: return ru ? "Сильный перегрев" : "Severe overheating"
        case .lowPower:
            return ru ? "Включён режим энергосбережения: игры и программы работают медленнее."
                      : "Low Power Mode is on: games and apps run slower."

        case .hintGPUStuck:
            return ru ? "Видеокарта загружена полностью, но работает на низкой частоте. Обычно помогает перезагрузка Mac."
                      : "The GPU is fully busy but stuck at a low clock. Restarting the Mac usually fixes it."
        case .hintThrottle:
            return ru ? "Mac снижает частоты из-за нагрева. Поставьте его на твёрдую поверхность и не закрывайте решётки."
                      : "Your Mac is slowing down to cool off. Keep it on a hard surface with the vents clear."
        case .hintMemory:
            return ru ? "Памяти не хватает, macOS сжимает её и пишет на диск. Больше всего занимает %@."
                      : "Memory is short, so macOS compresses and swaps. Using the most: %@."
        case .hintMemoryNoApp:
            return ru ? "Памяти не хватает, macOS сжимает её и пишет на диск. Закройте лишние программы."
                      : "Memory is short, so macOS compresses and swaps. Quit apps you do not need."

        case .topApps: return ru ? "Больше всего нагружают" : "Top apps"
        case .byCPU: return ru ? "Процессор" : "CPU"
        case .byMemory: return ru ? "Память" : "Memory"
        case .noData: return ru ? "Нет данных" : "No data"
        case .webPages: return ru ? "Веб-страницы" : "Web pages"

        case .lastGame: return ru ? "Последняя игра" : "Last game"
        case .noGameYet:
            return ru ? "Игр пока не было. Сессия начнётся сама, когда видеокарта загрузится игрой."
                      : "No games yet. A session starts by itself when a game loads the GPU."
        case .gameNow: return ru ? "Сейчас" : "Now"
        case .gameStats: return ru ? "ЦП до %@ · ГП до %@ · до %@ Вт" : "CPU up to %@ · GPU up to %@ · up to %@ W"
        case .gameThrottled: return ru ? "частоты снижались %@" : "throttled for %@"
        case .gameNoThrottle: return ru ? "без снижения частот" : "no throttling"
        case .gameGPUStuck: return ru ? "видеокарта застревала %@" : "GPU stuck for %@"

        case .settings: return ru ? "Настройки…" : "Settings…"
        case .quit: return ru ? "Выход" : "Quit"

        case .unitW: return ru ? "Вт" : "W"
        case .unitMHz: return ru ? "МГц" : "MHz"
        case .unitGB: return ru ? "ГБ" : "GB"
        case .unitRPM: return ru ? "об/мин" : "rpm"
        case .durHM: return ru ? "%d ч %d мин" : "%dh %dm"
        case .durM: return ru ? "%d мин" : "%d min"
        case .durLessMinute: return ru ? "меньше минуты" : "under a minute"

        case .settingsTitle: return ru ? "Настройки ThermalBar" : "ThermalBar Settings"
        case .tabMenuBar: return ru ? "Строка меню" : "Menu Bar"
        case .tabThresholds: return ru ? "Пороги" : "Thresholds"
        case .tabAlerts: return ru ? "Уведомления" : "Notifications"
        case .tabGeneral: return ru ? "Общие" : "General"
        case .showCPU: return ru ? "Температура процессора" : "CPU temperature"
        case .showGPU: return ru ? "Температура видеокарты" : "GPU temperature"
        case .showPower: return ru ? "Потребление, Вт" : "Power, W"
        case .showMemory: return ru ? "Нагрузка на память" : "Memory pressure"
        case .showFans: return ru ? "Вентиляторы" : "Fans"
        case .showLabels: return ru ? "Подписи (ЦП, ГП, ПАМ)" : "Labels (CPU, GPU, MEM)"
        case .layout: return ru ? "Вид" : "Layout"
        case .layoutSingle: return ru ? "В одну строку" : "Single line"
        case .layoutTwo: return ru ? "В две строки" : "Two lines"
        case .colorMode: return ru ? "Цвет цифр" : "Number color"
        case .colorWhenHot: return ru ? "Цветные только при нагреве" : "Colored only when hot"
        case .colorAlways: return ru ? "Всегда цветные" : "Always colored"
        case .menuBarPreviewNote:
            return ru ? "Изменения сразу видны в строке меню." : "Changes show up in the menu bar right away."
        case .thresholdsNote:
            return ru ? "Цифра становится оранжевой, потом красной, потом красной плашкой."
                      : "A number turns orange, then red, then a red badge."
        case .warnFrom: return ru ? "Оранжевый от" : "Orange from"
        case .highFrom: return ru ? "Красный от" : "Red from"
        case .criticalFrom: return ru ? "Плашка от" : "Badge from"
        case .sectionCPU: return ru ? "Процессор, °C" : "CPU, °C"
        case .sectionGPU: return ru ? "Видеокарта, °C" : "GPU, °C"
        case .sectionPower: return ru ? "Потребление, Вт" : "Power, W"
        case .resetDefaults: return ru ? "Вернуть значения для %@" : "Reset to defaults for %@"
        case .memoryNote:
            return ru ? "Память окрашивается по оценке самой macOS, как в Мониторинге системы."
                      : "Memory is colored by macOS's own pressure level, as in Activity Monitor."
        case .fanNote:
            return ru ? "Вентиляторы: оранжевый от 70% скорости, красный от 90%."
                      : "Fans: orange from 70% of max speed, red from 90%."
        case .notifyMemory: return ru ? "Памяти не хватает" : "Memory is running out"
        case .notifyThrottle: return ru ? "Mac снижает частоты из-за нагрева" : "Mac is throttling from heat"
        case .notifyGPUStuck: return ru ? "Видеокарта застряла на низкой частоте" : "GPU is stuck at a low clock"
        case .notifyTest: return ru ? "Проверить уведомление" : "Send a test notification"
        case .notifyDenied:
            return ru ? "Уведомления запрещены: Системные настройки → Уведомления → ThermalBar."
                      : "Notifications are off: System Settings → Notifications → ThermalBar."
        case .notifyNote:
            return ru ? "Не чаще раза в 20 минут для каждого вида." : "At most once every 20 minutes for each kind."
        case .language: return ru ? "Язык" : "Language"
        case .langSystem: return ru ? "Как в системе" : "System"
        case .interval: return ru ? "Обновлять каждые" : "Refresh every"
        case .intervalValue: return ru ? "%d с" : "%d s"
        case .transparency: return ru ? "Прозрачность панели" : "Panel transparency"
        case .launchAtLogin: return ru ? "Запускать при входе в систему" : "Open at login"
        case .version: return ru ? "Версия %@" : "Version %@"
        case .projectPage: return ru ? "Страница проекта" : "Project page"

        case .nMemoryTitle: return ru ? "Памяти не хватает" : "Memory is running out"
        case .nMemoryBody:
            return ru ? "macOS сжимает память и пишет на диск. Больше всего занимает %@."
                      : "macOS is compressing and swapping. Using the most: %@."
        case .nMemoryBodyNoApp:
            return ru ? "macOS сжимает память и пишет на диск. Закройте лишние программы."
                      : "macOS is compressing and swapping. Quit apps you do not need."
        case .nThrottleTitle: return ru ? "Mac снижает частоты" : "Your Mac is throttling"
        case .nThrottleBody:
            return ru ? "Из-за нагрева процессор и видеокарта работают медленнее. ЦП %@, ГП %@."
                      : "Heat is slowing the CPU and GPU down. CPU %@, GPU %@."
        case .nGPUStuckTitle: return ru ? "Видеокарта застряла на низкой частоте" : "GPU stuck at a low clock"
        case .nGPUStuckBody:
            return ru ? "Видеокарта загружена полностью, но работает на %@ из %@ МГц. Обычно помогает перезагрузка Mac."
                      : "The GPU is fully busy but runs at %@ of %@ MHz. Restarting the Mac usually fixes it."
        case .nTestTitle: return "ThermalBar"
        case .nTestBody: return ru ? "Уведомления работают." : "Notifications work."
        }
    }

    func f(_ key: K, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }

    var locale: Locale { Locale(identifier: lang == .ru ? "ru_RU" : "en_US") }

    /// Number with a fixed count of decimals in this language's style.
    func number(_ value: Double, decimals: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        let nf = NumberFormatter()
        nf.locale = locale
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = false
        nf.minimumFractionDigits = decimals
        nf.maximumFractionDigits = decimals
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }

    func temperature(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        return number(v) + "°"
    }

    func percent(_ fraction: Double?) -> String {
        guard let v = fraction else { return "—" }
        return number(v * 100) + "%"
    }

    func gigabytes(_ bytes: UInt64?) -> String {
        guard let b = bytes else { return "—" }
        let gb = Double(b) / 1_073_741_824
        return number(gb, decimals: gb < 10 ? 1 : 0)
    }

    func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return t(.durLessMinute) }
        let total = Int(seconds / 60)
        let h = total / 60
        let m = total % 60
        return h > 0 ? String(format: t(.durHM), h, m) : String(format: t(.durM), m)
    }
}

import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--dump") {
    let done = DispatchSemaphore(value: 0)
    let localOnly = arguments.contains("local")
    Task.detached {
        await DebugTools.dump(localOnly: localOnly)
        done.signal()
    }
    done.wait()
    exit(0)
}

if let index = arguments.firstIndex(of: "--icons"), arguments.count > index + 1 {
    let iconScale = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 1 : 1
    DebugTools.iconSheet(to: arguments[index + 1], iconScale: iconScale)
    exit(0)
}

if let index = arguments.firstIndex(of: "--panel"), arguments.count > index + 1 {
    MainActor.assumeIsolated {
        if arguments.contains("en") { Lang.setting = .en }
        if arguments.contains("fr") { Lang.setting = .fr }
        // « live » dessine les vraies données en cache ; « chatgpt » met en avant l'hebdo de ChatGPT.
        DebugTools.panel(
            to: arguments[index + 1], over: arguments.contains("over"), live: arguments.contains("live"),
            focus: arguments.contains("chatgpt") ? .chatgptWeekly : .claudeWeekly,
            surge: arguments.contains("surge")
        )
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--readme-assets"), arguments.count > index + 1 {
    MainActor.assumeIsolated {
        ReadmeAssets.generate(into: arguments[index + 1])
    }
    exit(0)
}

// Le code de premier niveau tourne sur le fil principal ; on le dit au compilateur.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

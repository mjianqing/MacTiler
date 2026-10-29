import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (works when Accessibility is granted).
final class HotKeyManager {
    enum Action: UInt32 {
        case retile = 1
        case prevStrategy = 2
        case nextStrategy = 3
        case strategy2 = 4
        case strategy3 = 5
        case strategy4 = 6
        case pause = 7
        case mirror = 8
    }

    var handler: ((Action) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if let action = Action(rawValue: hotKeyID.id) {
                DispatchQueue.main.async {
                    manager.handler?(action)
                }
            }
            return noErr
        }, 1, &eventType, userData, &eventHandler)

        // modifiers: control + option + command
        let mods = UInt32(controlKey | optionKey | cmdKey)

        register(Action.retile, keyCode: UInt32(kVK_ANSI_R), modifiers: mods)
        register(Action.prevStrategy, keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: mods)
        register(Action.nextStrategy, keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: mods)
        register(Action.strategy2, keyCode: UInt32(kVK_ANSI_2), modifiers: mods)
        register(Action.strategy3, keyCode: UInt32(kVK_ANSI_3), modifiers: mods)
        register(Action.strategy4, keyCode: UInt32(kVK_ANSI_4), modifiers: mods)
        register(Action.pause, keyCode: UInt32(kVK_ANSI_P), modifiers: mods)
        register(Action.mirror, keyCode: UInt32(kVK_ANSI_Backslash), modifiers: mods)
    }

    func stop() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register(_ action: Action, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D544C52), id: action.rawValue) // 'MTLR'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("MacTiler: failed to register hotkey \(action) status=\(status)")
        }
    }

    deinit {
        stop()
    }
}

import ClipboardHistory

extension ClipboardHistorySyncFileFailure {
    var presentationMessageKey: L10n.Key {
        switch self {
        case .network: .settingsClipboardSyncNetworkFailure
        case .quota: .settingsClipboardSyncQuotaFailure
        case .localStorage: .settingsClipboardSyncStorageFailure
        case .localFileAccessDenied: .settingsClipboardSyncFileAccessDenied
        case .sourceChanged: .settingsClipboardSyncSourceChanged
        case .corruptData: .settingsClipboardSyncCorruptData
        case .accessDenied: .settingsClipboardSyncAccessDenied
        case .accountChanged: .settingsClipboardSyncAccountChanged
        case .keyUnavailable: .settingsClipboardSyncWaitingForKey
        case .unavailable: .settingsClipboardSyncCapabilityUnavailable
        }
    }
}

extension ClipboardHistorySyncPhase {
    var presentationMessageKey: L10n.Key {
        switch self {
        case .disabled: .settingsClipboardSyncDisabled
        case .connecting: .settingsClipboardSyncConnecting
        case .waitingForAccount: .settingsClipboardSyncWaitingForAccount
        case .waitingForKey: .settingsClipboardSyncWaitingForKey
        case .keyLocked: .settingsClipboardSyncKeyLocked
        case .accessDenied: .settingsClipboardSyncAccessDenied
        case .capabilityUnavailable: .settingsClipboardSyncCapabilityUnavailable
        case .transferring: .settingsClipboardSyncTransferring
        case .upToDate: .settingsClipboardSyncUpToDate
        case .failed(let failure):
            switch failure {
            case .network: .settingsClipboardSyncNetworkFailure
            case .quota: .settingsClipboardSyncQuotaFailure
            case .localStorage: .settingsClipboardSyncStorageFailure
            case .localFileAccessDenied: .settingsClipboardSyncFileAccessDenied
            case .sourceChanged: .settingsClipboardSyncSourceChanged
            case .corruptData: .settingsClipboardSyncCorruptData
            case .recoveryRequired: .settingsClipboardSyncRecoveryRequired
            case .accountChanged: .settingsClipboardSyncAccountChanged
            case .unsupportedVersion: .settingsClipboardSyncUnsupportedVersion
            }
        }
    }
}

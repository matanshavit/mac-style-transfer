import Foundation
import Observation
import os
import Security
import SystemExtensions

@MainActor
@Observable
final class ExtensionManager: NSObject {
    enum State: Equatable {
        case idle
        case needsApproval
        case activated
        case needsReboot
        case failed(String)
        case requiresApplicationsFolder
    }

    private enum Action {
        case query
        case activate
        case deactivate
    }

    /// Ad-hoc builds (`make build`) have no team, and macOS refuses to install their camera extension.
    static let hasDeveloperTeam: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] is String
    }()

    private(set) var state: State = initialState

    @ObservationIgnored private var pendingActions: [ObjectIdentifier: Action] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.matanshavit.StyleCam", category: "extension")

    private static var initialState: State {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/") ? .idle : .requiresApplicationsFolder
    }

    func refresh() {
        submit(.propertiesRequest(forExtensionWithIdentifier: StyleCamIDs.extensionBundleID, queue: .main), action: .query)
    }

    func install() {
        submit(.activationRequest(forExtensionWithIdentifier: StyleCamIDs.extensionBundleID, queue: .main), action: .activate)
    }

    func uninstall() {
        submit(.deactivationRequest(forExtensionWithIdentifier: StyleCamIDs.extensionBundleID, queue: .main), action: .deactivate)
    }

    private func submit(_ request: OSSystemExtensionRequest, action: Action) {
        pendingActions[ObjectIdentifier(request)] = action
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionManager: @MainActor OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        logger.info("Replacing extension \(existing.bundleShortVersion) (\(existing.bundleVersion)) with \(ext.bundleShortVersion) (\(ext.bundleVersion))")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        pendingActions.removeValue(forKey: ObjectIdentifier(request))
        guard !pendingActions.values.contains(where: { $0 != .query }) else { return }
        if properties.contains(where: \.isAwaitingUserApproval) {
            state = .needsApproval
        } else if properties.contains(where: { $0.isEnabled && !$0.isUninstalling }) {
            state = .activated
        } else if properties.contains(where: \.isUninstalling) {
            state = .needsReboot
        } else {
            state = Self.initialState
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard let action = pendingActions.removeValue(forKey: ObjectIdentifier(request)), action != .query else { return }
        switch result {
        case .completed:
            state = action == .deactivate ? .idle : .activated
        case .willCompleteAfterReboot:
            state = .needsReboot
        @unknown default:
            state = .failed("Unknown result \(result.rawValue)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let action = pendingActions.removeValue(forKey: ObjectIdentifier(request))
        logger.error("System extension request failed: \(error.localizedDescription)")
        guard let action, action != .query else { return }
        if let error = error as? OSSystemExtensionError, error.code == .unsupportedParentBundleLocation {
            state = .requiresApplicationsFolder
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}

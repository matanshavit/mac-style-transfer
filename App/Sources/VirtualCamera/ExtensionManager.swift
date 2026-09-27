import Foundation
import Observation
import os
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
        case activate
        case deactivate
    }

    private(set) var state: State = isInApplicationsFolder ? .idle : .requiresApplicationsFolder

    @ObservationIgnored private var pendingActions: [ObjectIdentifier: Action] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.matanshavit.StyleCam", category: "extension")

    private static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
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

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let action = pendingActions.removeValue(forKey: ObjectIdentifier(request))
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
        pendingActions.removeValue(forKey: ObjectIdentifier(request))
        logger.error("System extension request failed: \(error.localizedDescription)")
        if let error = error as? OSSystemExtensionError, error.code == .unsupportedParentBundleLocation {
            state = .requiresApplicationsFolder
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}

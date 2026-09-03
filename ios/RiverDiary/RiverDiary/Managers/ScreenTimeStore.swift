import FamilyControls
import Foundation
import SwiftUI

enum SystemPermissionState: Equatable {
    case notRequested
    case requesting
    case approved
    case denied
    case unavailable
}

@MainActor
final class ScreenTimeStore: ObservableObject {
    @Published private(set) var permissionState: SystemPermissionState = .notRequested
    @Published private(set) var errorMessage: String?

    init() {
        Task { refreshAuthorizationStatus() }
    }

    private func refreshAuthorizationStatus() {
        let status = AuthorizationCenter.shared.authorizationStatus

        if #available(iOS 26.4, *), status == .approvedWithDataAccess {
            permissionState = .approved
        } else if status == .approved {
            permissionState = .approved
        } else if status == .denied {
            permissionState = .denied
        } else {
            permissionState = .notRequested
        }
    }

    func requestAuthorization() {
        permissionState = .requesting
        errorMessage = nil

        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                refreshAuthorizationStatus()
            } catch {
                permissionState = .denied
                errorMessage = error.localizedDescription
            }
        }
    }
}

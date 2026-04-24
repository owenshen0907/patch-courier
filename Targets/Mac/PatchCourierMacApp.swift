import AppKit
import SwiftUI

@MainActor
final class PatchCourierAppDelegate: NSObject, NSApplicationDelegate {
    let workspaceModel = MailroomWorkspaceModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        workspaceModel.loadIfNeeded()
        Task {
            await workspaceModel.ensureBackgroundDaemonRunning()
            await workspaceModel.refreshDaemonState()
        }
    }
}

@main
struct PatchCourierMacApp: App {
    @NSApplicationDelegateAdaptor(PatchCourierAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardView(workspaceModel: appDelegate.workspaceModel)
        }
        .defaultSize(width: 1480, height: 920)
    }
}

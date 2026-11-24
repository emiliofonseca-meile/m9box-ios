//
//  M9 Box - Nextcloud client branded for M9 Box
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Builds the tasks screen for the signed-in account (same credentials as the
//  device sync). Pushed from More and from the sync screen.
//

import SwiftUI
import UIKit

enum M9BoxTasksTab {
    static func makeViewController(account: String) -> UIViewController? {
        guard let creds = M9BoxSyncCredentials(account: account) else { return nil }
        let client = M9BoxCalDavClient(baseURL: creds.baseURL, authHeader: creds.authHeader, userId: creds.userId)
        let host = UIHostingController(rootView: M9BoxTasksView(repository: M9BoxTasksRepository(client: client)))
        host.title = NSLocalizedString("_m9box_tasks_", comment: "")
        return host
    }

    /// Push the tasks screen on the navigation stack that is currently visible.
    /// Used by the sync screen, which is SwiftUI hosted and has no controller of its own.
    static func pushOnVisibleStack(account: String) {
        guard let controller = makeViewController(account: account) else { return }
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        let nav = (root as? UITabBarController)?.selectedViewController as? UINavigationController
            ?? root as? UINavigationController
        nav?.pushViewController(controller, animated: true)
    }
}

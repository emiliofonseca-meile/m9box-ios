//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Builds the tasks screen for the signed-in account (same credentials as the
//  device sync). Pushed from More and from the sync screen.
//

import SwiftUI
import UIKit

enum MeileTasksTab {
    static func makeViewController(account: String) -> UIViewController? {
        guard let creds = MeileSyncCredentials(account: account) else { return nil }
        let client = MeileCalDavClient(baseURL: creds.baseURL, authHeader: creds.authHeader, userId: creds.userId)
        let host = UIHostingController(rootView: MeileTasksView(repository: MeileTasksRepository(client: client)))
        host.title = NSLocalizedString("_meile_tasks_", comment: "")
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

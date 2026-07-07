//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Entry point that turns the active account's credentials into a CalDAV-backed
//  calendar screen, hosted in a UINavigationController for use as a tab bar item.
//  Credentials come from NCSession (urlBase/user/userId) + NCPreferences keychain
//  (password) — the same pair the rest of the app uses for DAV requests.
//

import UIKit
import SwiftUI

enum MeileCalendarTab {

    /// Build the calendar tab for the given account, or nil if credentials are
    /// incomplete (e.g. no active account yet).
    static func makeViewController(account: String) -> UIViewController? {
        let session = NCSession.shared.getSession(account: account)
        let password = NCPreferences().getPassword(account: account)

        guard !session.urlBase.isEmpty,
              !session.user.isEmpty,
              !password.isEmpty,
              let baseURL = URL(string: session.urlBase) else {
            return nil
        }

        let raw = "\(session.user):\(password)"
        guard let token = raw.data(using: .utf8)?.base64EncodedString() else { return nil }
        let authHeader = "Basic \(token)"

        let client = MeileCalDavClient(baseURL: baseURL, authHeader: authHeader, userId: session.userId)
        let repository = MeileCalendarRepository(client: client)

        let hosting = UIHostingController(rootView: MeileCalendarView(repository: repository))
        hosting.tabBarItem = UITabBarItem(
            title: NSLocalizedString("_meile_calendar_", comment: ""),
            image: UIImage(systemName: "calendar"),
            selectedImage: UIImage(systemName: "calendar")
        )
        hosting.tabBarItem.tag = 105
        return hosting
    }
}

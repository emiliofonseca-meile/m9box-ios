//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One-time, post-login offer to turn on calendar/contacts sync, mirroring the
//  Android client: on the first real session a short prompt invites the user, and
//  "Ativar" requests the Calendar/Contacts permissions and runs the first sync —
//  no digging into More → Sync, no profile, no Settings. The .mobileconfig path
//  still exists on the sync screen for anyone who wants a real system CalDAV
//  account instead.
//

import SwiftUI
import UIKit

enum MeileSyncOnboarding {

    // Bumped when the offer flow changes so a user who saw an older version is
    // offered the current one once.
    private static let askedKey = "meile_sync_offer_asked_v3"
    /// Guards against re-presenting while the main files screen re-appears (it does
    /// so for every folder); the persisted flag guards across launches.
    private static var offeredThisSession = false

    /// Present the offer once if signed in, not asked before, and native sync is
    /// not already on. Safe to call from any view controller's viewDidAppear.
    static func maybeOffer(from viewController: UIViewController, account: String?) {
        guard !offeredThisSession,
              let account, !account.isEmpty,
              !UserDefaults.standard.bool(forKey: askedKey),
              !MeileNativeSync.shared.isEnabled,
              MeileSyncCredentials(account: account) != nil
        else { return }

        offeredThisSession = true
        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = UIAlertController(
            title: "Sincronizar Agenda e Contatos",
            message: "Deixe sua agenda e seus contatos do M9 Box aparecerem no Calendário e nos Contatos do iPhone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Ativar", style: .default) { _ in
            Task { await MeileNativeSync.shared.enable(account: account) }
        })
        alert.addAction(UIAlertAction(title: "Agora não", style: .cancel))
        viewController.present(alert, animated: true)
    }

    /// Push the sync setup screen — the same one reachable from More → Sync.
    static func openSyncScreen(from viewController: UIViewController, account: String) {
        let host = UIHostingController(rootView: MeileSyncSetupView(account: account))
        host.title = NSLocalizedString("_meile_sync_", comment: "")
        if let nav = viewController.navigationController {
            nav.pushViewController(host, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: host)
            viewController.present(nav, animated: true)
        }
    }
}

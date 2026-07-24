//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One-time, post-login offer to set up calendar/contacts sync, so the user is
//  invited on their first real session instead of having to dig into More → Sync
//  and tap a button (the Android client offers it the same way).
//
//  iOS cannot silently add a system CalDAV/CardDAV account, so "setting up sync"
//  here means generating the .mobileconfig and handing it to iOS to install — the
//  Settings + password step is Apple's wall and cannot be removed. The offer just
//  brings that flow to the front on first launch.
//

import SwiftUI
import UIKit

enum MeileSyncOnboarding {

    // Bumped when the offer flow changes so a user who dismissed the older,
    // broken version is offered the fixed one once.
    private static let askedKey = "meile_sync_offer_asked_v2"
    /// Guards against re-presenting while the main files screen re-appears (it does
    /// so for every folder); the persisted flag guards across launches.
    private static var offeredThisSession = false

    /// Present the offer once if the user is signed in and has not been asked before.
    /// Safe to call from any view controller's viewDidAppear.
    static func maybeOffer(from viewController: UIViewController, account: String?) {
        guard !offeredThisSession,
              let account, !account.isEmpty,
              !UserDefaults.standard.bool(forKey: askedKey),
              // Only offer when we can actually build a profile (valid session).
              MeileMobileConfig.makeProfile(account: account) != nil
        else { return }

        offeredThisSession = true
        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = UIAlertController(
            title: "Sincronizar Agenda e Contatos",
            message: "Deixe sua agenda e seus contatos do M9 Box aparecerem no Calendário e nos Contatos do iPhone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Ativar", style: .default) { _ in
            // Take the user to the sync screen (with the how-it-works steps and the
            // generate button). Deferring past the alert's dismissal avoids the
            // UIKit case where presenting/pushing inside the action handler is
            // dropped while the alert is still animating away.
            DispatchQueue.main.async {
                openSyncScreen(from: viewController, account: account)
            }
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

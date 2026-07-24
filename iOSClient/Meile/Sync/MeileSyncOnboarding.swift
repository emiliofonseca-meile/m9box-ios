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

import UIKit

enum MeileSyncOnboarding {

    private static let askedKey = "meile_sync_offer_asked"
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
            presentProfileInstall(from: viewController, account: account)
        })
        alert.addAction(UIAlertAction(title: "Agora não", style: .cancel))
        viewController.present(alert, animated: true)
    }

    /// Build the profile and hand it to iOS to install (same as tapping the button
    /// on the sync screen). The share sheet lets the user save/open it, which leads
    /// to Settings → Install.
    private static func presentProfileInstall(from viewController: UIViewController, account: String) {
        guard let url = MeileMobileConfig.makeProfile(account: account) else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad: anchor the popover so it doesn't crash.
        if let pop = share.popoverPresentationController {
            pop.sourceView = viewController.view
            pop.sourceRect = CGRect(x: viewController.view.bounds.midX,
                                    y: viewController.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        viewController.present(share, animated: true)
    }
}

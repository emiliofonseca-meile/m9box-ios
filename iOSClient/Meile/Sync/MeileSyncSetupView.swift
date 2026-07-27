//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Sync screen. Primary path is native sync (EventKit/Contacts): one tap grants
//  permission and the app mirrors the Box agenda/contacts into the phone's own
//  Calendar/Contacts — no profile, no Settings. The .mobileconfig path is kept
//  under "Opções avançadas" for anyone who prefers a real system CalDAV account
//  (which iOS then syncs in the background) at the cost of the manual install.
//

import SwiftUI
import UIKit

/// Wraps the profile URL so it can drive `.sheet(item:)`. Using `.sheet(item:)`
/// instead of `.sheet(isPresented:)` + `if let` avoids the race where SwiftUI
/// presents the sheet before the URL state commits and shows an empty sheet.
private struct ProfileFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct MeileSyncSetupView: View {
    let account: String

    @State private var enabled = MeileNativeSync.shared.isEnabled
    @State private var busy = false
    @State private var shareProfile: ProfileFile?
    @State private var errorText: String?
    @State private var resultText: String?

    private let brandBlue = Color(red: 0.07, green: 0.43, blue: 0.94)

    var body: some View {
        List {
            Section {
                Text("Sincronizar Agenda e Contatos")
                    .font(.title3).bold()
                    .foregroundColor(brandBlue)
                Text("Sua agenda e seus contatos do M9 Box aparecem no Calendário e nos Contatos do iPhone.")
                    .font(.subheadline)
            }

            Section {
                if enabled {
                    Label("Sincronização ativada", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Button {
                        Task { await syncNow() }
                    } label: {
                        if busy { ProgressView() } else { Label("Sincronizar agora", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(busy)
                } else {
                    Button {
                        Task { await activate() }
                    } label: {
                        if busy { ProgressView() } else { Label("Ativar sincronização", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(busy)
                }
                if let errorText {
                    Text(errorText).foregroundColor(.red).font(.footnote)
                }
                if let resultText {
                    Text(resultText).foregroundColor(.secondary).font(.footnote)
                }
            }

            Section("Abrir no iPhone") {
                openRow("Agenda", systemImage: "calendar", schemes: ["calshow://"])
                // No single documented scheme opens Contacts across iOS versions;
                // try the known candidates in order until one launches.
                openRow("Contatos", systemImage: "person.crop.circle",
                        schemes: ["addressbook://", "contacts://", "mobileaddressbook://"])
            }

            Section {
                Button {
                    generateProfile()
                } label: {
                    Label("Gerar perfil (conta CalDAV do sistema)", systemImage: "gearshape")
                        .font(.subheadline)
                }
            } header: {
                Text("Opções avançadas")
            } footer: {
                Text("Instala uma conta de sistema que o iPhone sincroniza em segundo plano. Requer instalar um perfil em Ajustes e informar sua senha.")
            }
        }
        .navigationTitle("Sincronização")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareProfile) { profile in
            MeileShareSheet(items: [profile.url])
        }
    }

    /// A tappable row that jumps to a native iPhone app. iOS has no officially
    /// documented scheme for Calendar/Contacts, but `calshow://` and `contacts://`
    /// are long-standing and handled by the system apps; `open` fails silently via
    /// its completion handler if a scheme is ever unavailable, so the row never
    /// misbehaves.
    private func openRow(_ title: String, systemImage: String, schemes: [String]) -> some View {
        Button {
            openFirst(schemes)
        } label: {
            HStack {
                Label(title, systemImage: systemImage).foregroundColor(brandBlue)
                Spacer()
                Image(systemName: "arrow.right").foregroundColor(brandBlue)
            }
        }
    }

    /// Try each scheme in turn; `open`'s completion reports whether a handler
    /// existed, so we fall through to the next candidate when one isn't supported.
    private func openFirst(_ schemes: [String]) {
        guard let first = schemes.first, let url = URL(string: first) else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { openFirst(Array(schemes.dropFirst())) }
        }
    }

    @MainActor
    private func activate() async {
        errorText = nil
        busy = true
        let ok = await MeileNativeSync.shared.enable(account: account)
        busy = false
        if ok {
            enabled = true
            await syncNow()
        } else {
            errorText = "Conceda acesso à Agenda e aos Contatos nos Ajustes para sincronizar."
        }
    }

    @MainActor
    private func syncNow() async {
        busy = true
        resultText = nil
        errorText = nil
        let summary = await MeileNativeSync.shared.sync(account: account)
        busy = false
        var line = "Agenda: \(summary.events) · Contatos: \(summary.contacts)"
        if summary.pushedEvents + summary.pushedContacts > 0 {
            line += " · enviados: \(summary.pushedEvents + summary.pushedContacts)"
        }
        if let container = summary.contactContainer {
            line += "\nContatos em: \(container)"
        }
        resultText = line
        if let e = summary.error { errorText = e }
    }

    private func generateProfile() {
        errorText = nil
        guard let url = MeileMobileConfig.makeProfile(account: account) else {
            errorText = "Entre na sua conta M9 Box primeiro."
            return
        }
        shareProfile = ProfileFile(url: url)
    }
}

/// Thin UIActivityViewController wrapper so the profile can be saved/opened and
/// installed by iOS.
struct MeileShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

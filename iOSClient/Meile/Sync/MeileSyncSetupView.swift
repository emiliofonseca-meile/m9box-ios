//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  "Sincronizar Agenda e Contatos" screen. Builds a CalDAV/CardDAV .mobileconfig
//  from the signed-in account and hands it to iOS to install, so events/contacts
//  appear in the phone's native Calendar/Contacts apps. One app, no DAVx5.
//

import SwiftUI
import UIKit

struct MeileSyncSetupView: View {
    let account: String

    @State private var profileURL: URL?
    @State private var showShare = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Text("Sincronizar Agenda e Contatos")
                    .font(.title3).bold()
                    .foregroundColor(Color(red: 0.07, green: 0.43, blue: 0.94))
                Text("Instale o perfil do M9 Box para que sua agenda e seus contatos apareçam no Calendário e nos Contatos nativos do iPhone.")
                    .font(.subheadline)
            }

            Section("Como funciona") {
                stepRow(1, "Toque em \"Gerar perfil de sincronização\".")
                stepRow(2, "Escolha \"Salvar em Arquivos\" (ou abra direto) e toque no arquivo.")
                stepRow(3, "Em Ajustes › Perfil Baixado, toque em Instalar e informe sua senha do M9 Box.")
            }

            Section {
                Button {
                    generate()
                } label: {
                    Label("Gerar perfil de sincronização", systemImage: "arrow.triangle.2.circlepath")
                }
                if let errorText {
                    Text(errorText).foregroundColor(.red).font(.footnote)
                }
            }

            Section("Abrir no iPhone") {
                openRow("Agenda", systemImage: "calendar", scheme: "calshow://")
                openRow("Contatos", systemImage: "person.crop.circle", scheme: "contacts://")
            }
        }
        .navigationTitle("Sincronização")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let profileURL {
                MeileShareSheet(items: [profileURL])
            }
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").bold().frame(width: 22, height: 22)
                .background(Circle().fill(Color(red: 0.07, green: 0.43, blue: 0.94).opacity(0.15)))
            Text(text).font(.subheadline)
        }
    }

    /// A tappable row that jumps to a native iPhone app. iOS has no officially
    /// documented scheme for Calendar/Contacts, but `calshow://` and `contacts://`
    /// are long-standing and handled by the system apps; `open` fails silently via
    /// its completion handler if a scheme is ever unavailable, so the row never
    /// misbehaves.
    private func openRow(_ title: String, systemImage: String, scheme: String) -> some View {
        Button {
            guard let url = URL(string: scheme) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundColor(Color(red: 0.07, green: 0.43, blue: 0.94))
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundColor(Color(red: 0.07, green: 0.43, blue: 0.94))
            }
        }
    }

    private func generate() {
        errorText = nil
        let session = NCSession.shared.getSession(account: account)
        guard let host = URL(string: session.urlBase)?.host, !session.user.isEmpty else {
            errorText = "Entre na sua conta M9 Box primeiro."
            return
        }
        let data = MeileMobileConfig.build(
            MeileMobileConfig.Input(
                host: host,
                username: session.user,
                userId: session.userId.isEmpty ? session.user : session.userId,
                displayName: "M9 Box (\(host))"
            )
        )
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("M9 Box.mobileconfig")
            try data.write(to: url, options: .atomic)
            profileURL = url
            showShare = true
        } catch {
            errorText = error.localizedDescription
        }
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

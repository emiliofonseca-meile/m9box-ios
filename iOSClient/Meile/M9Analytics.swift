//
//  M9Analytics.swift
//  M9 Box
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Firebase Analytics do M9 Box: quem usa o app e o quê, igual ao Android (M9Analytics.kt).
//  A conta vai como código, nunca como e-mail: os termos do Google Analytics proíbem dado que
//  identifique a pessoa, mesmo com hash. O código é um HMAC do login com uma chave que fica fora do
//  repositório (Keychain, entra no build por M9_ANALYTICS_KEY); só quem tem a chave liga código e pessoa.
//

import Foundation
import CryptoKit
import FirebaseCore
import FirebaseAnalytics

enum M9Analytics {
    // FirebaseApp.configure() só roda com o GoogleService-Info.plist real (AppDelegate)
    private static var enabled: Bool { FirebaseApp.app() != nil }
    private static var key: String { Bundle.main.object(forInfoDictionaryKey: "M9AnalyticsKey") as? String ?? "" }
    // conta já informada ao Firebase; evita refazer o HMAC a cada volta ao app
    @MainActor private static var lastAccount: String?

    /// Código da conta: 16 hex do HMAC-SHA256 do login em minúsculas. nil sem chave no build.
    static func accountCode(_ login: String, key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(login.lowercased().utf8), using: SymmetricKey(data: Data(key.utf8)))
        return String(mac.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Liga os eventos à conta ativa (login, troca e saída de conta).
    @MainActor
    static func identify() {
        guard enabled else { return }
        let tblAccount = NCManageDatabase.shared.getActiveTableAccount()
        let account = tblAccount?.account ?? ""
        guard account != lastAccount else { return }
        lastAccount = account

        guard let tblAccount else {
            Analytics.setUserID(nil)
            Analytics.setUserProperty(nil, forName: "conta")
            Analytics.setUserProperty(nil, forName: "servidor")
            return
        }
        let code = accountCode(tblAccount.user, key: key)
        Analytics.setUserID(code)
        Analytics.setUserProperty(code, forName: "conta")
        Analytics.setUserProperty(URL(string: tblAccount.urlBase)?.host.map { String($0.prefix(36)) }, forName: "servidor")
    }

    /// Item da aba Mais (ex.: "meile_talk", "settings"), mesmos nomes do Android.
    static func menu(_ item: String) {
        guard enabled else { return }
        Analytics.logEvent("menu_item", parameters: ["item": item])
    }

    /// Envio concluído; auto = envio automático de fotos/vídeos, não um envio da pessoa.
    static func upload(auto: Bool) {
        guard enabled else { return }
        Analytics.logEvent("file_upload", parameters: ["auto": auto ? "true" : "false"])
    }
}

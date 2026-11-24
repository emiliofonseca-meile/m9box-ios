//
//  M9 Box - Chamadas do Conversas como ligação nativa do iPhone.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  O servidor de push (<Box>/m9push) manda um push VoIP (PushKit) quando alguém liga no Talk.
//  O iOS exige reportar a chamada ao CallKit DENTRO do handler, senão derruba o app e deixa de
//  entregar VoIP; por isso o relato acontece antes de qualquer outra coisa. O `subject` vem
//  cifrado com a chave da conta (a mesma da Notification Service Extension).
//  Atender abre o Conversas na sala da chamada e encerra a ligação no CallKit: quem fala é o
//  WebRTC do WKWebView, e uma segunda sessão de áudio do CallKit brigaria com ele.
//

import UIKit
import PushKit
import CallKit
import NextcloudKit

final class M9BoxCallKit: NSObject, PKPushRegistryDelegate, CXProviderDelegate {

    static let shared = M9BoxCallKit()

    private struct Call {
        let uuid: UUID
        let account: String
        let token: String
        let url: URL?
    }

    private let provider: CXProvider
    private let callController = CXCallController()
    private var registry: PKPushRegistry?
    private var calls: [UUID: Call] = [:]

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// Chamar no launch: o iOS só entrega VoIP depois do registro.
    func start() {
        guard registry == nil else { return }
        registry = PKPushRegistry(queue: .main)
        registry?.delegate = self
        registry?.desiredPushTypes = [.voIP]
    }

    // MARK: - PushKit

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        NCPreferences().deviceTokenVoipPushNotification = token
        Task.detached {
            for tbl in await NCManageDatabase.shared.getAllTableAccountAsync() {
                await NCPushNotification.shared.subscribingNextcloudServerPushNotification(account: tbl.account, urlBase: tbl.urlBase)
            }
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if type == .voIP { NCPreferences().deviceTokenVoipPushNotification = "" }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { return completion() }
        let message = payload.dictionaryPayload["subject"] as? String
        let info = decrypt(message)

        // remoção: chamada encerrada ou atendida em outro aparelho
        if info?["delete"] as? Bool == true || info?["delete-all"] as? Bool == true || info?["delete-multiple"] != nil {
            let token = info?["id"] as? String ?? info?["objectId"] as? String
            let ending = calls.values.filter { $0.account == (info?["account"] as? String) && (token == nil || $0.token == token) }
            if ending.isEmpty {
                // sem chamada para encerrar: o iOS ainda exige um relato, que se fecha na hora
                let uuid = UUID()
                report(uuid: uuid, name: "M9 Box") { _ in self.provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
            }
            ending.forEach { end($0.uuid, reason: .answeredElsewhere) }
            return completion()
        }

        let account = info?["account"] as? String ?? ""
        let token = info?["id"] as? String ?? info?["objectId"] as? String ?? ""
        let name = info?["subject"] as? String ?? "M9 Box"
        var link = (info?["link"] as? String).flatMap(URL.init(string:))
        if link == nil, let base = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account })?.urlBase, !token.isEmpty {
            link = URL(string: base + "/call/" + token)
        }
        let call = Call(uuid: UUID(), account: account, token: token, url: link)
        report(uuid: call.uuid, name: name) { error in
            guard error == nil else { return }
            self.calls[call.uuid] = call
            // se o push de remoção nunca chegar, não toca para sempre
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.calls[call.uuid] != nil else { return }
                self.provider.reportCall(with: call.uuid, endedAt: nil, reason: .unanswered)
                self.calls[call.uuid] = nil
            }
        }
        completion()
    }

    private func report(uuid: UUID, name: String, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = true
        provider.reportNewIncomingCall(with: uuid, update: update, completion: completion)
    }

    private func end(_ uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
        calls[uuid] = nil
    }

    /// Decifra o `subject` com a chave privada de cada conta; devolve o JSON + a conta que abriu.
    private func decrypt(_ message: String?) -> [String: Any]? {
        guard let message else { return nil }
        for tbl in NCManageDatabase.shared.getAllTableAccount() {
            guard let key = NCPreferences().getPushNotificationPrivateKey(account: tbl.account),
                  let plain = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: key),
                  var json = (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) as? [String: Any] else { continue }
            json["account"] = tbl.account
            return json
        }
        return nil
    }

    // MARK: - CallKit

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let call = calls[action.callUUID] {
            open(call)
            // quem fala é o WebRTC do Conversas; a ligação nativa já cumpriu o papel
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.callController.request(CXTransaction(action: CXEndCallAction(call: call.uuid)), completion: { _ in })
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        calls[action.callUUID] = nil
        action.fulfill()
    }

    func providerDidReset(_ provider: CXProvider) {
        calls.removeAll()
    }

    // MARK: - Abrir o Conversas

    private func open(_ call: Call) {
        func present() {
            guard let tab = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController else { return }
            Task { @MainActor in
                if tab.account != call.account,
                   let tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == call.account }) {
                    await NCAccount().changeAccount(tbl.account, userProfile: nil, controller: tab)
                }
                guard let talk = M9BoxTalkViewController.make(account: call.account, url: call.url),
                      let nav = tab.currentNavigationController() else { return }
                nav.pushViewController(talk, animated: true)
            }
        }
        if UIApplication.shared.applicationState == .active {
            present()
        } else {
            // atendeu com o aparelho bloqueado: espera o app ficar ativo
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: present)
            }
        }
    }
}

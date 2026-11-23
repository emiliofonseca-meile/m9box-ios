//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Conversas: o Talk do próprio Box (chat + chamada de voz e vídeo) dentro do app.
//  Em vez de mandar para o app Nextcloud Talk (outra marca, outro app), abre o Talk web do
//  servidor num WKWebView autenticado com a credencial da conta (MeileSyncCredentials) e libera
//  câmera e microfone para o WebRTC. A chamada passa pelo mesmo HPB (meet) que o navegador usa.
//
//  Autenticação: o Nextcloud não abre sessão web para senha de app (cada pedido com Basic vale
//  só para ele), então a credencial vai em todo pedido ao Box:
//  - XHR/fetch do Talk: script no início do documento (só na origem do Box) que põe Authorization
//    e OCS-APIRequest (este dispensa o token CSRF da sessão, que muda a cada pedido);
//  - navegação de página: cancelada e refeita com o cabeçalho.
//  O WKWebView não deixa interceptar imagem; prévia de arquivo no chat pode não aparecer.
//
//  Sessão: o Talk guarda na sessão PHP em que sala o usuário está. Com senha de app, o Nextcloud
//  troca o id da sessão no segundo pedido autenticado; se esse segundo pedido for a rajada de XHR
//  do Talk, cada um troca para um id diferente e a sala "some". Por isso, antes de abrir o Talk,
//  dois pedidos em sequência fixam a sessão e o cookie dela vai para o WKWebView.
//

import UIKit
import WebKit

final class MeileTalkViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    private let account: String
    private let baseURL: URL
    private let authHeader: String
    private let startURL: URL
    private var webView: WKWebView!

    /// Tela de Conversas da conta; `url` abre direto uma conversa ou chamada do mesmo Box.
    static func make(account: String, url: URL? = nil) -> UIViewController? {
        guard let creds = MeileSyncCredentials(account: account) else { return nil }
        // link de fora do Box nunca recebe a credencial: cai na tela inicial das Conversas
        let home = creds.baseURL.appendingPathComponent("index.php/apps/spreed/")
        let start = url.flatMap { sameOrigin($0, creds.baseURL) ? $0 : nil } ?? home
        let controller = MeileTalkViewController(account: account, baseURL: creds.baseURL, authHeader: creds.authHeader, startURL: start)
        controller.title = NSLocalizedString("_meile_talk_", comment: "")
        controller.hidesBottomBarWhenPushed = true
        return controller
    }

    private init(account: String, baseURL: URL, authHeader: String, startURL: URL) {
        self.account = account
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.startURL = startURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Mesma origem = mesmo esquema, host e porta. Só o host não basta: um link http:// (ou de
    // outra porta) do mesmo host levaria a senha de app em texto claro ou para outro serviço.
    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && port(a) == port(b)
    }

    private func isBox(_ url: URL) -> Bool { Self.sameOrigin(url, baseURL) }

    private var origin: String {
        var value = "\(baseURL.scheme?.lowercased() ?? "https")://\(baseURL.host?.lowercased() ?? "")"
        if let port = baseURL.port { value += ":\(port)" }
        return value
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        // Sem dados persistentes, como os outros viewers do app: nada do Talk de uma conta fica
        // para a próxima (a sessão vem do aquecimento a cada abertura).
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // O Talk marca navegador sem "Version/… Safari/…" como sem suporte e avisa na tela;
        // o motor é o WebKit do Safari, então ele se apresenta como Safari.
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        config.userContentController.addUserScript(
            WKUserScript(source: authScript() + "\n" + pageScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            await warmSession()
            load(startURL)
        }
    }

    /// Dois pedidos autenticados em sequência fixam a sessão PHP; os cookies vão para o WKWebView.
    private func warmSession() async {
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/ocs/v2.php/cloud/user?format=json") else { return }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        do {
            for _ in 0..<2 { _ = try await session.data(for: request) }
        } catch {
            return
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in config.httpCookieStorage?.cookies(for: url) ?? [] {
            await store.setCookie(cookie)
        }
    }

    // chamada não pode apagar a tela no meio
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func load(_ url: URL) {
        guard isBox(url) else { return }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        webView.load(request)
    }

    // Credencial em todo XHR/fetch do Box (mesmo script do app Android).
    private func authScript() -> String {
        let auth = String(data: (try? JSONEncoder().encode(authHeader)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        let allowed = String(data: (try? JSONEncoder().encode(origin)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        return """
        (() => {
          if (window.__m9auth || location.origin !== \(allowed)) return; window.__m9auth = true;
          const H = {"Authorization": \(auth), "OCS-APIRequest": "true"};
          const same = u => { try { return new URL(u, location.href).origin === location.origin } catch (e) { return false } };
          const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (m, u) { this.__m9 = same(u); return open.apply(this, arguments) };
          XMLHttpRequest.prototype.send = function () {
            if (this.__m9) for (const k in H) { try { this.setRequestHeader(k, H[k]) } catch (e) {} }
            return send.apply(this, arguments);
          };
          const f = window.fetch;
          window.fetch = function (input, init) {
            const url = typeof input === "string" ? input : (input && input.url) || String(input);
            if (!same(url)) return f.apply(this, arguments);
            const req = new Request(input, init);
            for (const k in H) if (!req.headers.has(k)) req.headers.set(k, H[k]);
            return f.call(this, req);
          };
        })();
        """
    }

    // Mesmo texto do app Android (PAGE_STYLE e WAIT_SOUND_FIX), só na origem do Box:
    // - sem o cabeçalho do Nextcloud (a tela fica só com o Talk) e com o painel de conversas opaco;
    // - o Talk toca o "chamando" (LibremPhoneCall) logo depois do som de saída (leave_call) quando a
    //   outra pessoa sai: esse toque fica mudo até o Talk pará-lo; o "chamando" de quem liga segue.
    private func pageScript() -> String {
        let allowed = String(data: (try? JSONEncoder().encode(origin)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        return """
        (() => {
          if (window.__m9style || location.origin !== \(allowed)) return; window.__m9style = true;
          const css = `#header:not(.header-guest) { display: none !important; }
          :root, body { --header-height: 0px !important; --color-main-background-blur: var(--color-main-background) !important; }
          @media (max-width: 640px) {
            .bottom-bar { overflow: visible !important; }
            .bottom-bar > * { flex-shrink: 0; }
            .bottom-bar > .bottom-bar-call-controls:not(:has(.leave-call)):has(> :nth-child(3)) {
              flex-shrink: 1; min-width: 0; overflow-x: auto; scrollbar-width: none;
            }
            .bottom-bar > .bottom-bar-call-controls::-webkit-scrollbar { display: none; }
          }`;
          const add = () => {
            const s = document.createElement("style");
            s.textContent = css;
            (document.head || document.documentElement).appendChild(s);
          };
          if (document.documentElement) add(); else document.addEventListener("DOMContentLoaded", add);
        })();
        (() => {
          if (window.__m9wait || location.origin !== \(allowed)) return; window.__m9wait = true;
          const P = HTMLMediaElement.prototype, play = P.play, pause = P.pause;
          const src = a => a.src || a.currentSrc || "";
          let lastLeave = -Infinity, mute = false;
          P.play = function () {
            if (/\\/leave_call\\./.test(src(this))) lastLeave = Date.now();
            if (/\\/LibremPhoneCall\\./.test(src(this))) {
              if (!mute && Date.now() - lastLeave < 1000) mute = true;
              if (mute) return Promise.resolve();
            }
            return play.apply(this, arguments);
          };
          P.pause = function () {
            if (/\\/LibremPhoneCall\\./.test(src(this))) mute = false;
            return pause.apply(this, arguments);
          };
        })();
        """
    }

    // MARK: - Só o Talk fica na tela

    private static let callPath = try! NSRegularExpression(pattern: "/call/[A-Za-z0-9]+")
    private static let fileLink = try! NSRegularExpression(pattern: "(?:/index\\.php)?/f/([0-9]+)$")
    private static let filesAppId = try! NSRegularExpression(pattern: "/apps/files/files/([0-9]+)")

    private static func firstGroup(_ re: NSRegularExpression, _ text: String) -> String?? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return .some(nil) }
        return .some(String(text[r]))
    }

    private static func isTalk(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/apps/spreed") || callPath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// Link de arquivo do Box: `.some(id)` (/f/<id> ou /apps/files/files/<id>), `.some(nil)` para a
    /// pasta ou o app Arquivos sem id, `nil` se não for arquivo.
    private static func fileTarget(_ url: URL) -> String?? {
        let path = url.path
        if let id = firstGroup(fileLink, path), let id { return .some(id) }
        guard path.contains("/apps/files") else { return nil }
        if let id = firstGroup(filesAppId, path), let id { return .some(id) }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fileid" }?.value
        if let q, !q.isEmpty, q.allSatisfy(\.isNumber) { return .some(q) }
        return .some(nil)
    }

    /// "Sair" do Nextcloud = sair da conta do app (a saída web daria "CSRF check failed"): mesma
    /// confirmação de "Remover conta local" das configurações da conta.
    private func confirmLogout() {
        let tab = tabBarController as? NCMainTabBarController
        let account = self.account
        let alert = UIAlertController(title: NSLocalizedString("_want_delete_account_", comment: ""), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("_remove_local_account_", comment: ""), style: .destructive) { [weak self, weak tab] _ in
            Task { @MainActor in
                self?.navigationController?.popToRootViewController(animated: false)
                await NCAccount().deleteAccount(account)
                await NCAccount().showNextAccountOrLogin(controller: tab)
            }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("_cancel_", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    /// Página do Box que não é o Talk: Sair vira sair da conta, arquivo abre na tela nativa, o resto
    /// vai pro Safari.
    private func leaveTalk(_ url: URL) {
        if url.path.hasSuffix("/logout") {
            confirmLogout()
        } else if let target = Self.fileTarget(url) {
            openNativeFile(target)
        } else if url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
        }
    }

    private func openNativeFile(_ id: String?) {
        guard let tab = tabBarController as? NCMainTabBarController else { return }
        if let id {
            // empilha o visualizador do app; a chamada em andamento fica na tela de baixo
            Task { @MainActor in
                await NCNetworking.shared.viewerFile(account: account, fileId: id, viewController: self)
            }
        } else {
            // pasta ou app Arquivos sem id: fecha as Conversas e leva à aba Arquivos
            navigationController?.popToRootViewController(animated: true)
            tab.selectedIndex = ControllerConstants.filesIndex
        }
    }

    // MARK: - WKNavigationDelegate

    // dentro do Box, toda página leva a credencial; link para fora vai pro Safari
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isBox(url) {
            if mainFrame {
                if url.scheme == "http" || url.scheme == "https" { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
            return
        }
        // voltar/avançar e âncora na mesma página: deixa o WebKit seguir (vem do cache), sem
        // recarregar; refazer a navegação criaria outra entrada no histórico
        var semFragmento = URLComponents(url: url, resolvingAgainstBaseURL: false)
        semFragmento?.fragment = nil
        var atual = webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        atual?.fragment = nil
        if navigationAction.navigationType == .backForward || (semFragmento != nil && semFragmento?.url == atual?.url && url.fragment != nil) {
            decisionHandler(.allow)
            return
        }
        // Fica na tela só o Talk. Subframe e redirect do servidor (o pedido já leva a credencial, pois
        // vem de um load nosso) seguem como antes; o resto do Box sai daqui.
        if mainFrame, !Self.isTalk(url) {
            if url.path.hasSuffix("/logout") || navigationAction.request.value(forHTTPHeaderField: "Authorization") == nil {
                decisionHandler(.cancel)
                leaveTalk(url)
                return
            }
        }
        if mainFrame, navigationAction.request.httpMethod == "GET",
           navigationAction.request.value(forHTTPHeaderField: "Authorization") == nil {
            decisionHandler(.cancel)
            load(url)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    // link que abriria outra janela: Talk do Box fica aqui, resto do Box segue a regra do Talk, fora vai pro Safari
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isBox(url) {
                if Self.isTalk(url) { load(url) } else { leaveTalk(url) }
            } else if url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    // Câmera e microfone: o iOS já pediu ao usuário (textos no Info.plist); aqui só o Box recebe.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let boxPort = baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)
        let ok = origin.protocol == baseURL.scheme && origin.host.lowercased() == baseURL.host?.lowercased()
            && (origin.port == 0 ? (origin.protocol == "https" ? 443 : 80) : origin.port) == boxPort
        decisionHandler(ok ? .grant : .deny)
    }

    // MARK: - Downloads (anexo do chat)

    // o que o WebKit não mostra, ou vem como anexo, vira download
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    private var downloaded: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(suggestedFilename)
        downloaded[ObjectIdentifier(download)] = file
        completionHandler(file)
    }

    // baixou: folha de compartilhamento (Salvar em Arquivos, abrir em outro app...); fechada, a
    // cópia temporária some
    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloaded.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let dir = file.deletingLastPathComponent()
        guard view.window != nil else {
            try? FileManager.default.removeItem(at: dir)
            return
        }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
        share.popoverPresentationController?.sourceView = view
        // outra folha ou alerta já na tela: apresenta por cima dela em vez de falhar calado
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloaded.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }
}

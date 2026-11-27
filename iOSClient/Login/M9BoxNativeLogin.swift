// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-License-Identifier: GPL-3.0-or-later

//
// M9 Box: native login with e-mail + password.
//
// The server of every customer is https://box.<domain of the e-mail>, so the user types only
// the e-mail and the password. The password is exchanged for an app password (the same call
// the Login Flow already uses for MDM) and then the usual NCAccount.createAccount runs.
// The web login (Login Flow v2) stays as a fallback button.
//
// Kept in its own file so rebasing on upstream only touches the few hooks in NCLogin.swift.
//

import Foundation

// MARK: - Pure logic (no UIKit, compiled alone by the unit check outside the repo)

enum M9BoxLoginError: Equatable {
    case invalidEmail
    case emptyPassword
    case serverNotFound
    case alreadyAdded
    case wrongCredentials
    case tooManyAttempts
    case offline
    case useBrowser
    case generic

    /// Key in Localizable.strings.
    var key: String {
        switch self {
        case .invalidEmail: return "_m9box_login_err_email_"
        case .emptyPassword: return "_m9box_login_err_password_"
        case .serverNotFound: return "_m9box_login_err_server_"
        case .alreadyAdded: return "_m9box_login_err_exists_"
        case .wrongCredentials: return "_m9box_login_err_credentials_"
        case .tooManyAttempts: return "_m9box_login_err_toomany_"
        case .offline: return "_m9box_login_err_offline_"
        case .useBrowser: return "_m9box_login_err_other_"
        case .generic: return "_m9box_login_err_generic_"
        }
    }
}

struct M9BoxEmail: Equatable {
    /// Trimmed and lowercased: this is the user name on the server.
    let address: String
    let domain: String
}

enum M9BoxLoginLogic {
    /// Trim + lowercase, then: exactly one "@", non-empty local part without spaces, domain with
    /// a dot, only [a-z0-9.-], no dot at the ends and no empty label ("..").
    static func parseEmail(_ raw: String) -> M9BoxEmail? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = address.components(separatedBy: "@")
        guard parts.count == 2 else { return nil }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, local.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard domain.allSatisfy({ allowed.contains($0) }) else { return nil }
        return M9BoxEmail(address: address, domain: domain)
    }

    static func serverURL(domain: String) -> String {
        "https://box." + domain
    }

    /// Same key NCAccount.createAccount uses.
    static func accountName(user: String, urlBase: String) -> String {
        "\(user) \(urlBase)"
    }

    static func isServerUsable(installed: Bool, maintenance: Bool) -> Bool {
        installed && !maintenance
    }

    /// No network at all: the server was not even asked.
    private static let noNetworkCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
    /// Flaky network once the server was already reached.
    private static let flakyNetworkCodes: Set<Int> = noNetworkCodes.union([NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed])

    /// Result of the status.php check: no network, a timeout or a dropped connection is the
    /// network; anything else (DNS, TLS, untrusted certificate, HTML, 404) means "there is no
    /// box there".
    static func error(forServerStatusCode code: Int) -> M9BoxLoginError {
        let network = noNetworkCodes.union([NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost])
        return network.contains(code) ? .offline : .serverNotFound
    }

    /// Result of getapppassword. The HTTP status wins: NKError.errorCode can carry the OCS
    /// code (997) instead of 401. Without an HTTP response it is a transport error.
    static func error(forAppPassword httpStatus: Int?, errorCode: Int) -> M9BoxLoginError {
        if let httpStatus {
            switch httpStatus {
            case 401: return .wrongCredentials
            case 429: return .tooManyAttempts
            default: return .useBrowser
            }
        }
        return flakyNetworkCodes.contains(errorCode) ? .offline : .useBrowser
    }
}

/// Text of an M9 Box key. Only en, pt-BR, pt-PT and es carry these keys and iOS has no
/// per-key fallback, so any other language would show the raw key: use English there.
func m9boxLocalized(_ key: String) -> String {
    let text = NSLocalizedString(key, comment: "")
    guard text == key,
          let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
          let english = Bundle(path: path) else { return text }
    return english.localizedString(forKey: key, value: key, table: nil)
}

// MARK: - UI and flow

#if canImport(UIKit)
import UIKit
import NextcloudKit

/// The e-mail / password form that replaces the server address field on NCLogin.
@MainActor
final class M9BoxLoginForm: UIScrollView, UITextFieldDelegate {
    var onSubmit: ((_ email: String, _ password: String) -> Void)?
    var onBrowser: ((_ email: String) -> Void)?
    /// Top constant of the logo before the keyboard collapsed it.
    var logoTopBeforeKeyboard: CGFloat?

    private let emailField = UITextField()
    private let passwordField = UITextField()
    private let errorLabel = UILabel()
    private let loginButton = UIButton(type: .system)
    private let browserButton = UIButton(type: .system)
    private let textColor: UIColor
    private let textColorOpponent: UIColor

    init(textColor: UIColor, textColorOpponent: UIColor) {
        self.textColor = textColor
        self.textColorOpponent = textColorOpponent
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var email: String { emailField.text ?? "" }

    func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = (message ?? "").isEmpty
        if let message, !message.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    func setBusy(_ busy: Bool) {
        [emailField, passwordField].forEach { $0.isEnabled = !busy }
        loginButton.isEnabled = !busy
        browserButton.isEnabled = !busy
        var config = loginButton.configuration
        config?.showsActivityIndicator = busy
        loginButton.configuration = config
    }

    /// The password is never kept: wipe it as soon as the account exists.
    func clearPassword() {
        passwordField.text = nil
    }

    // MARK: Build

    private func build() {
        keyboardDismissMode = .interactive
        alwaysBounceVertical = false
        showsVerticalScrollIndicator = false
        translatesAutoresizingMaskIntoConstraints = false

        let hint = UILabel()
        hint.text = m9boxLocalized("_m9box_login_hint_")
        hint.textColor = textColor
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.numberOfLines = 0
        hint.textAlignment = .center

        configure(emailField, placeholder: "_m9box_login_email_", identifier: "m9boxLoginEmail")
        emailField.keyboardType = .emailAddress
        emailField.textContentType = .username
        emailField.returnKeyType = .next

        configure(passwordField, placeholder: "_m9box_login_password_", identifier: "m9boxLoginPassword")
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password
        passwordField.returnKeyType = .go

        errorLabel.textColor = textColor
        errorLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "m9boxLoginError"

        var filled = UIButton.Configuration.filled()
        filled.baseBackgroundColor = textColor
        filled.baseForegroundColor = textColorOpponent
        filled.background.cornerRadius = 10
        filled.title = m9boxLocalized("_m9box_login_button_")
        loginButton.configuration = filled
        loginButton.accessibilityIdentifier = "m9boxLoginSubmit"
        loginButton.addTarget(self, action: #selector(submit), for: .touchUpInside)

        var plain = UIButton.Configuration.plain()
        plain.baseForegroundColor = textColor
        plain.title = m9boxLocalized("_m9box_login_browser_")
        browserButton.configuration = plain
        browserButton.accessibilityIdentifier = "m9boxLoginBrowser"
        browserButton.addTarget(self, action: #selector(browser), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [hint, emailField, passwordField, errorLabel, loginButton, browserButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: errorLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let preferredWidth = stack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -80)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -16),
            stack.centerXAnchor.constraint(equalTo: frameLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: frameLayoutGuide.leadingAnchor, constant: 40),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            preferredWidth,
            emailField.heightAnchor.constraint(equalToConstant: 44),
            passwordField.heightAnchor.constraint(equalToConstant: 44),
            loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        // content width = frame width, so only vertical scrolling happens
        contentLayoutGuide.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor).isActive = true
    }

    private func configure(_ field: UITextField, placeholder: String, identifier: String) {
        field.textColor = textColor
        field.tintColor = textColor
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.layer.cornerRadius = 10
        field.layer.borderWidth = 1
        field.layer.borderColor = textColor.cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 15, height: 44))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 15, height: 44))
        field.rightViewMode = .always
        let text = m9boxLocalized(placeholder)
        field.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: textColor.withAlphaComponent(0.85)])
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.accessibilityLabel = text
        field.accessibilityIdentifier = identifier
        field.delegate = self
    }

    // MARK: Actions

    @objc private func submit() {
        endEditing(true)
        onSubmit?(emailField.text ?? "", passwordField.text ?? "")
    }

    @objc private func browser() {
        endEditing(true)
        onBrowser?(emailField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            passwordField.becomeFirstResponder()
        } else {
            submit()
        }
        return false
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

extension NCLogin {
    /// Hook called at the end of NCLogin.viewDidLoad. Swaps the server address UI for the form.
    func setupM9BoxNativeLogin(textColor: UIColor, textColorOpponent: UIColor) {
        guard NCBrandOptions.shared.use_email_login else { return }

        // hide server address, QR code and enforced servers for this brand
        let serverAddressViews: [UIView?] = [baseUrlTextField, loginAddressDetail, loginButton, qrCode, certificate, enforceServersButton, enforceServersDropdownImage]
        serverAddressViews.forEach { $0?.isHidden = true }

        let form = M9BoxLoginForm(textColor: textColor, textColorOpponent: textColorOpponent)
        form.onSubmit = { [weak self] email, password in self?.m9boxSubmit(email: email, password: password) }
        form.onBrowser = { [weak self] email in self?.m9boxLoginWithBrowser(email: email) }
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: imageBrand.bottomAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        m9boxForm = form

        NotificationCenter.default.addObserver(self, selector: #selector(m9boxKeyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(m9boxKeyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// On a small screen the logo makes room for the form while the keyboard is up.
    @objc private func m9boxKeyboardWillChange(_ notification: Notification) {
        guard let form = m9boxForm else { return }
        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let keyboardHeight = notification.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, view.bounds.height - frame.minY)
        let needsRoom = keyboardHeight > 0 && (view.bounds.height - keyboardHeight) < 560
        if needsRoom, form.logoTopBeforeKeyboard == nil {
            form.logoTopBeforeKeyboard = imageBrandConstraintY.constant
            imageBrandConstraintY.constant = -(imageBrand.bounds.height + 16)
        } else if !needsRoom, let top = form.logoTopBeforeKeyboard {
            imageBrandConstraintY.constant = top
            form.logoTopBeforeKeyboard = nil
        } else {
            return
        }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) {
            self.imageBrand.alpha = needsRoom ? 0 : 1
            self.view.layoutIfNeeded()
        }
    }

    // MARK: Flow

    func m9boxShow(_ error: M9BoxLoginError, domain: String = "") {
        let text = m9boxLocalized(error.key)
        m9boxForm?.showError(error == .serverNotFound ? String(format: text, NCBrandOptions.shared.brand, domain) : text)
    }

    func m9boxSubmit(email raw: String, password: String) {
        guard let form = m9boxForm else { return }
        guard let email = M9BoxLoginLogic.parseEmail(raw) else { return m9boxShow(.invalidEmail) }
        guard !password.isEmpty else { return m9boxShow(.emptyPassword) }

        form.showError(nil)
        form.setBusy(true)
        Task {
            let failure = await m9boxPasswordLogin(email: email, password: password)
            if let failure {
                m9boxShow(failure, domain: email.domain)
                form.setBusy(false)
            } else if await NCManageDatabase.shared.getTableAccountAsync(account: M9BoxLoginLogic.accountName(user: email.address, urlBase: M9BoxLoginLogic.serverURL(domain: email.domain))) != nil {
                form.clearPassword()
            } else {
                // createAccount already told the user why (it presents its own alert)
                form.setBusy(false)
            }
        }
    }

    /// NextcloudKit also accepts a certificate the user pinned earlier ("connect anyway" on the
    /// web login), so ask the system alone before the e-mail password can be sent.
    private func m9boxProbeSystemTrust(_ urlBase: String) async -> M9BoxLoginError? {
        guard let url = URL(string: urlBase + "/status.php") else { return .serverNotFound }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            _ = try await session.data(for: request)
            return nil
        } catch {
            return M9BoxLoginLogic.error(forServerStatusCode: (error as NSError).code)
        }
    }

    /// nil = account creation was started (NCAccount reports its own errors).
    private func m9boxPasswordLogin(email: M9BoxEmail, password: String) async -> M9BoxLoginError? {
        let urlBase = M9BoxLoginLogic.serverURL(domain: email.domain)

        if await NCManageDatabase.shared.getTableAccountAsync(account: M9BoxLoginLogic.accountName(user: email.address, urlBase: urlBase)) != nil {
            return .alreadyAdded
        }

        // The password only goes to a host that answers like a Nextcloud with a certificate
        // the system trusts. No "trust this certificate" prompt on this path, on purpose.
        if let untrusted = await m9boxProbeSystemTrust(urlBase) { return untrusted }
        let status = await NextcloudKit.shared.getServerStatusAsync(serverUrl: urlBase, options: NKRequestOptions(customUserAgent: userAgent))
        switch status.result {
        case .failure(let error):
            return M9BoxLoginLogic.error(forServerStatusCode: error.errorCode)
        case .success(let info):
            guard M9BoxLoginLogic.isServerUsable(installed: info.installed, maintenance: info.maintenance) else { return .serverNotFound }
        }

        // No retry: the server throttles repeated wrong passwords. The token on the server is
        // named after the User-Agent.
        let results = await NextcloudKit.shared.getAppPasswordAsync(url: urlBase, user: email.address, password: password, userAgent: userAgent)
        guard results.error == .success, let token = results.token, !token.isEmpty else {
            return M9BoxLoginLogic.error(forAppPassword: results.responseData?.response?.statusCode, errorCode: results.error.errorCode)
        }

        await createAccount(urlBase: urlBase, user: email.address, password: token)
        return nil
    }

    func m9boxLoginWithBrowser(email raw: String) {
        guard let email = M9BoxLoginLogic.parseEmail(raw) else { return m9boxShow(.invalidEmail) }
        m9boxForm?.showError(nil)
        isUrlValid(url: M9BoxLoginLogic.serverURL(domain: email.domain), user: email.address)
    }
}
#endif

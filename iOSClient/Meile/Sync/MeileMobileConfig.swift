//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  iOS cannot create a CalDAV/CardDAV account programmatically, so the "one app"
//  sync path is an Apple Configuration Profile (.mobileconfig): the app builds a
//  profile with com.apple.caldav.account + com.apple.carddav.account payloads for
//  the user's Box server and hands it to iOS to install (Agenda + Contatos land in
//  the phone's native Calendar/Contacts). Credentials come from the signed-in
//  account; the password is intentionally omitted so iOS prompts for it at install
//  (never embed the password in an unsigned profile shared off-device).
//

import Foundation

enum MeileMobileConfig {

    struct Input {
        let host: String        // e.g. box.empresa.com.br
        let username: String    // DAV login user
        let userId: String      // DAV user id (principal path segment)
        let displayName: String // shown in Settings > General > VPN & Device Management
    }

    /// Build the .mobileconfig XML for the given account. Returns UTF-8 data ready
    /// to write to a `.mobileconfig` file.
    static func build(_ input: Input) -> Data {
        let root = "network.m9.box.sync.\(input.host)"
        let principal = "/remote.php/dav/principals/users/\(input.userId)/"

        let caldav = accountPayload(
            type: "com.apple.caldav.account",
            keyPrefix: "CalDAV",
            description: "M9 Box — Agenda",
            host: input.host,
            username: input.username,
            principal: principal,
            identifier: "\(root).caldav"
        )
        let carddav = accountPayload(
            type: "com.apple.carddav.account",
            keyPrefix: "CardDAV",
            description: "M9 Box — Contatos",
            host: input.host,
            username: input.username,
            principal: principal,
            identifier: "\(root).carddav"
        )

        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadIdentifier</key><string>\(esc(root))</string>
            <key>PayloadUUID</key><string>\(UUID().uuidString)</string>
            <key>PayloadDisplayName</key><string>\(esc(input.displayName))</string>
            <key>PayloadDescription</key><string>Sincroniza a agenda e os contatos do M9 Box com o iPhone.</string>
            <key>PayloadOrganization</key><string>M9 Box</string>
            <key>PayloadRemovalDisallowed</key><false/>
            <key>PayloadContent</key>
            <array>
        \(caldav)
        \(carddav)
            </array>
        </dict>
        </plist>
        """
        return Data(body.utf8)
    }

    private static func accountPayload(
        type: String,
        keyPrefix: String,
        description: String,
        host: String,
        username: String,
        principal: String,
        identifier: String
    ) -> String {
        """
                <dict>
                    <key>PayloadType</key><string>\(type)</string>
                    <key>PayloadVersion</key><integer>1</integer>
                    <key>PayloadIdentifier</key><string>\(esc(identifier))</string>
                    <key>PayloadUUID</key><string>\(UUID().uuidString)</string>
                    <key>PayloadDisplayName</key><string>\(esc(description))</string>
                    <key>\(keyPrefix)AccountDescription</key><string>\(esc(description))</string>
                    <key>\(keyPrefix)HostName</key><string>\(esc(host))</string>
                    <key>\(keyPrefix)Username</key><string>\(esc(username))</string>
                    <key>\(keyPrefix)UseSSL</key><true/>
                    <key>\(keyPrefix)Port</key><integer>443</integer>
                    <key>\(keyPrefix)PrincipalURL</key><string>\(esc(principal))</string>
                </dict>
        """
    }

    /// Minimal XML entity escaping for the string values we emit.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import UserNotifications
import NextcloudKit

class NCPushNotification {
    static let shared = NCPushNotification()
    let global = NCGlobal.shared

    /// Each Box is its own push proxy: <urlBase>/m9push (same protocol as the official one).
    func proxyURL(urlBase: String) -> String {
        (urlBase.hasSuffix("/") ? String(urlBase.dropLast()) : urlBase) + "/m9push"
    }

    /// Two registrations per account, both with the same key pair: the alert token ("apns", shown by
    /// the Notification Service Extension) and the PushKit token ("apns-voip", Talk calls via CallKit).
    /// The VoIP one is kept under the account key + "#voip".
    func subscribingNextcloudServerPushNotification(account: String, urlBase: String) async {
        let preferences = NCPreferences()
        await subscribe(account: account, urlBase: urlBase, token: preferences.deviceTokenPushNotification, platform: "apns")
        await subscribe(account: account, urlBase: urlBase, token: preferences.deviceTokenVoipPushNotification, platform: "apns-voip")
    }

    private func subscribe(account: String, urlBase: String, token: String, platform: String) async {
        let preferences = NCPreferences()
        let proxyServerUrl = proxyURL(urlBase: urlBase)
        let slot = platform == "apns-voip" ? account + "#voip" : account
        guard !token.isEmpty,
              let pushTokenHash = NCEndToEndEncryption.shared().createSHA512(token) else {
            return
        }

        var privateKey = preferences.getPushNotificationPrivateKey(account: account)
        var publicKey = preferences.getPushNotificationPublicKey(account: account)

        if privateKey == nil || publicKey == nil {
            guard let keyPair = NCPushNotificationEncryption.shared().generatePushNotificationsKeyPair() else {
                return
            }
            privateKey = keyPair.privateKey
            publicKey = keyPair.publicKey

            preferences.setPushNotificationPrivateKey(account: account, data: privateKey)
            preferences.setPushNotificationPublicKey(account: account, data: publicKey)
        }

        guard privateKey != nil,
              let publicKey,
              let devicePublicKey = String(data: publicKey, encoding: .utf8) else {
            return
        }

        let responsePN = await NextcloudKit.shared.subscribingPushNotificationAsync(serverUrl: urlBase,
                                                                                    pushTokenHash: pushTokenHash,
                                                                                    devicePublicKey: devicePublicKey,
                                                                                    proxyServerUrl: proxyServerUrl, account: account) { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                            path: urlBase,
                                                                                            name: "subscribingPushNotification")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
        }

        guard responsePN.error == .success,
              let deviceIdentifier = responsePN.deviceIdentifier,
              let signature = responsePN.signature,
              let subscribingPublicKey = responsePN.publicKey
        else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Subscribed (\(platform)) to Push Notification Server \(urlBase) with error \(responsePN.error.errorDescription)")
            return
        }

        // NextcloudKit's proxy call has no room for the extra `platform` field, so this one is ours.
        guard let url = URL(string: proxyServerUrl + "/devices?format=json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(NCBrandOptions.shared.getUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "pushToken", value: token),
            URLQueryItem(name: "deviceIdentifier", value: deviceIdentifier),
            URLQueryItem(name: "deviceIdentifierSignature", value: signature),
            URLQueryItem(name: "userPublicKey", value: subscribingPublicKey),
            URLQueryItem(name: "platform", value: platform)
        ]
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)

        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Subscribed (\(platform)) to Push Notification Server Proxy \(proxyServerUrl) with status \(status)")
            return
        }

        preferences.setPushNotificationDeviceIdentifier(account: slot, deviceIdentifier: deviceIdentifier)
        preferences.setPushNotificationDeviceIdentifierSignature(account: slot, deviceIdentifierSignature: signature)
        preferences.setPushNotificationSubscribingPublicKey(account: slot, publicKey: subscribingPublicKey)
    }

    func unsubscribingNextcloudServerPushNotification(account: String, urlBase: String) async {
        let preferences = NCPreferences()
        let proxyServerUrl = proxyURL(urlBase: urlBase)

        let responsePN = await NextcloudKit.shared.unsubscribingPushNotificationAsync(serverUrl: urlBase,
                                                                                      account: account) { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                            path: urlBase,
                                                                                            name: "unsubscribingPushNotification")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
        }
        nkLog(tag: self.global.logTagPN, emoji: .info, message: "Unsubscribed to Push Notification Server \(urlBase) with error \(responsePN.error.errorDescription)")

        let userAgent = String(format: "%@  (Strict VoIP)", NCBrandOptions.shared.getUserAgent())
        let options = NKRequestOptions(customUserAgent: userAgent)
        for slot in [account, account + "#voip"] {
            guard let deviceIdentifier = preferences.getPushNotificationDeviceIdentifier(account: slot), !deviceIdentifier.isEmpty,
                  let signature = preferences.getPushNotificationDeviceIdentifierSignature(account: slot),
                  let subscribingPublicKey = preferences.getPushNotificationSubscribingPublicKey(account: slot) else {
                continue
            }
            let responseProxy = await NextcloudKit.shared.unsubscribingPushProxyAsync(proxyServerUrl: proxyServerUrl,
                                                                                      deviceIdentifier: deviceIdentifier,
                                                                                      signature: signature,
                                                                                      publicKey: subscribingPublicKey,
                                                                                      account: account,
                                                                                      options: options) { task in
                Task {
                    let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                                path: proxyServerUrl,
                                                                                                name: "unsubscribingPushProxy")
                    await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                }
            }
            nkLog(tag: self.global.logTagPN, emoji: .info, message: "Unsubscribed to Push Notification Server Proxy \(proxyServerUrl) with error \(responseProxy.error.errorDescription)")
        }
    }

    func applicationdidReceiveRemoteNotification(userInfo: [AnyHashable: Any], completion: @escaping (_ result: UIBackgroundFetchResult) -> Void) {
        if let message = userInfo["subject"] as? String {
            for tblAccount in NCManageDatabase.shared.getAllTableAccount() {
                if let privateKey = NCPreferences().getPushNotificationPrivateKey(account: tblAccount.account),
                   let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: privateKey),
                   let jsonData = decryptedMessage.data(using: .utf8) {
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            let nid = jsonObject["nid"] as? Int
                            let delete = jsonObject["delete"] as? Bool
                            let deleteAll = jsonObject["delete-all"] as? Bool
                            if let delete, delete, let nid {
                                removeNotificationWithNotificationId(nid, usingDecryptionKey: privateKey)
                            } else if let deleteAll, deleteAll {
                                cleanAllNotifications()
                            }
                        } else {
                            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to convert JSON data dictionary.")
                        }
                    } catch {
                        nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to parsing JSON data dictionary.")
                    }
                }
            }
        }
        completion(UIBackgroundFetchResult.noData)
    }

    func removeNotificationWithNotificationId(_ notificationId: Int, usingDecryptionKey key: Data) {
        // Check in pending notifications
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            for request in requests {
                if let message = request.content.userInfo["subject"] as? String,
                   let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: key),
                   let jsonData = decryptedMessage.data(using: .utf8) {
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            let nid = jsonObject["nid"] as? Int
                            if nid == notificationId {
                                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.identifier])
                            }
                        } else {
                            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to convert JSON data dictionary.")
                        }
                    } catch {
                        nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to parsing JSON data dictionary.")
                    }
                }
            }
        }
        // Check in delivered notifications
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            for notification in notifications {
                if let message = notification.request.content.userInfo["subject"] as? String,
                   let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: key),
                   let jsonData = decryptedMessage.data(using: .utf8) {
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            let nid = jsonObject["nid"] as? Int
                            if nid == notificationId {
                                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
                            }
                        } else {
                            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to convert JSON data dictionary.")
                        }
                    } catch {
                        nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to parsing JSON data dictionary.")
                    }
                }
            }
        }
    }

    func cleanAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

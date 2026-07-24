//
//  M9 Box - Meile branded Nextcloud client
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Minimal vCard (3.0/4.0) -> CNMutableContact mapper for the native Contacts
//  sync. Handles line unfolding, escaping and the fields the phone actually shows
//  (name, phones, emails, org/title, address, note, url, nickname, birthday,
//  photo). Unknown properties are ignored — this mirrors the Android reader, which
//  also maps a curated subset.
//

import Contacts
import Foundation

enum MeileVCard {

    /// Parse one vCard into a CNMutableContact. Returns nil if it has no usable
    /// name and no other content worth storing.
    static func parse(_ vcard: String) -> CNMutableContact? {
        let lines = unfold(vcard)
        let contact = CNMutableContact()
        var phones = [CNLabeledValue<CNPhoneNumber>]()
        var emails = [CNLabeledValue<NSString>]()
        var addresses = [CNLabeledValue<CNPostalAddress>]()
        var urls = [CNLabeledValue<NSString>]()
        var hasAny = false

        for line in lines {
            guard let prop = property(line) else { continue }
            let name = prop.name.uppercased()
            let value = prop.value
            switch name {
            case "FN":
                // Kept as a fallback only; N drives the structured name.
                if contact.givenName.isEmpty && contact.familyName.isEmpty {
                    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                    contact.givenName = parts.first ?? value
                    if parts.count > 1 { contact.familyName = parts[1] }
                }
                hasAny = hasAny || !value.isEmpty
            case "N":
                let comps = structured(value)
                contact.familyName = comps.count > 0 ? comps[0] : contact.familyName
                contact.givenName = comps.count > 1 ? comps[1] : contact.givenName
                if comps.count > 2 { contact.middleName = comps[2] }
                if comps.count > 3 { contact.namePrefix = comps[3] }
                if comps.count > 4 { contact.nameSuffix = comps[4] }
                hasAny = hasAny || !contact.givenName.isEmpty || !contact.familyName.isEmpty
            case "TEL":
                guard !value.isEmpty else { break }
                phones.append(CNLabeledValue(label: phoneLabel(prop.params), value: CNPhoneNumber(stringValue: value)))
                hasAny = true
            case "EMAIL":
                guard !value.isEmpty else { break }
                emails.append(CNLabeledValue(label: emailLabel(prop.params), value: value as NSString))
                hasAny = true
            case "ORG":
                let comps = structured(value)
                contact.organizationName = comps.first ?? value
                if comps.count > 1 { contact.departmentName = comps[1] }
                hasAny = true
            case "TITLE":
                contact.jobTitle = value
                hasAny = true
            case "NICKNAME":
                contact.nickname = value.split(separator: ",").first.map(String.init) ?? value
                hasAny = true
            case "NOTE":
                contact.note = value
                hasAny = true
            case "URL":
                guard !value.isEmpty else { break }
                urls.append(CNLabeledValue(label: CNLabelURLAddressHomePage, value: value as NSString))
                hasAny = true
            case "ADR":
                let comps = structured(value)
                let addr = CNMutablePostalAddress()
                // vCard ADR: PO;ext;street;locality;region;postal;country
                if comps.count > 2 { addr.street = comps[2] }
                if comps.count > 3 { addr.city = comps[3] }
                if comps.count > 4 { addr.state = comps[4] }
                if comps.count > 5 { addr.postalCode = comps[5] }
                if comps.count > 6 { addr.country = comps[6] }
                addresses.append(CNLabeledValue(label: CNLabelHome, value: addr))
                hasAny = true
            case "BDAY":
                if let comps = birthday(value) { contact.birthday = comps; hasAny = true }
            case "PHOTO":
                if let data = photoData(prop) { contact.imageData = data; hasAny = true }
            default:
                break
            }
        }

        guard hasAny else { return nil }
        contact.phoneNumbers = phones
        contact.emailAddresses = emails
        contact.postalAddresses = addresses
        contact.urlAddresses = urls
        return contact
    }

    // MARK: parsing helpers

    /// Join RFC 6350 folded lines (continuation lines begin with a space or tab).
    private static func unfold(_ vcard: String) -> [String] {
        var out = [String]()
        for raw in vcard.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !out.isEmpty {
                out[out.count - 1] += String(raw.dropFirst())
            } else {
                out.append(raw)
            }
        }
        return out
    }

    private struct Property { let name: String; let params: [String: String]; let value: String }

    private static func property(_ line: String) -> Property? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = unescape(String(line[line.index(after: colon)...]))
        let headParts = head.components(separatedBy: ";")
        guard let name = headParts.first, !name.isEmpty else { return nil }
        var params = [String: String]()
        var bareTypes = [String]()
        for p in headParts.dropFirst() {
            let kv = p.components(separatedBy: "=")
            if kv.count == 2 {
                params[kv[0].uppercased()] = kv[1].uppercased()
            } else if !p.isEmpty {
                // vCard 3.0 bare token, e.g. TEL;HOME;VOICE:... — treat as a TYPE.
                bareTypes.append(p.uppercased())
            }
        }
        if !bareTypes.isEmpty {
            let existing = params["TYPE"].map { [$0] } ?? []
            params["TYPE"] = (existing + bareTypes).joined(separator: ",")
        }
        return Property(name: name, params: params, value: value)
    }

    /// Split a structured value on unescaped `;`.
    private static func structured(_ value: String) -> [String] {
        splitUnescaped(value, on: ";").map { unescape($0) }
    }

    private static func splitUnescaped(_ s: String, on sep: Character) -> [String] {
        var out = [String]()
        var cur = ""
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false }
            else if ch == "\\" { cur.append(ch); escaped = true }
            else if ch == sep { out.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func typeSet(_ params: [String: String]) -> Set<String> {
        Set((params["TYPE"] ?? "").split(separator: ",").map { String($0).uppercased() })
    }

    private static func phoneLabel(_ params: [String: String]) -> String {
        let t = typeSet(params)
        if t.contains("CELL") || t.contains("MOBILE") { return CNLabelPhoneNumberMobile }
        if t.contains("WORK") { return CNLabelWork }
        if t.contains("HOME") { return CNLabelHome }
        if t.contains("FAX") { return CNLabelPhoneNumberOtherFax }
        return CNLabelOther
    }

    private static func emailLabel(_ params: [String: String]) -> String {
        let t = typeSet(params)
        if t.contains("WORK") { return CNLabelWork }
        if t.contains("HOME") { return CNLabelHome }
        return CNLabelOther
    }

    private static func birthday(_ value: String) -> DateComponents? {
        // Accept YYYY-MM-DD or YYYYMMDD.
        let digits = value.filter { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let y = Int(digits.prefix(4))
        let m = Int(digits.dropFirst(4).prefix(2))
        let d = Int(digits.dropFirst(6).prefix(2))
        guard let month = m, let day = d, month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = month
        comps.day = day
        return comps
    }

    private static func photoData(_ prop: Property) -> Data? {
        // vCard 3.0: PHOTO;ENCODING=b;TYPE=JPEG:<base64>. vCard 4.0: PHOTO:data:image/jpeg;base64,<b64>.
        var b64 = prop.value
        if let range = b64.range(of: "base64,") { b64 = String(b64[range.upperBound...]) }
        b64 = b64.filter { !$0.isWhitespace }
        return Data(base64Encoded: b64)
    }
}

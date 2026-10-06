// Live check of MeileTasksRepository against a Nextcloud (lab). Not part of CI.
// Run: Tests/MeileTasks/e2e.sh <baseURL> <user> <password-file>
import Foundation

let args = CommandLine.arguments
let base = URL(string: args[1])!
let user = args[2]
let pw = try! String(contentsOfFile: args[3]).trimmingCharacters(in: .whitespacesAndNewlines)
let auth = "Basic " + Data("\(user):\(pw)".utf8).base64EncodedString()
let client = MeileCalDavClient(baseURL: base, authHeader: auth, userId: user)
let repo = MeileTasksRepository(client: client)
var fails = 0
func check(_ ok: Bool, _ m: String) { print(ok ? "ok: \(m)" : "FAIL: \(m)"); if !ok { fails += 1 } }

func run() async throws {
    var lists = try await repo.loadLists()
    print("lists:", lists.map(\.displayName))
    if !lists.contains(where: { $0.displayName == "E2E iOS" }) {
        try await repo.createList(name: "E2E iOS")
        lists = try await repo.loadLists()
    }
    let list = lists.first { $0.displayName == "E2E iOS" }!
    check(true, "task list discovered/created: \(list.href)")
    let personal = try await client.discoverCalendars().map(\.displayName)
    check(!personal.contains("E2E iOS"), "VTODO-only list not offered as agenda (\(personal))")

    let stamp = "e2e-\(Int(Date().timeIntervalSince1970))"
    try await repo.create(MeileTaskDraft(title: stamp, notes: "nota", due: Date().addingTimeInterval(86400), dueAllDay: true, completed: false, priority: 1), in: list)
    var tasks = try await repo.loadTasks(list: list)
    guard var t = tasks.first(where: { $0.title == stamp }) else { check(false, "created task listed"); return }
    check(t.priority == 1 && t.notes == "nota" && t.dueAllDay && !t.completed, "created task round-trips from server")

    try await repo.update(t, draft: MeileTaskDraft(title: stamp + " editada", notes: nil, due: nil, dueAllDay: false, completed: false, priority: 0))
    tasks = try await repo.loadTasks(list: list)
    t = tasks.first { $0.title == stamp + " editada" }!
    check(t.due == nil && t.notes == nil, "edit applied on server")

    // Stale write: someone else changes the task after we loaded it -> 412, not a lost update.
    let other = try await client.getResource(href: t.resourceHref)
    try await client.putResource(href: t.resourceHref, ics: other.ics.replacingOccurrences(of: "SUMMARY:", with: "SUMMARY:outro cliente "), ifMatch: other.etag, isNew: false)
    do {
        _ = try await client.putResource(href: t.resourceHref, ics: other.ics, ifMatch: t.etag, isNew: false)
        check(false, "stale If-Match must be rejected")
    } catch let e as MeileCalDavError { check(e.code == 412, "stale write rejected with 412 (got \(e.code))") }

    tasks = try await repo.loadTasks(list: list)
    t = tasks.first { $0.title.hasPrefix("outro cliente") }!
    try await repo.setCompleted(t, true)
    tasks = try await repo.loadTasks(list: list)
    t = tasks.first { $0.title.hasPrefix("outro cliente") }!
    check(t.completed, "completed on server")
    try await repo.setCompleted(t, false)
    tasks = try await repo.loadTasks(list: list)
    check(tasks.first { $0.title.hasPrefix("outro cliente") }?.completed == false, "reopened on server")

    for x in tasks where x.title.hasPrefix("outro cliente") || x.title.hasPrefix("e2e-") { try await repo.delete(x) }
    tasks = try await repo.loadTasks(list: list)
    check(tasks.isEmpty, "deleted")
}

Task {
    do { try await run() } catch { print("FAIL: error \(error)"); fails += 1 }
    print(fails == 0 ? "E2E PASSED" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
RunLoop.main.run()

// swiftc-run harness for the VTODO parser/builder and the VTODO-aware discovery.
// Run: Tests/MeileTasks/run.sh   (no Xcode project involved)
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL: \(msg)") } else { print("ok: \(msg)") } }

let list = MeileCalendarCollection(href: "/dav/cal/tarefas/", displayName: "T", color: nil, ctag: nil, syncToken: nil, readOnly: false)

// 1. Discovery: VTODO-only list is kept for VTODO, dropped for VEVENT (and vice versa).
let xml = """
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
<d:response><d:href>/dav/cal/</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
<d:response><d:href>/dav/cal/personal/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype><d:displayname>Personal</d:displayname><cal:supported-calendar-component-set><cal:comp name="VEVENT"/></cal:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/dav/cal/tarefas/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype><d:displayname>Tarefas</d:displayname><cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/dav/cal/both/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype><d:displayname>Both</d:displayname><cal:supported-calendar-component-set><cal:comp name="VEVENT"/><cal:comp name="VTODO"/></cal:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>
""".data(using: .utf8)!
let todos = MeileMultiStatus.parseCalendars(xml, ownHref: "/dav/cal/", component: "VTODO").map(\.href)
let events = MeileMultiStatus.parseCalendars(xml, ownHref: "/dav/cal/").map(\.href)
check(todos == ["/dav/cal/tarefas/", "/dav/cal/both/"], "VTODO discovery = \(todos)")
check(events == ["/dav/cal/personal/", "/dav/cal/both/"], "VEVENT discovery unchanged = \(events)")

// 2. Parse: folded SUMMARY, escapes, VALARM DESCRIPTION must not leak, date DUE, completed.
let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:a@x\r\nSUMMARY:Comprar p\r\n ao\\, leite\r\nDESCRIPTION:nota\\nlinha 2\r\nDUE;VALUE=DATE:20261015\r\nPRIORITY:1\r\nSTATUS:COMPLETED\r\nX-CUSTOM:keep\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:alarme\r\nTRIGGER:-PT5M\r\nEND:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
let res = MeileRemoteResource(href: "/dav/cal/tarefas/a.ics", etag: "e1", ics: ics)
let t = MeileVTodo.parse(list: list, resource: res)
check(t.count == 1, "one task parsed")
check(t[0].title == "Comprar pao, leite", "folded+escaped title: \(t[0].title)")
check(t[0].notes == "nota\nlinha 2", "notes keep alarm description out: \(String(describing: t[0].notes))")
check(t[0].dueAllDay && t[0].due != nil, "all-day due")
check(t[0].completed && t[0].priority == 1, "completed + priority")

// 3. Edit: managed props rewritten, X-CUSTOM and VALARM kept (with its DESCRIPTION), completion toggles.
var d = MeileTaskDraft(title: "Novo; titulo", notes: nil, due: nil, dueAllDay: false, completed: false, priority: 0)
let edited = MeileVTodo.applyEdit(existingICS: ics, draft: d, now: Date(timeIntervalSince1970: 1_800_000_000))
check(edited.contains("SUMMARY:Novo\\; titulo"), "summary rewritten + escaped")
check(!edited.contains("Comprar") && !edited.contains("DUE") && !edited.contains("PRIORITY:1"), "old values gone")
check(edited.contains("X-CUSTOM:keep"), "unknown property preserved")
check(edited.contains("DESCRIPTION:alarme") && edited.contains("TRIGGER:-PT5M"), "VALARM untouched")
check(edited.contains("STATUS:NEEDS-ACTION") && !edited.contains("COMPLETED:"), "uncompleted")
d.completed = true
let done = MeileVTodo.applyEdit(existingICS: edited, draft: d, now: Date(timeIntervalSince1970: 1_800_000_000))
check(done.contains("STATUS:COMPLETED") && done.contains("PERCENT-COMPLETE:100") && done.contains("COMPLETED:2027"), "completed stamp")
check(MeileVTodo.parse(list: list, resource: MeileRemoteResource(href: "h", etag: nil, ics: done)).first?.completed == true, "round trip completed")

// 4. Recurring: override VTODO first is left alone, master edited.
let rec = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:r@x\r\nRECURRENCE-ID:20261001T100000Z\r\nSUMMARY:override\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:r@x\r\nSUMMARY:master\r\nRRULE:FREQ=DAILY\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
let recEdit = MeileVTodo.applyEdit(existingICS: rec, draft: d, now: Date())
check(recEdit.contains("SUMMARY:override") && !recEdit.contains("SUMMARY:master") && recEdit.contains("RRULE:FREQ=DAILY"), "override kept, master rewritten")
check(MeileVTodo.parse(list: list, resource: MeileRemoteResource(href: "h", etag: nil, ics: rec)).count == 1, "override not listed")

// 5. New task round-trips with due datetime.
let due = Date(timeIntervalSince1970: 1_800_100_000)
let built = MeileVTodo.buildICS(MeileTaskDraft(title: "X", notes: "n", due: due, dueAllDay: false, completed: false, priority: 5), uid: "u@m9box")
let back = MeileVTodo.parse(list: list, resource: MeileRemoteResource(href: "h", etag: nil, ics: built))
check(back.count == 1 && back[0].due.map { abs($0.timeIntervalSince(due)) < 1 } == true && back[0].priority == 5, "build -> parse round trip")

// 6. RELATED-TO -> parentUid: absent / plain / PARENT / CHILD / SIBLING / params / folded / empty.
func parent(_ lines: String...) -> String? {
    let ics = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:k@x\r\nSUMMARY:k\r\n" + lines.joined(separator: "\r\n") + "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
    return MeileVTodo.parse(list: list, resource: MeileRemoteResource(href: "h", etag: nil, ics: ics)).first?.parentUid
}
check(parent("STATUS:NEEDS-ACTION") == nil, "no RELATED-TO -> nil")
check(parent("RELATED-TO:p1") == "p1", "plain RELATED-TO")
check(parent("RELATED-TO;RELTYPE=PARENT:p2") == "p2", "RELTYPE=PARENT")
check(parent("RELATED-TO;reltype=parent:p3") == "p3", "reltype case-insensitive")
check(parent("RELATED-TO;RELTYPE=CHILD:c1") == nil, "RELTYPE=CHILD ignored")
check(parent("RELATED-TO;RELTYPE=SIBLING:s1") == nil, "RELTYPE=SIBLING ignored")
check(parent("RELATED-TO;RELTYPE=CHILD:c1", "RELATED-TO:p4", "RELATED-TO:p5") == "p4", "first parent wins, child skipped")
check(parent("RELATED-TO;X-FOO=bar;RELTYPE=PARENT:p6") == "p6", "extra params")
check(parent("RELATED-TO:abc", " def") == "abcdef", "folded line")
check(parent("RELATED-TO:   ") == nil, "empty value -> nil")
check(parent("RELATED-TO:  p7  ") == "p7", "value trimmed")

// 7. Edits keep RELATED-TO (also when completing).
let sub = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:s@x\r\nSUMMARY:sub\r\nRELATED-TO;RELTYPE=PARENT:p@x\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
let subEdit = MeileVTodo.applyEdit(existingICS: sub, draft: MeileTaskDraft(title: "sub2", notes: nil, due: nil, dueAllDay: false, completed: true, priority: 0), now: Date())
check(subEdit.contains("RELATED-TO;RELTYPE=PARENT:p@x"), "edit/complete keeps RELATED-TO")
check(MeileVTodo.parse(list: list, resource: MeileRemoteResource(href: "h", etag: nil, ics: subEdit)).first?.parentUid == "p@x", "parentUid after edit")

// 8. Tree.
func task(_ uid: String, _ parent: String? = nil, done: Bool = false, list: String = "L") -> MeileTask {
    MeileTask(uid: uid, listHref: list, resourceHref: "\(list)/\(uid).ics", etag: nil, title: uid, notes: nil, due: nil,
              dueAllDay: false, completed: done, priority: 0, recurring: false, parentUid: parent)
}
func shape(_ tasks: [MeileTask]) -> String { MeileTaskTree.flatten(tasks).map { String(repeating: ">", count: $0.depth) + $0.task.uid }.joined(separator: " ") }
check(shape([task("a"), task("b", "a"), task("c", "b"), task("d")]) == "a >b >>c d", "3 levels")
check(shape([task("b", "a"), task("a"), task("c", "a")]) == "a >b >c", "child listed before parent, siblings keep section order")
check(shape([task("o", "gone")]) == "o", "orphan is a root")
check(shape([task("a", "a")]) == "a", "self parent is a root")
check(shape([task("x", "y"), task("y", "x"), task("z", "y")]) == "x >y >>z", "cycle: no loop, nothing lost")
check(shape([task("a"), task("b", "a", list: "M")]) == "a b", "parent must be in the same list")
let dup = [task("a"), MeileTask(uid: "a", listHref: "L", resourceHref: "L/a2.ics", etag: nil, title: "a2", notes: nil, due: nil, dueAllDay: false, completed: false, priority: 0, recurring: false, parentUid: nil), task("c", "a")]
check(MeileTaskTree.flatten(dup).map { "\($0.depth)\($0.task.title)" } == ["0a", "1c", "0a2"], "duplicate uid: first in section order is the parent")
let openChild = [task("p", done: true), task("c", "p"), task("q", done: true), task("d", "q", done: true)]
check(shape(openChild.filter { !$0.completed }) == "c" && shape(openChild.filter { $0.completed }) == "p q >d", "open child of done parent is a root of the open section")

// 9. Real server responses (CalDAV REPORT), through the app's own parsing path.
func fixture(_ name: String, _ href: String) -> [MeileTask] {
    let data = FileManager.default.contents(atPath: "Tests/MeileTasks/fixtures/\(name).xml")!
    let l = MeileCalendarCollection(href: href, displayName: name, color: nil, ctag: nil, syncToken: nil, readOnly: false)
    return MeileMultiStatus.parseResources(data).flatMap { MeileVTodo.parse(list: l, resource: $0) }
        .sorted { $0.title < $1.title }  // stable order for the test
}
func titles(_ tasks: [MeileTask]) -> String { MeileTaskTree.flatten(tasks).map { String(repeating: ">", count: $0.depth) + $0.task.title }.joined(separator: " | ") }
let tarefas = fixture("hier-tarefas-2", "/hier-tarefas-2/")
check(tarefas.count == 5, "Tasks app fixture: 5 tasks")
check(titles(tarefas.filter { !$0.completed }) == "tarefa 4 | tarefas (hier-tarefas-2) | >nova sub RC | >tarefa 1", "Tasks app open section (child of completed parent is root): \(titles(tarefas.filter { !$0.completed }))")
check(titles(tarefas.filter { $0.completed }) == "tarefa 2", "Tasks app done section")
let deck = fixture("app-generated--deck--board-2", "/deck/")
check(deck.count == 6, "Deck fixture: 6 tasks")
check(titles(deck) == "List : Aprovação | >Cartão 1 de Aprovação | >Cartão 2 de Aprovação | List : Concluído | >Cartão 1 de Concluído | >Cartão 2 de Concluído", "Deck cards sit under their stack: \(titles(deck))")
let ctl = fixture("hier-controle", "/hier-controle/")
check(ctl.count == 10, "mixed fixture: 10 tasks")
check(titles(ctl) == "tarefas (hier-controle) | >tarefa 1 | >tarefa 3 | >>tarefa 2 | >>>tarefa 4 | tarefas (hier-tarefas-5) | >tarefa 1 | >tarefa 3 | >>tarefa 2 | >>>tarefa 4", "mixed fixture, two trees: \(titles(ctl))")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

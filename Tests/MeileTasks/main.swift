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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

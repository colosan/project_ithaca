// `Ithaca --selftest-perf`: typing-latency bench on the real ManuscriptView text view, offscreen, in-memory library.
// Loads Korean sheets of 5k / 20k / 60k / 120k characters (headings, scene breaks, emphasis), then types 300
// characters in the middle — once as marked-text composition (jamo steps, like the 2-set IME), once as plain inserts —
// and measures main-thread time per keystroke: the event itself, a forced display (layout + draw) and every run-loop
// pass until the next key (SwiftUI updates, async reveal…). Debounced work that fires in typing pauses (styling,
// counts) is reported separately as "settle". Budget (docs/research/2026-10-24 §2.2/6, §6/12): p95 < 8 ms at 20k,
// < 16 ms at 120k, open 120k < 300 ms. Prints a table; exit 1 if a budget is missed. Nothing on disk.
import AppKit
import SwiftUI

@MainActor
enum PerfSelfTest {
    /// PERF_SIZES=20000,120000 limits the run (profiling).
    static let sizes = ProcessInfo.processInfo.environment["PERF_SIZES"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [5_000, 20_000, 60_000, 120_000]
    static let keyGap = 0.02  // seconds between keystrokes (a fast typist)
    static let pauseEvery = ProcessInfo.processInfo.environment["PERF_PAUSE_EVERY"].flatMap { Int($0) } ?? 30  // keystrokes between typing pauses
    static let pause = 0.45  // longer than the style (150 ms) and count (250 ms) debounces

    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // A background, windowless-looking process gets App Nap / efficiency cores; the real editor is a foreground app.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "perf self-test")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let lib = MockLibrary(seeded: false)
        let suite = "io.github.colosan.ithaca.perftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(library: lib, defaults: UserDefaults(suiteName: suite)!)
        model.createProject(title: "Perf", language: .ko, folders: ["연재"], goal: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ShellView().environment(model))
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        guard let tv = findTextView(window.contentView) else { fail("no text view") }
        let busy = BusyMeter()

        var rows: [String] = []
        var misses: [String] = []
        let pid = model.projectId!
        for size in sizes {
            let body = sample(size)
            let id = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: body))!.id
            model.reloadOutline()
            pump(0.2)

            // Open: model switch → SwiftUI update → load + style → first display.
            let t0 = now()
            model.openSheet(id)
            while (tv.string as NSString).length != (body as NSString).length { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
            window.displayIfNeeded()
            let openWall = now() - t0
            busy.reset()
            pump(0.3)  // the async reveal / focus pass after load belongs to opening too
            let open = openWall + busy.total

            // Full markup restyle (what a markup-mode / text-size change costs).
            let coordinator = model.editor as? ManuscriptView.Coordinator
            let r0 = now()
            coordinator?.debugRestyleAll()
            window.displayIfNeeded()
            let restyle = now() - r0

            let c0 = now()
            _ = TextMetrics.counts(tv.string)
            let counts = now() - c0

            let mid = middle(of: tv.string as NSString)
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: mid, length: 0))
            pump(0.5)
            let comp = type(tv, window, busy, composing: true)
            pump(0.6)
            let mid2 = middle(of: tv.string as NSString)
            tv.setSelectedRange(NSRange(location: mid2, length: 0))
            pump(0.5)
            let plain = type(tv, window, busy, composing: false)
            pump(0.6)
            let mem = footprintMB()

            // Sanity: the typing landed where it was typed, and styling never ate characters.
            let grown = (tv.string as NSString).length - (body as NSString).length
            if grown != comp.chars + plain.chars { misses.append("\(size): text grew \(grown), typed \(comp.chars + plain.chars)") }

            func f(_ s: Double) -> String { String(format: "%6.2f", s * 1000) }
            rows.append(String(format: "%7d │ %@ %@ %@ %@ │ %@ %@ %@ %@ │ %@ %@ %@ │ %@ %@ %@ │ %5.0f",
                               size,
                               f(comp.p(0.5)), f(comp.p(0.95)), f(comp.max), f(comp.cpuP(0.95)),
                               f(plain.p(0.5)), f(plain.p(0.95)), f(plain.max), f(plain.cpuP(0.95)),
                               f(max(comp.settleP50, plain.settleP50)), f(max(comp.settleMax, plain.settleMax)), f(max(comp.hitch, plain.hitch)),
                               f(open), f(restyle), f(counts), mem))
            let p95 = max(comp.p(0.95), plain.p(0.95))
            if size <= 20_000, p95 > 0.008 { misses.append("\(size): p95 \(f(p95)) ms > 8 ms") }
            if p95 > 0.016 { misses.append("\(size): p95 \(f(p95)) ms > 16 ms") }
            if size == 120_000, open > 0.3 { misses.append("120k open \(f(open)) ms > 300 ms") }
            model.flushSave()
        }
        print("")
        print("main-thread ms per keystroke (300 chars typed mid-sheet; composition = 3 marked-text steps per syllable)")
        print("    chars │ compose p50    p95    max cpu95 │ plain   p50    p95    max cpu95 │ settle p50    max  hitch │   open restyle counts │ mem MB")
        print("  ────────┼────────────────────────────────┼────────────────────────────────┼─────────────────────────┼───────────────────────┼───────")
        for r in rows { print(r) }
        print("  p50/p95/max = wall-clock main-thread busy time per keystroke; cpu95 = p95 of main-thread CPU time")
        print("  settle = debounced work in a typing pause (styling, counts); hitch = longest single run-loop pass while typing")
        print("  restyle = full-document markup restyle; counts = TextMetrics.counts on the whole sheet (debounced, off the key path)")
        if misses.isEmpty { print("✓ perf self-test within budget") } else { misses.forEach { print("✗ \($0)") } }
        exit(misses.isEmpty ? 0 : 1)
    }

    /// `--selftest-mem`: the real switching flow (AppModel.openSheet → SwiftUI → editor load), 4 sheets × 20 switches,
    /// a few typed characters per visit, phys_footprint after each. Exit 1 if memory keeps growing after the first round.
    static let memKeys = ProcessInfo.processInfo.environment["MEM_KEYS"].flatMap { Int($0) } ?? 20
    static func runMem() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let lib = MockLibrary(seeded: false)
        let suite = "io.github.colosan.ithaca.memtest"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(library: lib, defaults: UserDefaults(suiteName: suite)!)
        model.createProject(title: "Mem", language: .ko, folders: ["연재"], goal: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ShellView().environment(model))
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        guard let tv = findTextView(window.contentView) else { fail("no text view") }
        let pid = model.projectId!
        let sizes = [120_000, 60_000, 120_000, 20_000]
        let ids = sizes.map { (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: sample($0)))!.id }
        model.reloadOutline()
        pump(0.3)
        let base = footprintMB()
        var marks: [Double] = []
        for i in 0..<20 {
            autoreleasepool {
                model.openSheet(ids[i % ids.count])
                pump(0.3)
                tv.setSelectedRange(NSRange(location: middle(of: tv.string as NSString), length: 0))
                for k in 0..<memKeys {
                    autoreleasepool {
                        let ch = String(plainText[k % plainText.count])
                        tv.insertText(ch, replacementRange: tv.selectedRange())
                        window.displayIfNeeded()
                    }
                    pump(0.01)
                }
                pump(0.3)
                model.flushSave()
            }
            marks.append(footprintMB())
        }
        print(String(format: "phys_footprint MB: start %.0f", base))
        for (i, m) in marks.enumerated() { print(String(format: "  switch %2d (%6d chars): %6.0f", i + 1, sizes[i % sizes.count], m)) }
        let firstRound = marks[sizes.count - 1], last = marks.last!
        let growth = last - firstRound
        print(String(format: "after round 1 %.0f MB → after 20 switches %.0f MB (Δ %.0f MB)", firstRound, last, growth))
        exit(growth > 60 ? 1 : 0)
    }

    // MARK: Typing

    struct Run {
        var keys: [Double] = []
        var cpu: [Double] = []  // main-thread CPU time for the same window (no frequency ramp / scheduling noise)
        var settles: [Double] = []
        var hitch: Double = 0
        var chars = 0
        func p(_ q: Double) -> Double {
            let s = keys.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * q).rounded(.up)) - 1)]
        }
        var max: Double { keys.max() ?? 0 }
        func cpuP(_ q: Double) -> Double {
            let s = cpu.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * q).rounded(.up)) - 1)]
        }
        var settleP50: Double { let s = settles.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        var settleMax: Double { settles.max() ?? 0 }
    }

    /// Syllables with their 2-set jamo steps.
    static let syllables: [[String]] = [["ㅎ", "하", "한"], ["ㄱ", "그", "글"], ["ㅅ", "사", "산"], ["ㄷ", "다", "달"],
                                        ["ㅂ", "바", "밤"], ["ㅁ", "무", "물"], ["ㄴ", "누", "눈"], ["ㅇ", "이", "일"]]
    static let plainText = Array("그는 창문을 열고 오래 바라보았다. “괜찮아?” 그녀가 물었다. 바람이 불었고, 밤은 깊었다. ")

    static func type(_ tv: ManuscriptTextView, _ window: NSWindow, _ busy: BusyMeter, composing: Bool) -> Run {
        var run = Run()
        var keystroke = 0
        func key(_ action: () -> Void) { autoreleasepool { keyInPool(action) } }
        // Each keystroke in its own autorelease pool, like an AppKit event: the bench's code runs outside any run-loop
        // iteration, so without it every forced display's autoreleased buffers piled up (~0.4 MB per keystroke).
        func keyInPool(_ action: () -> Void) {
            busy.reset()
            let cpu0 = cpuNow()
            let t0 = now()
            action()
            window.displayIfNeeded()
            let direct = now() - t0
            pump(keyGap)
            run.keys.append(direct + busy.total)
            run.cpu.append(cpuNow() - cpu0)
            run.hitch = max(run.hitch, direct, busy.longest)
            keystroke += 1
            if keystroke % pauseEvery == 0 {
                busy.reset()
                pump(pause)
                run.settles.append(busy.total)
                run.hitch = max(run.hitch, busy.longest)
            }
        }
        if composing {
            var i = 0
            while run.chars < 300 {
                if i % 4 == 3 {
                    key { tv.insertText(" ", replacementRange: tv.selectedRange()) }
                } else {
                    let steps = syllables[i % syllables.count]
                    for (n, s) in steps.enumerated() {
                        key {
                            // A new syllable's first jamo commits nothing here; the full one is committed below.
                            tv.setMarkedText(s, selectedRange: NSRange(location: (s as NSString).length, length: 0),
                                             replacementRange: NSRange(location: NSNotFound, length: 0))
                            if n == steps.count - 1 { tv.insertText(s, replacementRange: tv.markedRange()) }
                        }
                    }
                }
                run.chars += 1
                i += 1
            }
        } else {
            for i in 0..<300 {
                let ch = String(plainText[i % plainText.count])
                key { tv.insertText(ch, replacementRange: tv.selectedRange()) }
                run.chars += 1
            }
        }
        return run
    }

    // MARK: Sample text

    /// Deterministic Korean manuscript: episode headings, scene headings, scene breaks, dialogue, emphasis.
    static func sample(_ target: Int) -> String {
        let sentences = [
            "그날 밤 비는 그치지 않았고, 골목 끝의 가로등만 혼자서 깜빡였다.",
            "“이제 와서 무슨 소리야.” 민서가 낮게 말했다.",
            "그는 대답 대신 창밖을 보았다. 젖은 아스팔트 위로 **붉은 불빛**이 번졌다.",
            "기억은 언제나 엉뚱한 순간에 돌아왔다. 오래된 라디오에서 흘러나오던 노래처럼.",
            "“우리 그때 약속했잖아. 다시는 이 동네로 돌아오지 않겠다고.”",
            "책상 위에는 반쯤 식은 커피와 *읽다 만 편지*가 놓여 있었다.",
            "시계는 새벽 세 시를 가리켰지만, 누구도 먼저 자리에서 일어나지 않았다.",
            "바람이 문틈으로 스며들자 촛불이 한 번 크게 흔들렸다.",
        ]
        var out = ""
        var n = 0
        var episode = 1
        var sinceBreak = 0
        while (out as NSString).length < target {
            if n % 40 == 0 { out += (out.isEmpty ? "" : "\n") + "# \(episode)화. 비 오는 밤\n\n"; episode += 1 }
            else if n % 13 == 0 { out += "## 장면 \(n / 13)\n\n" }
            var para = ""
            for k in 0..<(2 + n % 4) { para += (k > 0 ? " " : "") + sentences[(n * 3 + k) % sentences.count] }
            out += para + "\n"
            if n % 3 == 2 { out += "\n" }
            sinceBreak += (para as NSString).length
            if sinceBreak > 1200 { out += "\n* * *\n\n"; sinceBreak = 0 }
            n += 1
        }
        return out
    }

    /// The start of a body paragraph near the middle (not a heading or scene break), a few characters in.
    static func middle(of ns: NSString) -> Int {
        var at = ns.length / 2
        while at < ns.length {
            let line = ns.paragraphRange(for: NSRange(location: at, length: 0))
            let s = Substring(ns.substring(with: line))
            if line.length > 20, !TextMetrics.isHeading(s), !TextMetrics.isSceneBreak(s) { return line.location + 10 }
            at = NSMaxRange(line)
        }
        return ns.length
    }

    // MARK: Measurement

    /// Main-thread busy time: the spans between the run loop entering / waking up and going back to sleep / exiting.
    final class BusyMeter {
        private(set) var total: Double = 0
        private(set) var longest: Double = 0
        private var woke: Double?
        private var observers: [CFRunLoopObserver] = []

        /// Start first (lowest order) and stop last (highest order): Core Animation's commit — layout and drawing —
        /// runs in a beforeWaiting observer and must be inside the measured span.
        init() {
            let start = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [unowned self] _, _ in
                if woke == nil { woke = now() }
            }!
            let stop = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, CFIndex.max) { [unowned self] _, _ in
                guard let w = woke else { return }
                let d = now() - w
                total += d
                longest = max(longest, d)
                woke = nil
            }!
            observers = [start, stop]
            for o in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
        }

        func reset() { total = 0; longest = 0; woke = nil }
    }

    static func cpuNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func findTextView(_ v: NSView?) -> ManuscriptTextView? {
        guard let v else { return nil }
        if let t = v as? ManuscriptTextView { return t }
        for s in v.subviews { if let t = findTextView(s) { return t } }
        return nil
    }

    private static func fail(_ m: String) -> Never { print("✗ \(m)"); exit(1) }
}

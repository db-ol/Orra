"""Tests of the Projects source rules in check_rules.py. Standard library only:

    python3 -I -m unittest discover -s Tools/ci -p 'test_*.py' -v

Each test writes small files into a temporary repository folder and checks it. The cases
are made up here. The last test checks the real tree.
"""

import tempfile
import textwrap
import unittest
from pathlib import Path

import check_rules

REPOSITORY = Path(__file__).resolve().parents[2]


class SourceCheckTestCase(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(textwrap.dedent(text), encoding="utf-8")

    def problems(self, **options):
        return check_rules.check_sources(self.root, **options)[0]

    def check_one(self, path, text, **options):
        """The problems of a tree that holds this one file."""
        for file in self.root.rglob("*"):
            if file.is_file():
                file.unlink()
        self.write(path, text)
        return self.problems(**options)

    def assert_fails(self, path, text, rule, name, **options):
        problems = self.check_one(path, text, **options)
        self.assertIn((rule, name), [(problem.rule, problem.name) for problem in problems], problems)

    def assert_passes(self, path, text, **options):
        self.assertEqual(self.check_one(path, text, **options), [])


class LexerTests(SourceCheckTestCase):
    """Comments never count, and string literals are not code, so the lexer must know where
    each ends. Each case puts a banned name in Orra/Projects."""

    PATH = "Orra/Projects/Example.swift"

    def test_nested_block_comments(self):
        self.assert_passes(self.PATH, "/* outer /* inner */ Process() */\nlet a = 1\n")
        self.assert_fails(self.PATH, "/* outer /* inner */ */ Process()\n", 1, "Process")

    def test_line_comments(self):
        self.assert_passes(self.PATH, "let a = 1 // Process() and NSWorkspace\n/// TextInserter\n")

    def test_a_double_slash_in_a_string_starts_no_comment(self):
        self.assert_fails(self.PATH, 'let a = "a // b"; Process()\n', 1, "Process")
        self.assert_fails(self.PATH, 'let a = "/* b"; Process() // */\n', 1, "Process")

    def test_escaped_quotes(self):
        self.assert_passes(self.PATH, 'let a = "say \\"Process\\" twice \\\\"\n')
        self.assert_fails(self.PATH, 'let a = "\\\\"; Process()\n', 1, "Process")

    def test_raw_strings(self):
        self.assert_passes(self.PATH, 'let a = #"a "Process" b \\(Process()) c"#\n')
        self.assert_passes(self.PATH, 'let a = ##"a "# Process "# b"##\n')
        self.assert_fails(self.PATH, 'let a = #"a "b" c"#; Process()\n', 1, "Process")
        self.assert_fails(self.PATH, 'let a = #"a \\#(Process()) b"#\n', 1, "Process")

    def test_multiline_strings(self):
        self.assert_passes(self.PATH, 'let a = """\n    Process "the" ""files""\n    """\n')
        self.assert_passes(self.PATH, 'let a = #"""\n    """ Process\n    """#\n')
        self.assert_fails(self.PATH, 'let a = """\n    text\n    """\nProcess()\n', 1, "Process")
        self.assert_fails(self.PATH, 'let a = """\n    \\(Process())\n    """\n', 1, "Process")

    def test_a_regex_literal_may_hold_a_double_slash(self):
        self.assert_passes(self.PATH, "let a = #/https?://\\w+ Process/#\n")
        self.assert_fails(self.PATH, "let a = #/a//b/#; Process()\n", 1, "Process")
        self.assert_fails(self.PATH, "let a = ##/a/# b/##; Process()\n", 1, "Process")
        self.assert_passes(self.PATH, "let a = #/\n  a // b\n  Process\n  /#\n")

    def test_a_slash_regex_with_a_quote_starts_no_string(self):
        self.assert_passes(self.PATH, 'let a = line.wholeMatch(of: /("[^"]*")/)\nlet b = 1\n')
        self.assert_fails(self.PATH, 'let a = text.firstMatch(of: /"/); Process(); let b = "c"\n', 1, "Process")

    def test_a_division_is_no_regex(self):
        self.assert_fails(self.PATH, 'var x = a/b + "c/d".count; Process(); let e = "f"\n', 1, "Process")
        self.assert_fails(self.PATH, 'x /= "a/b".count; Process(); let e = "f"\n', 1, "Process")
        self.assert_fails(self.PATH, 'let x = (a) / 2 + "a/b".count; Process(); let e = "f"\n', 1, "Process")

    def test_a_slash_after_a_postfix_operator_divides(self):
        self.assert_fails(self.PATH, 'let r = a!/2; let s = "x/y"; let task = Process(); let t = "\\""\n', 1, "Process")
        self.assert_fails(self.PATH, 'let r = f()?/2; let s = "x/y"; let task = Process(); let t = "\\""\n', 1, "Process")

    def test_a_slash_after_a_keyword_starts_a_regex(self):
        self.assert_fails(
            self.PATH,
            'func f() -> Regex<Substring> { return/"/ }; let s = "a"; let task = Process(); let t = "\\""\n',
            1, "Process",
        )
        self.assert_fails(self.PATH, 'let m = a.map { v in/"/ }; let s = "a"; let task = Process(); let t = "\\""\n', 1, "Process")
        self.assert_fails(self.PATH, 'let r = try!/"/; let s = "a"; let task = Process(); let t = "\\""\n', 1, "Process")

    def test_a_slash_after_a_word_that_is_a_name_divides(self):
        self.assert_fails(self.PATH, 'let y = then/2; let s = "a/b"; let task = Process(); let t = "c"\n', 1, "Process")
        self.assert_fails(self.PATH, 'let y = item.in/2; let s = "a/b"; let task = Process(); let t = "c"\n', 1, "Process")

    def test_names_in_backticks(self):
        self.assert_fails(self.PATH, "let x = `a // b`(); let task = Process()\n", 1, "Process")
        self.assert_fails(self.PATH, "func `e /* f`() {}\nlet task = Process()\nfunc `g */ h`() {}\n", 1, "Process")
        self.assert_passes(self.PATH, 'func `c " d`() {}\nlet a = 1\n')
        self.assert_passes(self.PATH, "let `default` = 1\nlet b = `default` + 1\n")
        self.assert_fails(self.PATH, 'let a = "\\(`b // c`) d"; let task = Process()\n', 1, "Process")
        # The name stays in the code view.
        self.assert_fails(self.PATH, "func `runs Process`() {}\n", 1, "Process")

    def test_a_banned_name_inside_an_interpolation_fails(self):
        self.assert_fails(self.PATH, 'let a = "files: \\(Process().arguments)"\n', 1, "Process")
        self.assert_fails(self.PATH, 'let a = "a \\(f("b \\(Process())")) c"\n', 1, "Process")
        self.assert_fails(self.PATH, 'let a = "a \\(f(")")) \\(Process()) b"\n', 1, "Process")

    def test_text_after_an_interpolation_is_still_a_literal(self):
        self.assert_passes(self.PATH, 'let a = "\\(count) Process (files)"\n')

    def test_a_literal_or_comment_without_an_end_fails(self):
        cases = [
            'let a = "abc\nlet b = 1\n',
            'let a = "abc\\\nProcess()"\n',
            "/* abc\n",
            "/* a /* b */\n",
            'let a = """\nabc\n',
            'let a = #"abc"\n',
            'let a = "\\(f(1)"\n',
            "let a = #/abc\n/#\n",
            'let a = """abc"""\n',
            "let a = `abc\n",
            "let a = `abc\nd`\n",
        ]
        for text in cases:
            with self.subTest(text=text):
                problems = self.check_one(self.PATH, text)
                self.assertEqual([problem.rule for problem in problems], [None], problems)

    def test_a_file_that_is_not_utf8_fails(self):
        file = self.root / self.PATH
        file.parent.mkdir(parents=True)
        file.write_bytes(b"let a = \"\xff\"\n")
        self.assertEqual(self.problems(), [check_rules.SourceProblem(self.PATH, None, None, "not UTF-8")])

    def test_views_keep_lengths_and_lines(self):
        text = 'let a = "x\\(b("y"))z" /* c\n d */ // e\nlet f = #"""\n g\n """#\n'
        code, uncommented = check_rules.swift_views(text)
        self.assertEqual(len(code), len(text))
        self.assertEqual(len(uncommented), len(text))
        self.assertEqual(code.split("\n")[0].split(), ["let", "a", "=", "b(", ")"])
        self.assertEqual(code.count("\n"), text.count("\n"))
        self.assertNotIn("c", uncommented.split("\n")[0][20:])
        self.assertIn('"x', uncommented)


class ProjectsCodeTests(SourceCheckTestCase):
    """Rule 1: what code in Orra/Projects must never name."""

    PATH = "Orra/Projects/Window/Example.swift"

    def test_each_banned_name_fails(self):
        cases = {
            "TextInserter.paste(text)": "TextInserter",
            "let tap = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)": "CGEvent",
            "CGEventPost(.cghidEventTap, event)": "CGEventPost",
            "let app = AXUIElementCreateApplication(pid)": "AXUIElementCreateApplication",
            "let trusted = AXIsProcessTrusted()": "AXIsProcessTrusted",
            "let name = kAXFocusedUIElementAttribute": "kAXFocusedUIElementAttribute",
            "NSWorkspace.shared.open(url)": "NSWorkspace",
            "NSPasteboard.general.clearContents()": "NSPasteboard",
            "ConcealedClipboard.copy(draft, to: .general)": "ConcealedClipboard",
            "let task = Process()": "Process",
            "let task = Foundation.Process()": "Process",
            "let task = NSTask()": "NSTask",
            "posix_spawn(&pid, path, nil, nil, argv, nil)": "posix_spawn",
            "posix_spawnp(&pid, name, nil, nil, argv, nil)": "posix_spawnp",
            'system("ls")': "system(",
            'let code = system ("ls")': "system (",
            'Darwin.system("ls")': "system(",
            'let pipe = popen("ls", "r")': "popen",
            "execv(path, argv)": "execv",
            "execve(path, argv, env)": "execve",
            "let pid = fork()": "fork",
            "let handle = dlopen(nil, RTLD_NOW)": "dlopen",
            'let symbol = dlsym(handle, "f")': "dlsym",
            'let type = NSClassFromString("NSTask")': "NSClassFromString",
            'let action = NSSelectorFromString("send")': "NSSelectorFromString",
            'let action = Selector("send")': "Selector(",
            "object.perform(action)": ".perform(",
            "object.performSelector(onMainThread: action, with: nil, waitUntilDone: false)": "performSelector",
            'let type: AnyClass? = objc_getClass("Helper") as? AnyClass': "objc_getClass",
            'let type = Bundle.main.classNamed("Helper")': "classNamed",
            '@_silgen_name("system") func run(_ command: UnsafePointer<CChar>) -> Int32': "@_silgen_name",
            '@_extern(c, "system") func run(_ command: UnsafePointer<CChar>) -> Int32': "@_extern",
            "let view = WKWebView()": "WKWebView",
            "import WebKit": "import WebKit",
            "@preconcurrency import WebKit": "import WebKit",
            "import class WebKit.WKWebView": "import class WebKit",
            "let session = URLSession.shared": "URLSession",
            "import Network": "import Network",
            "let connection = NWConnection(host: host, port: port, using: .tcp)": "NWConnection",
            "AsyncImage(url: url)": "AsyncImage",
            'Link("Site", destination: url)': "Link(",
            "@Environment(\\.openURL) private var openURL": "openURL",
            "let action = OpenURLAction { _ in .handled }": "OpenURLAction",
            "LSOpenCFURLRef(url as CFURL, nil)": "LSOpenCFURLRef",
            "let text = try AttributedString(markdown: answer)": "AttributedString(markdown",
            "let text = try NSAttributedString(markdown: answer)": "NSAttributedString(markdown",
            "let type = NSAttributedString.DocumentType.html": ".html",
            "options[.documentType] = .html": ".html",
            "let type = NSAttributedString.DocumentType.webArchive": ".webArchive",
            'let type = NSAttributedString.DocumentType(rawValue: "NSHTML")': "DocumentType(",
            "mail.terminate()": "terminate(",
            "mail.forceTerminate()": "forceTerminate",
            "kill(pid, SIGTERM)": "kill(",
            "killpg(group, SIGTERM)": "killpg(",
            "unlink(path)": "unlink",
            "unlinkat(folder, name, 0)": "unlinkat",
            "rmdir(path)": "rmdir",
            "remove(path)": "remove(",
            "Darwin.remove(path)": "remove(",
            "rename(old, new)": "rename(",
            "renameat(a, old, b, new)": "renameat",
            "renamex_np(old, new, 0)": "renamex_np",
            "removefile(path, nil, 0)": "removefile",
            "let document = PDFDocument(url: file)": "PDFDocument(url",
            "let document = CGPDFDocumentCreateWithURL(file as CFURL)": "CGPDFDocumentCreateWithURL",
            "let source = CGImageSourceCreateWithURL(file as CFURL, nil)": "CGImageSourceCreateWithURL",
            "let provider = CGDataProviderCreateWithURL(file as CFURL)": "CGDataProviderCreateWithURL",
            "let handler = VNImageRequestHandler(url: file, options: [:])": "VNImageRequestHandler(url",
            "let parser = XMLParser(contentsOf: file)": "XMLParser(contentsOf",
            "let document = try XMLDocument(contentsOf: file)": "XMLDocument(contentsOf",
            "let image = NSImage(contentsOf: file)": "NSImage(contentsOf",
            "let image = NSImage(byReferencing: file)": "NSImage(byReferencing",
            "parser.externalEntityResolvingPolicy = .always": "externalEntityResolvingPolicy",
            "parser.shouldResolveExternalEntities = true": "shouldResolveExternalEntities",
            "parser.allowedExternalEntityURLs = [file]": "allowedExternalEntityURLs",
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_fails(self.PATH, code + "\n", 1, name)

    def test_readers_of_bytes_pass(self):
        # The readers of bytes, and Vision's handler, which takes an array of requests.
        self.assert_passes("Orra/Projects/Index/Example.swift", """\
            let document = PDFDocument(data: data)
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let parser = XMLParser(data: data)
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            try handler.perform( [request, other])
            """)
        self.assert_fails("Orra/Projects/Index/Example.swift", "object.perform(action)\n", 1, ".perform(")

    def test_readers_by_url_pass_outside_the_projects_folder(self):
        self.assert_passes(
            "OrraTests/Projects/ExampleTests.swift",
            "let document = PDFDocument(url: file)\nlet parser = XMLParser(contentsOf: file)\nparser.shouldResolveExternalEntities = false\n",
        )

    def test_a_member_named_html_fails(self):
        # Only a name can tell the HTML document type, so no member in Orra/Projects is
        # named html, not even a case of an enum of its own.
        self.assert_fails(self.PATH, "enum Part { case plain, html }\nlet part = Part.html\n", 1, ".html")

    def test_names_that_only_look_alike_pass(self):
        self.assert_passes(self.PATH, """\
            import SwiftUI

            struct Example: View {
                let memory = ProcessInfo.processInfo.physicalMemory
                let processed = 3
                var body: some View {
                    Text(verbatim: "Process the files, then save page.html")
                        .font(.system(size: 12))
                        .font(.system(.body))
                }
                func processText(_ text: String) -> String { text }
                func remove(_ id: UUID) { projects.remove(at: 0); ids.remove(id); remove(project: id); remove(); items.removeAll() }
                func rename(to name: String) { title = name }
                @objc func refresh() {}
                let killed = skillCount
                let extensions = [".html", ".htm"]
                let kind = ProjectsWarning.link
                let mailLink = "x"
            }
            """)

    def test_rule_one_holds_only_in_the_projects_folder(self):
        self.assert_passes(
            "Orra/AppLanguage.swift",
            "let shell = Process()\nNSWorkspace.shared.open(url)\nConcealedClipboard.copy(draft, to: .general)\n",
        )
        self.assert_passes("OrraTests/Projects/ExampleTests.swift", "let task = Process()\n")

    def test_a_failure_prints_no_more_than_the_name(self):
        problems = self.check_one(self.PATH, 'let a = 1\nlet secret = "Mei"; let task = Process()\n')
        self.assertEqual(problems, [check_rules.SourceProblem(self.PATH, 2, 1, "Process")])
        printed = check_rules.format_source_problem(problems[0])
        self.assertEqual(printed, f"{self.PATH} line 2: rule 1, Process")


class AttributedStringTests(SourceCheckTestCase):
    """Rule 2: NSAttributedString only in Index/FileText.swift, from data with a named type."""

    FILE_TEXT = "Orra/Projects/Index/FileText.swift"

    def test_data_with_a_document_type_passes_in_file_text(self):
        self.assert_passes(self.FILE_TEXT, """\
            let text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
            )
            let plain = NSAttributedString(string: "a")
            """)

    def test_data_without_a_document_type_fails(self):
        self.assert_fails(
            self.FILE_TEXT,
            "let text = try NSAttributedString(data: data, options: options, documentAttributes: nil)\n",
            2, "NSAttributedString(data: without documentType",
        )
        self.assert_fails(
            self.FILE_TEXT,
            'let text = try NSAttributedString(data: data, options: ["documentType": 1], documentAttributes: nil)\n',
            2, "NSAttributedString(data: without documentType",
        )

    def test_a_url_a_path_or_html_fails(self):
        cases = {
            "try NSAttributedString(url: file, options: [.documentType: type], documentAttributes: nil)": "NSAttributedString(url:",
            "NSAttributedString(path: path, documentAttributes: nil)": "NSAttributedString(path:",
            "NSAttributedString(html: data, documentAttributes: nil)": "NSAttributedString(html:",
            "try NSMutableAttributedString(url: file, options: [:], documentAttributes: nil)": "NSMutableAttributedString(url:",
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_fails(self.FILE_TEXT, code + "\n", 2, name)

    def test_other_projects_files_make_none(self):
        self.assert_fails("Orra/Projects/Mail/VisibleText.swift", 'let a = NSAttributedString(string: "a")\n', 2, "NSAttributedString(")

    def test_rule_two_holds_only_in_the_projects_folder(self):
        self.assert_passes("Orra/Other.swift", "let a = try NSAttributedString(url: file, options: [:], documentAttributes: nil)\n")


class AppleEventTests(SourceCheckTestCase):
    """Rules 3 and 4: building and sending Apple Events."""

    def test_building_or_sending_fails_in_the_app(self):
        cases = {
            "let event = NSAppleEventDescriptor.appleEvent(withEventClass: a, eventID: b, targetDescriptor: t, returnID: r, transactionID: x)": "NSAppleEventDescriptor.appleEvent",
            "let event: NSAppleEventDescriptor = .appleEvent(withEventClass: a, eventID: b, targetDescriptor: t, returnID: r, transactionID: x)": "appleEvent(withEventClass",
            "let event = NSAppleEventDescriptor(eventClass: a, eventID: b, targetDescriptor: t, returnID: r, transactionID: x)": "NSAppleEventDescriptor(eventClass",
            "let reply = try event.sendEvent(options: [.neverInteract], timeout: 10)": "sendEvent(options",
            "AESendMessage(event, reply, mode, timeout)": "AESendMessage",
            "AESend(event, reply, mode, priority, timeout, nil, nil)": "AESend",
            "AECreateAppleEvent(a, b, target, r, x, event)": "AECreateAppleEvent",
            "AEBuildAppleEvent(a, b, type, target, size, r, x, event, nil, format)": "AEBuildAppleEvent",
            "let status = AEDeterminePermissionToAutomateTarget(target, a, b, false)": "AEDeterminePermissionToAutomateTarget",
            "let send = event.sendEvent": "sendEvent",
            "import ScriptingBridge": "import ScriptingBridge",
            "@preconcurrency import ScriptingBridge": "import ScriptingBridge",
            'let mail = SBApplication(bundleIdentifier: "com.apple.mail")': "SBApplication",
            "let message: SBObject = messages[0]": "SBObject",
            "let messages: SBElementArray = inbox.messages()": "SBElementArray",
        }
        for path in ("Orra/Other.swift", "Orra/Projects/Mail/MailBridge.swift"):
            for code, name in cases.items():
                with self.subTest(path=path, code=code):
                    self.assert_fails(path, code + "\n", 3, name)

    def test_reading_the_launch_event_passes(self):
        self.assert_passes("Orra/LaunchWindow.swift", """\
            static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
                guard let event, event.eventID == kAEOpenApplication else { return false }
                return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            }
            let current = NSAppleEventManager.shared().currentAppleEvent
            """)

    def test_an_nsevent_send_event_passes(self):
        text = (
            "override func sendEvent(_ event: NSEvent) {\n    super.sendEvent(event)\n}\nwindow.sendEvent(event)\n"
            "let action = #selector(NSApplication.sendEvent(_:))\n"
        )
        self.assert_passes("Orra/Window.swift", text)
        self.assert_passes("OrraTests/WindowTests.swift", text)

    def test_a_file_on_the_allow_list_may_build_and_send(self):
        allowed = frozenset({"Orra/Projects/Mail/Example.swift"})
        text = "let event = NSAppleEventDescriptor(eventClass: a, eventID: b, targetDescriptor: t, returnID: r, transactionID: x)\nlet reply = try event.sendEvent(options: [], timeout: 10)\n"
        self.assert_passes("Orra/Projects/Mail/Example.swift", text, apple_event_files=allowed)
        self.assert_fails("Orra/Projects/Mail/MailBridge.swift", text, 3, "sendEvent(options", apple_event_files=allowed)
        self.assert_fails("Orra/Projects/Mail/Example.swift", text, 3, "sendEvent(options")

    def test_only_mail_events_is_on_the_allow_list(self):
        self.assertEqual(check_rules.APPLE_EVENT_FILES, frozenset({"Orra/Projects/Mail/MailEvents.swift"}))
        problems = self.check_one(
            "Orra/Projects/Mail/MailEvents.swift", "let reply = try event.sendEvent(options: [], timeout: 10)\n"
        )
        self.assertNotIn(3, [problem.rule for problem in problems])
        problems = self.check_one(
            "Orra/Projects/Mail/MailEvents.swift",
            "let reply = try event.sendEvent(options: [], timeout: 10)\n",
            apple_event_files=frozenset(),
        )
        self.assertIn((3, "sendEvent(options"), [(problem.rule, problem.name) for problem in problems])

    def test_tests_may_build_but_never_send(self):
        self.assert_passes("OrraTests/LaunchWindowTests.swift", """\
            private func openApplicationEvent() -> NSAppleEventDescriptor {
                NSAppleEventDescriptor(
                    eventClass: kCoreEventClass,
                    eventID: kAEOpenApplication,
                    targetDescriptor: nil,
                    returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID)
                )
            }
            """)
        cases = {
            "let reply = try event.sendEvent(options: [], timeout: 1)": "sendEvent(options",
            "AESendMessage(event, reply, mode, timeout)": "AESendMessage",
            "AESend(event, reply, mode, priority, timeout, nil, nil)": "AESend",
            "AEDeterminePermissionToAutomateTarget(target, a, b, false)": "AEDeterminePermissionToAutomateTarget",
            "let send = event.sendEvent": "sendEvent",
            "import ScriptingBridge": "import ScriptingBridge",
            'let mail = SBApplication(bundleIdentifier: "com.apple.mail")': "SBApplication",
            "let bridge = MailBridge.live": "MailBridge.live",
            "let events = MailEvents.live": "MailEvents.live",
            "let front = ReplyHandoff.bringMailToFront": "ReplyHandoff.bringMailToFront",
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_fails("OrraTests/Projects/MailBridgeTests.swift", code + "\n", 4, name)

    def test_names_in_comments_and_strings_pass(self):
        self.assert_passes("Orra/Other.swift", '// AESendMessage\nlet a = "sendEvent(options:"\n')


class MailEventsRuleTests(SourceCheckTestCase):
    """Rule 10, on the real MailEvents.swift and on changed copies of it."""

    PATH = "Orra/Projects/Mail/MailEvents.swift"
    REAL = (REPOSITORY / PATH).read_text(encoding="utf-8")

    def changed(self, old, new, count=1):
        """The real file with one change, which must find its place."""
        self.assertEqual(self.REAL.count(old), count, old)
        return self.REAL.replace(old, new)

    def rule_ten(self, text):
        return [problem.name for problem in self.check_one(self.PATH, text) if problem.rule == 10]

    def assert_rule_ten_fails(self, text, name):
        self.assertIn(name, self.rule_ten(text))

    def test_the_real_file_passes(self):
        self.assertEqual(self.check_one(self.PATH, self.REAL), [])
        self.assertEqual(check_rules.check_mail_events(self.REAL), [])

    def test_the_rule_holds_whatever_the_allow_list_says(self):
        text = self.changed('case reply = "emalrpms"', 'case reply = "emalfwms"')
        problems = self.check_one(self.PATH, text, apple_event_files=frozenset({self.PATH}))
        self.assertIn("MailEvent case reply = emalfwms", [problem.name for problem in problems if problem.rule == 10])

    def test_the_rule_reads_only_mail_events(self):
        text = self.changed('case reply = "emalrpms"', 'case delete = "coredelo"')
        self.assert_passes("Orra/Projects/Mail/MailEventsTools.swift", text, apple_event_files=frozenset({"Orra/Projects/Mail/MailEventsTools.swift"}))

    def test_another_event_in_the_enum_fails(self):
        text = self.changed('    case reply = "emalrpms"\n', '    case reply = "emalrpms"\n    case delete = "coredelo"\n')
        self.assertCountEqual(self.rule_ten(text), ["MailEvent case delete = coredelo", '"coredelo", the code of delete'])
        text = self.changed('case count = "corecnte"', 'case count = "corecnte", move = "coremove"')
        self.assertCountEqual(self.rule_ten(text), ["MailEvent case move = coremove", '"coremove", the code of move'])

    def test_a_changed_or_missing_event_fails(self):
        self.assertCountEqual(
            self.rule_ten(self.changed('case reply = "emalrpms"', 'case reply = "emalfwms"')),
            ["MailEvent case reply = emalfwms", '"emalfwms", the code of forward'],
        )
        self.assertCountEqual(
            self.rule_ten(self.changed('case get = "coregetd"', 'case get = "coresetd"')),
            ["MailEvent case get = coresetd", '"coresetd", the code of set'],
        )
        self.assertEqual(self.rule_ten(self.changed('    case count = "corecnte"\n', "")), ["MailEvent without case count"])
        self.assert_rule_ten_fails(self.changed('case get = "coregetd"', "case get"), "MailEvent case get without its code")
        self.assert_rule_ten_fails(self.changed("enum MailEvent:", "enum MailEvents2:"), "no MailEvent enum")

    def test_codes_not_from_the_raw_value_fail(self):
        self.assert_rule_ten_fails(
            self.changed("MailEvents.code(rawValue.prefix(4))", 'MailEvents.code("core")'),
            "MailEvent eventClass not from rawValue.prefix(4)",
        )
        self.assert_rule_ten_fails(
            self.changed("MailEvents.code(rawValue.suffix(4))", "MailEvents.code(rawValue.prefix(4))"),
            "MailEvent eventID not from rawValue.suffix(4)",
        )

    def test_an_event_with_codes_of_its_own_fails(self):
        cases = [
            ("withEventClass: self.event.eventClass", 'withEventClass: MailEvents.code("core")'),
            ("eventID: self.event.eventID", "eventID: MailEvents.code(rawValue)"),
            ("eventID: self.event.eventID", "eventID: other.eventID"),
            ("withEventClass: self.event.eventClass", "withEventClass: 0x636F_7265"),
        ]
        for old, new in cases:
            with self.subTest(new=new):
                self.assert_rule_ten_fails(self.changed(old, new), "appleEvent(withEventClass: not from MailEvent")
        self.assertEqual(self.rule_ten(self.changed("withEventClass: self.event.eventClass", "withEventClass: MailEvent.get.eventClass")), ["appleEvent(withEventClass: not from MailEvent"])
        self.assertEqual(
            self.rule_ten(self.changed(
                "withEventClass: self.event.eventClass,\n                eventID: self.event.eventID",
                "withEventClass: MailEvent.reply.eventClass,\n                eventID: MailEvent.reply.eventID",
            )),
            [],
        )
        self.assert_rule_ten_fails(
            self.REAL + "let other = NSAppleEventDescriptor(eventClass: a, eventID: b, targetDescriptor: t, returnID: r, transactionID: x)\n",
            "NSAppleEventDescriptor(eventClass: not from MailEvent",
        )
        self.assert_rule_ten_fails(self.REAL + "AECreateAppleEvent(a, b, target, r, x, event)\n", "AECreateAppleEvent")
        self.assert_rule_ten_fails(self.REAL + "AEBuildAppleEvent(a, b, type, target, size, r, x, event, nil, format)\n", "AEBuildAppleEvent")

    def test_changing_an_event_after_it_is_built_fails(self):
        cases = {
            'event.setAttribute(NSAppleEventDescriptor(typeCode: MailEvents.code("de" + "lo")), forKeyword: keyEventIDAttr)': ["setAttribute", "keyEventIDAttr"],
            "event.setAttribute(other, forKeyword: AEKeyword(keyEventClassAttr))": ["setAttribute", "keyEventClassAttr"],
            "let other = NSAppleEventDescriptor(descriptorType: typeAppleEvent, data: saved)": ["typeAppleEvent"],
            "AEPutAttributeDesc(event, keyword, value)": ["AEPutAttributeDesc"],
            "AEPutAttributePtr(event, keyword, type, data, size)": ["AEPutAttributePtr"],
        }
        for code, names in cases.items():
            with self.subTest(code=code):
                self.assertCountEqual(self.rule_ten(self.REAL + code + "\n"), names)

    def test_a_reply_without_its_window_fails(self):
        self.assert_rule_ten_fails(
            self.changed("NSAppleEventDescriptor(boolean: true), forKeyword: MailEvents.code(\"ropw\")", "NSAppleEventDescriptor(boolean: false), forKeyword: MailEvents.code(\"ropw\")"),
            "ropw not set to true",
        )
        self.assert_rule_ten_fails(
            self.changed("                event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: MailEvents.code(\"ropw\"))\n", ""),
            "reply without ropw true",
        )
        self.assert_rule_ten_fails(
            self.REAL + 'let late = { event.setParam(NSAppleEventDescriptor(boolean: open), forKeyword: MailEvents.code("ropw")) }\n',
            "ropw not set to true",
        )

    def test_a_code_of_a_command_that_changes_mail_fails(self):
        cases = {
            'let a = "coredelo"': '"coredelo", the code of delete',
            'let a = "delo"': '"delo", the code of delete',
            'let a = "emsgsend"': '"emsgsend", the code of send',
            'let a = "emsg"': '"emsg", the code of send',
            'let a = "send"': '"send", the code of send',
            'let a = "aevtquit"': '"aevtquit", the code of quit',
            'let a = "setd"': '"setd", the code of set',
            'let a = "cpma"': '"cpma", the code of perform mail action with messages',
            'let a = "ctnt"': '"ctnt", the code of content',
            'let a = #"move"#': '"move", the code of move',
            'let a = "del\\u{6F}"': '"delo", the code of delete',
            "let a = 0x6465_6C6F": "0x6465_6C6F, the code delo of delete",
            "let a = 1684368495": "1684368495, the code delo of delete",
            "let a = 0o14431266157": "0o14431266157, the code delo of delete",
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_rule_ten_fails(self.REAL + code + "\n", name)

    def test_codes_that_only_read_and_comments_pass(self):
        text = self.REAL + '// coredelo, delete and "send"\nlet a = "core"\nlet b = "emal"\nlet c = "move it"\nlet d = "\\(x)send"\n'
        self.assertEqual(self.rule_ten(text), [])

    def test_the_banned_codes(self):
        banned = check_rules.MAIL_BANNED_CODES
        for code in ("delo", "send", "fwms", "chma", "emsg", "aevt", "ctnt", "setd"):
            self.assertIn(code, banned)
        for code in ("core", "emal", "getd", "cnte", "rpms", "raso", "meid"):
            self.assertNotIn(code, banned)

    def test_the_list_covers_every_command_of_mail(self):
        """Every command in Mail's scripting dictionary is either one of the three events, a
        command that only reads, or a command rule 10 bans. Skipped where Mail is not, as on
        the Linux runner."""
        dictionaries = [
            Path("/System/Applications/Mail.app/Contents/Resources/Mail.sdef"),
            Path("/System/Library/ScriptingDefinitions/CocoaStandard.sdef"),
        ]
        if not all(path.is_file() for path in dictionaries):
            self.skipTest("Mail's scripting dictionary is not on this machine")
        import xml.etree.ElementTree as ElementTree

        reading = {"coredoex": "exists", "emaleafn": "extract name from", "emaleaua": "extract address from"}
        allowed = set(check_rules.MAIL_EVENTS.values())
        for path in dictionaries:
            for command in ElementTree.parse(path).iter("command"):
                code = command.get("code")
                with self.subTest(path=path.name, command=command.get("name")):
                    self.assertTrue(code in allowed or code in reading or code in check_rules.MAIL_CHANGING_COMMANDS, code)
                    if code in check_rules.MAIL_CHANGING_COMMANDS:
                        self.assertEqual(check_rules.MAIL_CHANGING_COMMANDS[code].lower(), command.get("name").lower())


class ScriptTextTests(SourceCheckTestCase):
    """Rule 5: no script text anywhere in Orra, OrraTests or Tools."""

    def test_script_names_fail_in_code_and_in_strings(self):
        cases = {
            "let script = NSAppleScript(source: text)": "NSAppleScript",
            "let script = OSAScript(source: text)": "OSAScript",
            'let tool = "/usr/bin/osascript"': "osascript",
            'let source = "tell application \\"Mail\\" to quit"': "tell application",
            'let source = """\n    Tell  Application "Mail"\n    """': "Tell Application",
            "let task = try NSUserAppleScriptTask(url: url)": "NSUserAppleScriptTask",
            "let task = try NSUserUnixTask(url: url)": "NSUserUnixTask",
            "let task = try NSUserScriptTask(url: url)": "NSUserScriptTask",
            "import OSAKit": "import OSAKit",
            'let tool = "/usr/bin/osacompile"': "osacompile",
        }
        for path in ("Orra/Other.swift", "OrraTests/OtherTests.swift", "Orra/Projects/Mail/MailEvents.swift"):
            for code, name in cases.items():
                with self.subTest(path=path, code=code):
                    self.assert_fails(path, code + "\n", 5, name)

    def test_every_kind_of_file_counts(self):
        self.assert_fails("Tools/release/quit.sh", "osascript -e 'quit app \"Orra\"'\n", 5, "osascript")
        self.assert_fails("Tools/release/helper.py", "# runs osascript\n", 5, "osascript")
        self.assert_fails("Orra/Localizable.xcstrings", '{"a": "tell application"}\n', 5, "tell application")
        self.assert_fails("Tools/readme-media/Kit.swift", 'let a = "osascript"\n', 5, "osascript")

    def test_comments_in_swift_files_pass(self):
        self.assert_passes("Orra/Other.swift", "// Never NSAppleScript or osascript.\nlet a = 1\n")

    def test_only_this_check_and_its_tests_may_name_them(self):
        self.assert_passes("Tools/ci/check_rules.py", 'NAMES = ["osascript", "NSAppleScript"]\n')
        self.assert_passes("Tools/ci/test_check_rules.py", 'NAMES = ["osascript", "NSAppleScript"]\n')
        self.assert_fails("Tools/ci/other.py", 'NAMES = ["osascript"]\n', 5, "osascript")

    def test_folders_outside_the_three_pass(self):
        self.assert_passes("docs/notes.md", "osascript -e 'tell application \"Mail\"'\n")

    def test_python_caches_under_tools_are_skipped(self):
        self.assert_passes("Tools/ci/__pycache__/check_rules.cpython-312.pyc", "osascript\n")


class StorageRulesTests(SourceCheckTestCase):
    """Rules 6 to 8: SQLite, removing files and UserDefaults."""

    def test_sqlite_only_in_the_projects_folders(self):
        for path in ("Orra/Projects/Index/ProjectsDatabase.swift", "OrraTests/Projects/ProjectsDatabaseTests.swift"):
            with self.subTest(path=path):
                self.assert_passes(path, "import SQLite3\nlet result = sqlite3_open(path, &handle)\n")
        for path in ("Orra/Other.swift", "OrraTests/OtherTests.swift"):
            with self.subTest(path=path):
                self.assert_fails(path, "import SQLite3\n", 6, "import SQLite3")
                self.assert_fails(path, "let result = sqlite3_open(path, &handle)\n", 6, "sqlite3_open")

    def test_only_projects_storage_removes_files(self):
        cases = {
            "try FileManager.default.removeItem(at: url)": "removeItem",
            "try FileManager.default.moveItem(at: a, to: b)": "moveItem",
            "try FileManager.default.replaceItemAt(a, withItemAt: b)": "replaceItemAt",
            "try FileManager.default.trashItem(at: url, resultingItemURL: nil)": "trashItem",
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_fails("Orra/Projects/Index/FolderIndex.swift", code + "\n", 7, name)
                self.assert_passes("Orra/Projects/ProjectsStorage.swift", code + "\n")
                self.assert_passes("Orra/VoiceSampleFile.swift", code + "\n")

    def test_only_two_files_use_user_defaults(self):
        for path in ("Orra/Projects/ProjectsSwitch.swift", "Orra/Projects/Mail/MailChoice.swift", "Orra/Preferences.swift"):
            with self.subTest(path=path):
                self.assert_passes(path, 'let on = UserDefaults.standard.bool(forKey: "projectsOn")\n')
        self.assert_fails("Orra/Projects/Window/ProjectsWindow.swift", "let defaults = UserDefaults.standard\n", 8, "UserDefaults")
        self.assert_fails("Orra/Projects/Window/ProjectsWindow.swift", '@AppStorage("width") var width = 300.0\n', 8, "AppStorage")
        self.assert_fails(
            "Orra/Projects/Window/ProjectsWindow.swift",
            "let value = CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)\n",
            8, "CFPreferencesCopyAppValue",
        )
        self.assert_fails(
            "Orra/Projects/Window/ProjectsWindow.swift", "let controller = NSUserDefaultsController.shared\n", 8, "NSUserDefaultsController"
        )


class FolderTests(SourceCheckTestCase):
    """Rule 9, and what a missing file or folder does."""

    def test_only_swift_files_in_the_projects_folder(self):
        self.assert_fails("Orra/Projects/notes.md", "Notes\n", 9, ".md")
        self.assert_fails("Orra/Projects/Index/stopwords.json", "[]\n", 9, ".json")
        self.assert_fails("Orra/Projects/README", "Notes\n", 9, "a file without an extension")
        self.assert_passes("Orra/Projects/Index/FileText.swift", "let a = 1\n")
        self.assert_passes("Orra/Projects/.DS_Store", "\0\0")
        self.assert_passes("Orra/notes.md", "Notes\n")

    def test_an_empty_tree_passes(self):
        self.assertEqual(check_rules.check_sources(self.root), ([], 0, 0))

    def test_problems_are_sorted_and_counted(self):
        self.write("Orra/Projects/B.swift", "let a = Process()\n")
        self.write("Orra/Projects/A.swift", "let a = 1\nlet b = NSPasteboard.general\nlet c = Process()\n")
        self.write("Orra/Projects/C.txt", "c\n")
        problems, swift_count, other_count = check_rules.check_sources(self.root)
        self.assertEqual([(problem.path, problem.line, problem.rule) for problem in problems], [
            ("Orra/Projects/A.swift", 2, 1),
            ("Orra/Projects/A.swift", 3, 1),
            ("Orra/Projects/B.swift", 1, 1),
            ("Orra/Projects/C.txt", None, 9),
        ])
        self.assertEqual((swift_count, other_count), (2, 1))


class RealTreeTests(unittest.TestCase):
    def test_the_repository_passes(self):
        problems, swift_count, _ = check_rules.check_sources(REPOSITORY)
        self.assertEqual([check_rules.format_source_problem(problem) for problem in problems], [])
        self.assertGreater(swift_count, 100)


if __name__ == "__main__":
    unittest.main()

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
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_fails(self.PATH, code + "\n", 1, name)

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
        self.assert_passes("Orra/AppLanguage.swift", "let shell = Process()\nNSWorkspace.shared.open(url)\n")
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
        allowed = frozenset({"Orra/Projects/Mail/MailEvents.swift"})
        text = "let event = NSAppleEventDescriptor(eventClass: a, eventID: b, targetDescriptor: t, returnID: r, transactionID: x)\nlet reply = try event.sendEvent(options: [], timeout: 10)\n"
        self.assert_passes("Orra/Projects/Mail/MailEvents.swift", text, apple_event_files=allowed)
        self.assert_fails("Orra/Projects/Mail/MailBridge.swift", text, 3, "sendEvent(options", apple_event_files=allowed)
        self.assert_fails("Orra/Projects/Mail/MailEvents.swift", text, 3, "sendEvent(options")

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
        }
        for code, name in cases.items():
            with self.subTest(code=code):
                self.assert_fails("OrraTests/Projects/MailBridgeTests.swift", code + "\n", 4, name)

    def test_names_in_comments_and_strings_pass(self):
        self.assert_passes("Orra/Other.swift", '// AESendMessage\nlet a = "sendEvent(options:"\n')


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

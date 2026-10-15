#!/usr/bin/env python3
import json
import signal
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
loader = SourceFileLoader("file_picker", str(ROOT / "intercom-file-picker"))
PICKER = module_from_spec(spec_from_loader(loader.name, loader))
loader.exec_module(PICKER)


class Variant:
    def __init__(self, signature, value):
        self.signature, self.value = signature, value

    def unpack(self):
        return self.value


class PickerTests(unittest.TestCase):
    def setUp(self):
        self.bus = Mock()
        self.loop = Mock()
        self.context = Mock()
        self.gio = SimpleNamespace(bus_get_sync=Mock(return_value=self.bus),
                                   BusType=SimpleNamespace(SESSION=1),
                                   DBusSignalFlags=SimpleNamespace(NONE=0),
                                   DBusCallFlags=SimpleNamespace(NONE=0))
        self.glib = SimpleNamespace(Variant=Variant, VariantType=SimpleNamespace(new=lambda value: value),
                                    MainLoop=Mock(return_value=self.loop), Error=RuntimeError,
                                    PRIORITY_DEFAULT=0, IOCondition=SimpleNamespace(HUP=1, ERR=2),
                                    io_add_watch=Mock(return_value=3), source_remove=Mock(),
                                    MainContext=SimpleNamespace(default=Mock(return_value=self.context)))
        self.unix = SimpleNamespace(signal_add=Mock(side_effect=[1, 2]))
        self.handle = "/org/freedesktop/portal/desktop/request/test/actual_handle"
        self.events = {}

        def subscribe(sender, interface, event, *args):
            self.events[event] = args[-1]
            return len(self.events)

        def call(*args):
            if args[3] != "Close":
                self.assertIn("Response", self.events, "response subscription must precede the call")
                return Variant("(o)", (self.handle,))

        self.bus.signal_subscribe.side_effect = subscribe
        self.bus.call_sync.side_effect = call

    def response(self, code, results, path=None):
        self.events["Response"](self.bus, PICKER.PORTAL, path or self.handle, PICKER.REQUEST, "Response",
                                Variant("(ua{sv})", (code, results)))

    def run_picker(self, request):
        with patch.object(PICKER.sys, "stdin") as stdin:
            stdin.fileno.return_value = 0
            return PICKER.pick(request, self.gio, self.glib, self.unix)

    def test_open_requests_system_portal_with_multiple_files(self):
        self.loop.run.side_effect = lambda: self.response(0, {"uris": ["file:///home/test/a%20b.txt", "file:///home/test/c.png"]})
        result = self.run_picker({"mode": "open"})
        self.assertEqual(result, {"state": "selected", "files": ["file:///home/test/a%20b.txt", "file:///home/test/c.png"]})
        args = self.bus.call_sync.call_args.args
        self.assertEqual(args[:4], (PICKER.PORTAL, PICKER.DESKTOP, "org.freedesktop.portal.FileChooser", "OpenFile"))
        parent, title, options = args[4].unpack()
        self.assertEqual(parent, "")
        self.assertIn("Attach files", title)
        self.assertTrue(options["multiple"].unpack())
        self.assertTrue(options["modal"].unpack())
        self.assertFalse(options["directory"].unpack())
        self.bus.signal_unsubscribe.assert_any_call(1)
        self.bus.signal_unsubscribe.assert_any_call(2)

    def test_save_preserves_suggested_name_and_local_folder(self):
        self.loop.run.side_effect = lambda: self.response(0, {"uris": ["file:///home/test/Invoice%20%231.pdf"]})
        result = self.run_picker({"mode": "save", "name": "Invoice #1.pdf", "folder": "file:///home/test/My%20Downloads"})
        args = self.bus.call_sync.call_args.args
        self.assertEqual(args[3], "SaveFile")
        options = args[4].unpack()[2]
        self.assertEqual(options["current_name"].unpack(), "Invoice #1.pdf")
        self.assertEqual(options["current_folder"].unpack(), b"/home/test/My Downloads\0")
        self.assertEqual(result["files"], ["file:///home/test/Invoice%20%231.pdf"])

    def test_user_cancel_does_not_return_files_or_send_close_again(self):
        self.loop.run.side_effect = lambda: self.response(1, {})
        self.assertEqual(self.run_picker({}), {"state": "cancelled"})
        self.assertEqual(self.bus.call_sync.call_count, 1)

    def test_terminate_closes_portal_request(self):
        self.loop.run.side_effect = lambda: self.unix.signal_add.call_args_list[0].args[2]()
        self.assertEqual(self.run_picker({}), {"state": "cancelled"})
        self.assertEqual(self.unix.signal_add.call_args_list[0].args[1], signal.SIGTERM)
        self.assertEqual(self.bus.call_sync.call_args.args[:4], (PICKER.PORTAL, self.handle, PICKER.REQUEST, "Close"))

    def test_parent_pipe_closure_closes_portal_request(self):
        self.loop.run.side_effect = lambda: self.glib.io_add_watch.call_args.args[3]()
        self.assertEqual(self.run_picker({}), {"state": "cancelled"})
        self.assertEqual(self.bus.call_sync.call_args.args[3], "Close")

    def test_portal_disappearance_surfaces_error_and_releases_request(self):
        self.loop.run.side_effect = lambda: self.events["NameOwnerChanged"](None, None, None, None, None,
                                                                           Variant("(sss)", (PICKER.PORTAL, ":1.2", "")))
        self.assertEqual(self.run_picker({})["state"], "error")
        self.assertEqual(self.bus.call_sync.call_args.args[3], "Close")

    def test_unrelated_responses_are_ignored(self):
        def run():
            self.response(0, {"uris": ["file:///wrong"]}, "/unrelated")
            self.loop.quit.assert_not_called()
            self.response(0, {"uris": ["file:///right"]})
        self.loop.run.side_effect = run
        self.assertEqual(self.run_picker({})["files"], ["file:///right"])

    def test_portal_errors_and_invalid_results_are_reported(self):
        self.assertEqual(PICKER.selection(2, {}, "open")["state"], "error")
        for uris in ([], "file:///one", ["https://example.com/file"], ["file://remote/etc/passwd"],
                     ["file:///bad%00name"], ["/relative", None], ["file:///a"] * 11):
            with self.subTest(uris=uris), self.assertRaises(ValueError):
                PICKER.selection(0, {"uris": uris}, "open")
        with self.assertRaises(ValueError):
            PICKER.selection(0, {"uris": ["file:///one", "file:///two"]}, "save")

    def test_invalid_options_never_open_portal(self):
        for request in ({"mode": "bad"}, {"mode": "save", "name": "../escape"}, {"mode": "save", "name": ".."},
                        {"folder": "https://example.com"}, {"folder": "relative"}):
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.run_picker(request)
        self.gio.bus_get_sync.assert_not_called()


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
import json
import base64
import io
import os
import tempfile
import threading
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = SourceFileLoader("intercom_fetch", str(ROOT / "intercom-fetch"))
FETCH = module_from_spec(spec_from_loader(loader.name, loader))
loader.exec_module(FETCH)


class FetchTests(unittest.TestCase):
    def test_spam_blocks_original_sender_not_latest_teammate(self):
        conversation = {"id": "123", "source": {"author": {"type": "lead", "id": "customer"}},
                        "conversation_parts": [{"author": {"type": "admin", "id": "teammate"}, "body": "Reply"}]}
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(
            FETCH, "request_json", side_effect=[conversation, {"blocked": True}]
        ) as request:
            result = FETCH.spam_conversation(None, "123")
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["senderId"], "customer")
        self.assertEqual(request.call_args.args[0], "https://api.intercom.io/contacts/customer/block")
        self.assertEqual(request.call_args.kwargs["method"], "POST")
        self.assertEqual(FETCH.normalize_thread(conversation, "US", "ws")["senderId"], "customer")
        self.assertEqual(FETCH.parse_args(["--spam", "123"]).spam, "123")

    def test_spam_refuses_ambiguous_or_unsafe_senders(self):
        for conversation in ({"source": {"author": {"type": "admin", "id": "teammate"}}},
                             {"contacts": {"contacts": [{"id": "one"}, {"id": "two"}]}},
                             {"source": {"author": {"type": "lead", "id": "bad/id"}}}):
            with self.subTest(conversation=conversation), patch.object(FETCH, "read_token", return_value="tok"), patch.object(
                FETCH, "request_json", return_value=conversation
            ) as request:
                result = FETCH.spam_conversation(None, "123")
            self.assertEqual(result["state"], "error")
            self.assertEqual(request.call_count, 1)
        self.assertEqual(FETCH.conversation_sender_id({"contacts": {"contacts": [{"id": "single"}]}}), "single")
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(FETCH, "request_json") as request:
            self.assertEqual(FETCH.spam_conversation(None, "bad/id")["state"], "error")
            request.assert_not_called()
        with patch.object(FETCH, "read_token", return_value=None):
            self.assertEqual(FETCH.spam_conversation(None, "123")["state"], "unconfigured")

    def test_spam_failure_never_retries_mutation_in_another_region(self):
        conversation = {"source": {"author": {"type": "user", "id": "customer"}}}
        for status in (403, 404, 500):
            with self.subTest(status=status), patch.object(FETCH, "read_token", return_value="tok"), patch.object(
                FETCH, "request_json", side_effect=[conversation, FETCH.ApiError(status, "Failed")]
            ) as request:
                result = FETCH.spam_conversation(None, "123")
            self.assertEqual(result["state"], "error")
            self.assertEqual(request.call_count, 2)
            if status == 403:
                self.assertIn("Write users", result["message"])
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(
            FETCH, "request_json", side_effect=[conversation, {}]
        ):
            self.assertEqual(FETCH.spam_conversation(None, "123")["state"], "error")

    def test_spam_discovers_region_before_blocking(self):
        wrong_region = FETCH.ApiError(401, '{"errors":[{"code":"unauthorized","message":"Access Token Invalid"}]}')
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(
            FETCH, "request_json", side_effect=[wrong_region, {"contacts": {"contacts": [{"id": "customer"}]}}, {"blocked": True}]
        ) as request:
            self.assertEqual(FETCH.spam_conversation(None, "123")["state"], "ready")
        self.assertEqual(request.call_args.args[0], "https://api.eu.intercom.io/contacts/customer/block")

    def test_document_attachments_are_retained_searchable_and_deduplicated(self):
        attachment = {"url": "https://example.com/Invoice.PDF?signature=old", "content_type": "application/pdf", "filesize": 1234}
        body, blocks = FETCH.format_message_content("", [attachment, attachment, None, {"url": "file:///etc/passwd"}])
        self.assertEqual(body, "Attachment: Invoice.PDF")
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0], {"type": "attachment", "url": attachment["url"], "name": "Invoice.PDF", "contentType": "application/pdf", "size": 1234})
        conv = {"id": "docs", "source": {"attachments": [attachment]}, "conversation_parts": {"conversation_parts": [
            {"part_type": "comment", "attachments": [attachment], "created_at": 2},
            {"part_type": "note", "body": "See file", "attachments": [{**attachment, "filesize": "bad"}], "created_at": 3},
        ]}}
        messages = FETCH.extract_messages(conv)
        self.assertEqual(len(messages), 3)
        self.assertEqual(messages[-1]["blocks"][-1]["size"], 0)
        self.assertIn("invoice.pdf", FETCH.archive_row_haystack({"id": "docs", "messages": messages}).lower())
        old_id = messages[1]["id"]
        conv["conversation_parts"]["conversation_parts"][0]["attachments"] = [{**attachment, "url": attachment["url"].replace("old", "new")}]
        self.assertEqual(FETCH.extract_messages(conv)[1]["id"], old_id)

    def test_upload_files_encode_binary_with_names_and_mime_types(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory, "screen shot.png")
            image.write_bytes(b"\x00\xffbinary")
            unknown = Path(directory, "unknown.not-a-file-type")
            unknown.write_bytes(b"")
            files = FETCH.reply_attachment_files(json.dumps({"attachments": [image.as_uri(), str(unknown)]}))
        self.assertEqual(files[0], {"name": "screen shot.png", "content_type": "image/png", "data": base64.b64encode(b"\x00\xffbinary").decode("ascii")})
        self.assertEqual(files[1]["content_type"], "application/octet-stream")
        self.assertEqual(files[1]["data"], "")

    def test_invalid_uploads_fail_without_network_or_partial_send(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory, "pipe")
            os.mkfifo(fifo)
            file = Path(directory, "large.txt")
            file.write_bytes(b"12345")
            invalid = [None, "bad", [str(file)] * 11, ["https://example.com/file"], ["file://remote/etc/passwd"],
                       ["relative.txt"], ["/missing/attachment"], [str(fifo)], [directory], ["/bad\x00name"]]
            with patch.object(FETCH, "read_token", return_value="tok"), patch.object(FETCH, "request_json") as request:
                for attachments in invalid:
                    with self.subTest(attachments=attachments):
                        result = FETCH.reply_conversation(None, "123", json.dumps({"body": "Do not send without the file", "attachments": attachments}))
                        self.assertEqual(result["state"], "error")
                with patch.object(FETCH, "MAX_UPLOAD_BYTES", 4):
                    result = FETCH.reply_conversation(None, "123", json.dumps({"body": "Hi", "attachments": [str(file)]}))
                    self.assertIn("20 MiB", result["message"])
                request.assert_not_called()

    def test_attachment_only_replies_and_notes_post_as_signed_in_admin(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "log.txt")
            file.write_text("log contents")
            for note in (False, True):
                posted = []
                def request(url, token, method="GET", payload=None, **kwargs):
                    if url.endswith("/me"):
                        return {"id": "signed-in", "app": {"region": "US"}}
                    if method == "POST":
                        posted.append(payload)
                    return {"id": "123"}
                with patch.object(FETCH, "read_token", return_value="tok"), patch.object(FETCH, "request_json", side_effect=request):
                    result = FETCH.reply_conversation(None, "123", json.dumps({"body": "", "note": note, "attachments": [str(file)]}))
                self.assertEqual(result["state"], "ready")
                self.assertEqual(len(posted), 1)
                self.assertEqual(posted[0]["admin_id"], "signed-in")
                self.assertEqual(posted[0]["message_type"], "note" if note else "comment")
                self.assertEqual(base64.b64decode(posted[0]["attachment_files"][0]["data"]), b"log contents")
                self.assertIn("body", posted[0])

    def test_attachment_reply_still_checks_for_new_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "file.txt")
            file.write_text("attachment")
            thread = {"id": "123", "source": {"id": "new", "created_at": 2, "body": "New comment"}}
            with patch.object(FETCH, "read_token", return_value="tok"), patch.object(FETCH, "request_json", return_value={"id": "admin"}) as request, patch.object(FETCH, "fetch_conversation", return_value=thread):
                result = FETCH.reply_conversation(None, "123", json.dumps({"body": "Reply", "attachments": [str(file)], "seen": [{"id": "old", "createdAt": 1}]}))
            self.assertEqual(result["state"], "error")
            self.assertIn("New comments", result["message"])
            self.assertTrue(all(call.kwargs.get("method", "GET") != "POST" for call in request.call_args_list))

    def test_download_redirects_without_auth_and_saves_binary(self):
        headers = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                headers.append(self.headers)
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/file?signature=secret")
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.send_header("Content-Length", "5")
                    self.end_headers()
                    self.wfile.write(b"\x00\xffabc")
            def log_message(self, *args):
                pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"INTERCOM_ACCESS_TOKEN": "never-send-this"}):
                target = Path(directory, "saved file.bin")
                result = FETCH.download_attachment(json.dumps({"url": f"http://127.0.0.1:{server.server_port}/redirect", "path": target.as_uri()}))
                self.assertEqual(result["state"], "saved")
                self.assertEqual(target.read_bytes(), b"\x00\xffabc")
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("signature", result["message"])
            self.assertEqual(len(headers), 2)
            self.assertTrue(all(header.get("Authorization") is None for header in headers))
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_failed_download_preserves_existing_file_and_removes_partial(self):
        class Response(io.BytesIO):
            headers = {"Content-Length": "9"}
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory, "existing.bin")
            target.write_bytes(b"keep me")
            raw = json.dumps({"url": "https://example.com/file?signature=secret", "path": str(target)})
            with patch.object(FETCH.urllib.request.OpenerDirector, "open", return_value=Response(b"short")):
                result = FETCH.download_attachment(raw)
            self.assertEqual(result["state"], "error")
            self.assertEqual(target.read_bytes(), b"keep me")
            self.assertEqual(list(Path(directory).iterdir()), [target])
            with patch.object(FETCH, "MAX_DOWNLOAD_BYTES", 4), patch.object(FETCH.urllib.request.OpenerDirector, "open", return_value=Response(b"short")):
                self.assertEqual(FETCH.download_attachment(raw)["state"], "error")
            self.assertEqual(target.read_bytes(), b"keep me")

    def test_download_rejects_unsafe_urls_and_destinations(self):
        with patch.object(FETCH.urllib.request.OpenerDirector, "open") as request:
            for url in ("file:///etc/passwd", "data:text/plain,hi", "https://u:p@example.com/a", "https://example.com:bad/a"):
                self.assertEqual(FETCH.download_attachment(json.dumps({"url": url, "path": "/tmp/unused"}))["state"], "error")
            self.assertEqual(FETCH.download_attachment(json.dumps({"url": "https://example.com/a", "path": "relative"}))["state"], "error")
            request.assert_not_called()
        with self.assertRaises(ValueError):
            FETCH.AttachmentRedirectHandler().redirect_request(None, None, 302, "", {}, "file:///etc/passwd")

    def test_collect_search_pages_has_no_total_limit(self):
        first = {
            "total_count": 201,
            "conversations": [{"id": str(i)} for i in range(150)],
            "pages": {"next": {"starting_after": "page-2"}},
        }
        second = {"conversations": [{"id": str(i)} for i in range(149, 201)], "pages": {}}
        body = FETCH.search_open_body(150)
        with patch.object(FETCH, "request_json", return_value=second) as request:
            result = FETCH.collect_search_pages("tok", "US", body, first)
        self.assertEqual(len(result["conversations"]), 201)
        self.assertEqual(result["total_count"], 201)
        self.assertEqual(request.call_args.kwargs["payload"]["pagination"]["starting_after"], "page-2")
        self.assertNotIn("starting_after", body["pagination"])

    def test_collect_search_pages_rejects_repeated_cursor(self):
        page = {"conversations": [{"id": "1"}], "pages": {"next": {"starting_after": "same"}}}
        with patch.object(FETCH, "request_json", return_value=page):
            with self.assertRaises(FETCH.ApiError):
                FETCH.collect_search_pages("tok", "US", FETCH.search_open_body(150), page)

    def test_fetch_open_includes_every_page_even_with_small_page_size(self):
        first = {"total_count": 3, "conversations": [{"id": "1", "state": "open"}],
                 "pages": {"next": {"starting_after": "page-2"}}}
        second = {"conversations": [{"id": "2", "state": "open"}, {"id": "3", "state": "open"}]}
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(
            FETCH, "search_first_region", return_value={"ok": True, "region": "US", "workspace": "ws", "payload": first}
        ), patch.object(FETCH, "request_json", return_value=second), patch.object(
            FETCH, "attach_latest_messages", side_effect=lambda token, region, rows: rows
        ) as details:
            result = FETCH.fetch_open(None, 1)
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["openCount"], 3)
        self.assertEqual(len(result["conversations"]), 3)
        self.assertEqual(len(details.call_args.args[2]), 3)

    def test_fetch_waiting_includes_every_page(self):
        first = {"total_count": 2, "conversations": [{"id": "1", "waiting_since": 10}],
                 "pages": {"next": {"starting_after": "page-2"}}}
        second = {"conversations": [{"id": "2", "waiting_since": 20}]}
        with patch.object(FETCH, "request_json", return_value=second), patch.object(
            FETCH, "attach_latest_messages", side_effect=lambda token, region, rows: rows
        ), patch.object(FETCH, "fetch_inbox_counts", return_value=None):
            result = FETCH.fetch_waiting("tok", "US", "ws", 1, first)
        self.assertEqual(result["waitingCount"], 2)
        self.assertEqual(len(result["conversations"]), 2)

    def test_pagination_failure_does_not_return_a_partial_inbox(self):
        first = {"total_count": 2, "conversations": [{"id": "1", "state": "open"}],
                 "pages": {"next": {"starting_after": "page-2"}}}
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(
            FETCH, "search_first_region", return_value={"ok": True, "region": "US", "workspace": "ws", "payload": first}
        ), patch.object(FETCH, "request_json", side_effect=FETCH.ApiError(500, "Failed page")):
            result = FETCH.fetch_open(None, 1)
        self.assertEqual(result["state"], "error")

    def setUp(self):
        self._xdg = tempfile.TemporaryDirectory()
        self._old_xdg = os.environ.get("XDG_CONFIG_HOME")
        self._old_token = os.environ.get("INTERCOM_ACCESS_TOKEN")
        os.environ["XDG_CONFIG_HOME"] = self._xdg.name
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)

    def tearDown(self):
        if self._old_xdg is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = self._old_xdg
        if self._old_token is None:
            os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        else:
            os.environ["INTERCOM_ACCESS_TOKEN"] = self._old_token
        self._xdg.cleanup()

    def test_hosts(self):
        self.assertEqual(FETCH.api_base_for_region("EU"), "https://api.eu.intercom.io")
        self.assertEqual(FETCH.inbox_host_for_region("au"), "https://app.au.intercom.com")
        self.assertEqual(
            FETCH.conversation_url("EU", "abc", "1295"),
            "https://app.eu.intercom.com/a/inbox/abc/inbox/shared/all/conversation/1295",
        )
        self.assertEqual(FETCH.conversation_url("US", "", "1295"), "")
        self.assertEqual(
            FETCH.inbox_url("US", "xyz"),
            "https://app.intercom.com/a/inbox/xyz/inbox/shared/all",
        )

    def test_parse_workspace_id(self):
        self.assertEqual(
            FETCH.parse_workspace_id(
                "https://app.intercom.com/a/inbox/ecahpwf5/inbox/shared/all/conversation/1295"
            ),
            "ecahpwf5",
        )
        self.assertEqual(
            FETCH.parse_workspace_id("https://app.eu.intercom.com/a/apps/tx2p130c/inbox/inbox/1"),
            "tx2p130c",
        )
        self.assertEqual(FETCH.parse_workspace_id("  abc123  "), "abc123")
        self.assertEqual(FETCH.parse_workspace_id("inbox"), "")
        self.assertEqual(FETCH.parse_workspace_id("/a/inbox/inbox/conversation/1"), "")
        self.assertEqual(
            FETCH.workspace_from_payload({"company": {"app_id": "ecahpwf5"}}),
            "ecahpwf5",
        )
        self.assertEqual(
            FETCH.workspace_from_payload({
                "conversations": [
                    {"id": "1"},
                    {"id": "2", "company": {"app_id": "tx2p130c"}},
                ]
            }),
            "tx2p130c",
        )

    def test_strip_html(self):
        self.assertEqual(FETCH.strip_html("<p>Please &amp; help</p>"), "Please & help")
        self.assertTrue(FETCH.truncate("x" * 400).endswith("…"))
        self.assertLessEqual(len(FETCH.truncate("x" * 400)), 240)

    def test_format_message_body(self):
        self.assertEqual(FETCH.format_message_body("<p>Please &amp; help</p>"), "Please &amp; help")
        self.assertEqual(FETCH.format_message_body("<p>Hello</p><p>World</p>"), "Hello<br><br>World")
        self.assertEqual(FETCH.format_message_body("<p>Hello<br>World</p>"), "Hello<br>World")
        self.assertEqual(FETCH.format_message_body("line1<br>line2"), "line1<br>line2")
        self.assertEqual(FETCH.format_message_body("plain\nbreaks"), "plain<br>breaks")
        self.assertEqual(FETCH.format_message_body("<ul><li>a</li><li>b</li></ul>"), "a<br>b")
        self.assertEqual(
            FETCH.format_message_body("<b>bold</b> and <i>italic</i>"),
            "<b>bold</b> and <i>italic</i>",
        )
        self.assertEqual(
            FETCH.format_message_body("<strong>b</strong> <em>i</em>"),
            "<b>b</b> <i>i</i>",
        )
        styled = FETCH.format_message_body('See <a href="https://example.com/path">this link</a>')
        self.assertIn('href="https://example.com/path"', styled)
        self.assertIn(">this link</a>", styled)
        self.assertEqual(FETCH.format_message_body('<a href="javascript:alert(1)">x</a>'), "x")
        linked = FETCH.format_message_body("Visit https://example.com/path for more")
        self.assertIn('<a href="https://example.com/path">https://example.com/path</a>', linked)
        self.assertEqual(FETCH.format_message_body("<p></p>"), "")
        self.assertEqual(FETCH.format_message_body("<div>Hello</div><div>World</div>"), "Hello<br>World")
        self.assertEqual(
            FETCH.format_message_body("<div>Hello</div><div><br></div><div>World</div>"),
            "Hello<br><br>World",
        )
        gmail = (
            '<div dir="ltr"><div>Account Name: Grimké Seminary</div>'
            "<div><br></div>"
            "<div>Account Owner: Kyle Archuleta</div>"
            "<div><span><br></span></div>"
            "<div><br></div>"
            "<span>-- </span><br>"
            "<div><div><b>Zack Veselik</b></div>"
            "<b>Account Executive</b></div></div>"
        )
        self.assertEqual(
            FETCH.format_message_body(gmail),
            "Account Name: Grimké Seminary<br><br>"
            "Account Owner: Kyle Archuleta<br><br>"
            "-- <br><b>Zack Veselik</b><br><b>Account Executive</b>",
        )
        self.assertEqual(FETCH.is_safe_http_url("https://example.com"), "https://example.com")
        self.assertEqual(FETCH.is_safe_http_url("javascript:alert(1)"), "")

    def test_parse_me(self):
        me = FETCH.parse_me({
            "id": "42",
            "name": "Ada",
            "email": "ada@example.com",
            "app": {"id_code": "abc123", "region": "EU"},
        })
        self.assertEqual(me["workspaceId"], "abc123")
        self.assertEqual(me["region"], "EU")
        self.assertEqual(me["id"], "42")
        self.assertEqual(me["email"], "ada@example.com")
        self.assertEqual(
            FETCH.identity_from_me(me),
            {"adminId": "42", "adminName": "Ada", "adminEmail": "ada@example.com"},
        )
        self.assertEqual(FETCH.identity_from_me(None), {})
        self.assertEqual(FETCH.identity_from_me({"id": "7"}), {"adminId": "7"})

    def test_inline_images_preserve_order_and_balanced_formatting(self):
        url = "https://downloads.intercomcdn.com/shot.png?signature=abc&expires=123"
        body, blocks = FETCH.format_message_content(
            '<p><b>Before <a href="https://example.com/full"><i>inside'
            f'<img src="{url.replace("&", "&amp;")}" alt="Screenshot" width="800" height="600">'
            'after</i></a> end</b></p>'
        )
        self.assertEqual([b["type"] for b in blocks], ["text", "image", "text"])
        self.assertEqual(blocks[0]["text"], '<b>Before <a href="https://example.com/full"><i>inside</i></a></b>')
        self.assertEqual(blocks[2]["text"], '<b><a href="https://example.com/full"><i>after</i></a> end</b>')
        self.assertEqual(blocks[1]["url"], url)
        self.assertEqual(blocks[1]["linkUrl"], "https://example.com/full")
        self.assertEqual(blocks[1]["width"], 800)
        self.assertNotIn("<img", body)

    def test_image_attachments_merge_inline_metadata_without_duplicate_previews(self):
        url = "https://example.com/image?signature=a&expires=1"
        attachment = {"url": url, "name": "screenshot.png", "content_type": "image/png", "width": 500, "height": 300}
        _, blocks = FETCH.format_message_content(f'<img src="{url}">', [
            attachment, attachment, {"url": "https://example.com/file.pdf", "content_type": "application/pdf"},
            {"url": "file:///etc/passwd", "content_type": "image/png"}, None,
        ])
        self.assertEqual([block["type"] for block in blocks], ["image", "attachment"])
        self.assertEqual(blocks[0]["name"], "screenshot.png")
        self.assertEqual(blocks[0]["width"], 500)
        _, repeated = FETCH.format_message_content(f'<img src="{url}"><img src="{url}">', [attachment])
        self.assertEqual(len(repeated), 2)  # Repetition in the message is intentional.
        self.assertTrue(all(b["width"] == 500 for b in repeated))
        _, intercom = FETCH.format_message_content(
            '<img src="https://downloads.intercomcdn.com/i/o/workspace/upload/shot.png?signature=inline">',
            [{**attachment, "url": "https://workspace.intercom-attachments-3.com/i/o/workspace/upload/shot.png?signature=attachment"}],
        )
        self.assertEqual(len(intercom), 1)
        self.assertEqual(intercom[0]["name"], "screenshot.png")
        self.assertEqual(intercom[0]["width"], 500)
        _, unrelated = FETCH.format_message_content('<img src="https://example.com/shot.png">', [
            {**attachment, "url": "https://other.example/shot.png"}
        ])
        self.assertEqual(len(unrelated), 2)
        _, extension = FETCH.format_message_content("", [{"url": "https://example.com/shot.PNG?download=1"}])
        self.assertEqual(extension[0]["type"], "image")

    def test_image_only_source_replies_and_notes_are_retained(self):
        attachment = {"url": "https://example.com/shot.png", "name": "screenshot.png", "content_type": "image/png"}
        conv = {"id": "images", "created_at": 1,
                "source": {"id": "src", "attachments": [attachment], "author": {"type": "user", "name": "Ada"}},
                "conversation_parts": {"conversation_parts": [
                    {"id": "reply", "part_type": "comment", "created_at": 2, "body": '<img src="https://example.com/reply.png"/>', "author": {"type": "admin"}},
                    {"id": "note", "part_type": "note", "created_at": 3, "attachments": [attachment]},
                    {"id": "system", "part_type": "assignment", "created_at": 4, "attachments": [attachment], "author": {"type": "bot"}},
                ]}}
        messages = FETCH.extract_messages(conv)
        self.assertEqual([m["id"] for m in messages], ["src", "reply", "note"])
        self.assertEqual([m["kind"] for m in messages], ["customer", "teammate", "note"])
        self.assertEqual(messages[0]["body"], "Image: screenshot.png")
        self.assertTrue(all(m["blocks"][0]["type"] == "image" for m in messages))
        self.assertTrue(FETCH.conversation_identity(conv)[2].startswith("Image:"))
        conv["conversation_parts"]["conversation_parts"] = []
        self.assertEqual(FETCH.conversation_identity(conv), ("Ada", "", "Image: screenshot.png"))

    def test_image_urls_and_malformed_metadata_are_safe(self):
        for url in ["file:///etc/passwd", "qrc:/image.png", "data:image/png;base64,abc", "cid:mail-image",
                    "javascript:alert(1)", "https://", "https://u:p@example.com/a.png", "https://example.com:bad/a.png",
                    "https://example.com/\x00.png", "https://example.com\\@evil.com/a.png"]:
            with self.subTest(url=url):
                self.assertEqual(FETCH.image_url(url), "")
        body, blocks = FETCH.format_message_content('<img src="cid:unknown" alt="Missing screenshot">')
        self.assertIn("Missing screenshot", body)
        self.assertEqual(blocks[0]["type"], "text")
        _, blocks = FETCH.format_message_content('<img src="https://example.com/a.png" width="nan" height="-20">')
        self.assertEqual((blocks[0]["width"], blocks[0]["height"]), (0, 0))

    def test_image_message_identity_survives_signed_url_refresh(self):
        def message(signature):
            return FETCH.extract_messages({"conversation_parts": {"conversation_parts": [
                {"part_type": "comment", "created_at": 1, "body": f'<img src="https://example.com/a.png?signature={signature}">'}
            ]}})[0]
        self.assertEqual(message("old")["id"], message("new")["id"])
        self.assertEqual(FETCH.image_identity("https://example.com/image?id=1&X-Amz-Signature=abc&Expires=123#fragment"), "https://example.com/image?id=1")
        self.assertNotEqual(FETCH.image_identity("https://example.com/image?id=1"), FETCH.image_identity("https://example.com/image?id=2"))

    def test_archive_media_upgrade_and_filename_search(self):
        FETCH.write_json_file(FETCH.archive_thread_path("legacy"), {"id": "legacy", "state": "closed"})
        self.assertFalse(FETCH.archive_thread_stored("legacy"))
        conv = {"id": "legacy", "state": "closed", "source": {"body": "See this", "attachments": [
            {"url": "https://example.com/a.png", "name": "invoice-screenshot.png", "content_type": "image/png"}
        ]}}
        with patch.object(FETCH, "fetch_archive_thread", return_value=conv) as fetch:
            self.assertEqual(FETCH.sync_search_page("token", "US", "ws", [conv], {}), (1, 1, 0, 0))
            fetch.assert_called_once()
        self.assertTrue(FETCH.archive_thread_stored("legacy"))
        with patch.object(FETCH, "fetch_archive_thread") as fetch:
            self.assertEqual(FETCH.sync_search_page("token", "US", "ws", [conv], {}), (1, 0, 1, 0))
            fetch.assert_not_called()
        self.assertEqual([r["id"] for r in FETCH.search_archive_local("invoice-screenshot")], ["legacy"])

    def test_normalize_and_sort(self):
        payload = {
            "total_count": 3,
            "conversations": [
                {
                    "id": "2",
                    "title": "Later",
                    "waiting_since": 200,
                    "source": {
                        "body": "<p>Hi</p>",
                        "author": {"name": "Bo", "email": "bo@example.com"},
                    },
                },
                {
                    "id": "1",
                    "waiting_since": 100,
                    "source": {"subject": "First", "body": "Hello"},
                },
                {
                    "id": "skip",
                    "waiting_since": None,
                    "source": {"body": "done"},
                },
                {
                    "id": "snoozed",
                    "waiting_since": 50,
                    "state": "snoozed",
                    "snoozed_until": 9999999999,
                    "source": {"body": "Later"},
                },
            ],
        }
        parsed = FETCH.parse_search(payload, "US", "ws", 20)
        self.assertEqual(parsed["waitingCount"], 2)
        self.assertTrue(all(row["state"] == "open" for row in parsed["conversations"]))
        self.assertEqual([row["id"] for row in parsed["conversations"]], ["2", "1"])
        self.assertEqual(parsed["conversations"][0]["title"], "Later")
        self.assertEqual(parsed["conversations"][0]["snippet"], "Hi")
        self.assertEqual(parsed["conversations"][0]["from"], "Bo")
        self.assertEqual(parsed["conversations"][0]["email"], "bo@example.com")
        self.assertEqual(parsed["conversations"][1]["title"], "First")
        self.assertEqual(
            parsed["conversations"][0]["url"],
            "https://app.intercom.com/a/inbox/ws/inbox/shared/all/conversation/2",
        )
        self.assertEqual(parsed["conversations"][0]["messages"][0]["body"], "Hi")

    def test_conversation_identity_uses_last_comment(self):
        conv = {
            "created_at": 100,
            "source": {
                "created_at": 100,
                "body": "First message",
                "author": {"name": "Ada", "type": "user"},
            },
            "conversation_parts": {
                "type": "conversation_part.list",
                "conversation_parts": [
                    {
                        "part_type": "note",
                        "created_at": 400,
                        "body": "Internal note",
                        "author": {"name": "Teammate", "type": "admin"},
                    },
                    {
                        "part_type": "comment",
                        "created_at": 200,
                        "body": "<p>Later ping</p>",
                        "author": {"name": "Ada", "type": "user"},
                    },
                    {
                        "part_type": "assignment",
                        "created_at": 300,
                        "body": "Assigned to inbox",
                        "author": {"name": "Operator", "type": "bot"},
                    },
                    {
                        "part_type": "comment",
                        "created_at": 350,
                        "body": "<p>Newest question</p>",
                        "author": {
                            "name": "Ada Lovelace",
                            "email": "ada@example.com",
                            "type": "user",
                        },
                    },
                    {
                        "part_type": "assignment",
                        "created_at": 380,
                        "body": "Assigned to inbox",
                        "author": {"name": "Operator", "type": "bot"},
                    },
                ],
            },
        }
        self.assertEqual(FETCH.conversation_identity(conv), (
            "Ada Lovelace",
            "ada@example.com",
            "Newest question",
        ))
        self.assertEqual(FETCH.author_label({"type": "admin"}), "Teammate")
        self.assertEqual(FETCH.author_label({"email": "ada@example.com"}), "ada@example.com")
        self.assertEqual(
            FETCH.author_label({"name": "Ada Lovelace", "email": "ada@example.com"}),
            "Ada Lovelace",
        )
        self.assertEqual(
            FETCH.author_email_for_display({"name": "Ada Lovelace", "email": "ada@example.com"}),
            "ada@example.com",
        )
        self.assertEqual(FETCH.author_email_for_display({"email": "ada@example.com"}), "")
        self.assertEqual(
            FETCH.author_label({"name": "ada@example.com", "email": "ada@example.com"}),
            "ada@example.com",
        )
        self.assertTrue(FETCH.is_message_part("assignment", {"type": "admin"}))
        self.assertTrue(FETCH.is_message_part("assignment", {"type": "admin"}, public_only=True))
        self.assertFalse(FETCH.is_message_part("assignment", {"type": "bot"}))
        self.assertFalse(FETCH.is_message_part("note", {"type": "admin"}, public_only=True))
        assigned_reply = {
            "waiting_since": 0,
            "source": {
                "created_at": 100,
                "body": "Need help",
                "author": {"name": "Ada", "type": "user"},
            },
            "conversation_parts": {
                "conversation_parts": [
                    {
                        "part_type": "assignment",
                        "created_at": 200,
                        "body": "<p>On it, assigned to me.</p>",
                        "author": {"name": "Bo", "type": "admin"},
                    }
                ]
            },
        }
        self.assertEqual(FETCH.conversation_identity(assigned_reply), ("Bo", "", "On it, assigned to me."))
        self.assertEqual(
            [row["kind"] for row in FETCH.extract_messages(assigned_reply)],
            ["customer", "teammate"],
        )

    def test_search_body(self):
        body = FETCH.search_body(20)
        fields = {item["field"] for item in body["query"]["value"]}
        self.assertEqual(fields, {"open", "state", "waiting_since"})
        self.assertEqual(body["sort"]["field"], "waiting_since")
        self.assertEqual(body["sort"]["order"], "descending")
        self.assertNotIn("read", json.dumps(body))
        self.assertNotIn("admin_assignee_id", json.dumps(body))
        self.assertFalse(FETCH.is_snoozed({"state": "open", "snoozed_until": None}))
        self.assertTrue(FETCH.is_snoozed({"state": "snoozed"}))
        self.assertTrue(FETCH.is_snoozed({"snoozed_until": 4000}, now=1000))
        self.assertFalse(FETCH.is_snoozed({"snoozed_until": 500}, now=1000))

    def test_search_open_body(self):
        body = FETCH.search_open_body(20)
        fields = {item["field"] for item in body["query"]["value"]}
        self.assertEqual(fields, {"open", "state"})
        self.assertNotIn("waiting_since", json.dumps(body))
        self.assertEqual(body["sort"]["field"], "updated_at")
        self.assertEqual(body["sort"]["order"], "descending")

    def test_search_inbox_bodies(self):
        closed = FETCH.search_inbox_body("closed", 20)
        fields = {item["field"] for item in closed["query"]["value"] if isinstance(item, dict)}
        self.assertEqual(closed["query"]["value"][0]["value"], "closed")
        self.assertEqual(fields, {"state"})
        self.assertEqual(closed["sort"]["field"], "updated_at")
        self.assertEqual(closed["pagination"]["per_page"], 20)
        self.assertEqual(closed["query"]["value"], [{"field": "state", "operator": "=", "value": "closed"}])
        count_only = FETCH.search_inbox_body("closed", 1)
        count_fields = {item["field"] for item in count_only["query"]["value"] if isinstance(item, dict)}
        self.assertEqual(count_fields, {"state"})
        snoozed = FETCH.search_inbox_body("snoozed", 15)
        snoozed_fields = {item["field"] for item in snoozed["query"]["value"] if isinstance(item, dict)}
        self.assertEqual(snoozed["query"]["value"][0]["value"], "snoozed")
        self.assertEqual(snoozed_fields, {"state"})
        self.assertEqual(snoozed["pagination"]["per_page"], 15)
        self.assertEqual(
            FETCH.search_inbox_body("all", 20)["query"]["operator"],
            "OR",
        )
        self.assertEqual(
            FETCH.search_inbox_body("waiting", 10),
            FETCH.search_body(10),
        )
        self.assertEqual(
            FETCH.search_inbox_body("open", 10),
            FETCH.search_open_body(10),
        )

    def test_inbox_counts_use_one_row_and_sum_all(self):
        self.assertEqual(FETCH.search_total_count({"total_count": 12}), 12)
        self.assertEqual(FETCH.search_total_count({"conversations": [{}, {}]}), 2)
        self.assertEqual(FETCH.search_inbox_body("closed", 1)["pagination"]["per_page"], 1)
        calls = []

        def fake_request(url, token, method="GET", payload=None):
            calls.append(payload)
            query = (payload or {}).get("query") or {}
            values = query.get("value") if isinstance(query.get("value"), list) else []
            if any(item.get("field") == "open" for item in values if isinstance(item, dict)):
                return {"total_count": 5, "conversations": [{"id": "open"}]}
            state = values[0].get("value") if values and isinstance(values[0], dict) else ""
            if state == "closed":
                return {"total_count": 9, "conversations": [{"id": "closed"}]}
            if state == "snoozed":
                return {"total_count": 2, "conversations": [{"id": "snoozed"}]}
            return {"total_count": 0, "conversations": []}

        with patch.object(FETCH, "request_json", side_effect=fake_request):
            counts = FETCH.fetch_inbox_counts("tok", "US")
        self.assertEqual(counts, {"open": 5, "closed": 9, "snoozed": 2, "all": 16})
        self.assertEqual(len(calls), 3)
        for payload in calls:
            self.assertEqual(payload["pagination"]["per_page"], 1)
            self.assertLessEqual(len(payload.get("query", {}).get("value", [])), 2)
        self.assertEqual(
            FETCH.inbox_count_fields(counts),
            {"openCount": 5, "closedCount": 9, "snoozedCount": 2, "allCount": 16},
        )
        self.assertEqual(FETCH.inbox_count_fields(None), {})

    def test_fetch_waiting_includes_inbox_counts(self):
        waiting_payload = {
            "total_count": 1,
            "conversations": [
                {
                    "id": "1",
                    "waiting_since": 50,
                    "source": {"body": "Hi", "author": {"name": "Ada"}},
                }
            ],
        }
        with patch.object(FETCH, "attach_latest_messages", return_value=waiting_payload["conversations"]), patch.object(
            FETCH,
            "fetch_inbox_counts",
            return_value={"open": 4, "closed": 8, "snoozed": 1, "all": 13},
        ):
            result = FETCH.fetch_waiting("tok", "US", "ws", 5, waiting_payload)
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["waitingCount"], 1)
        self.assertEqual(result["openCount"], 4)
        self.assertEqual(result["closedCount"], 8)
        self.assertEqual(result["snoozedCount"], 1)
        self.assertEqual(result["allCount"], 13)
        with patch.object(FETCH, "attach_latest_messages", return_value=waiting_payload["conversations"]), patch.object(
            FETCH,
            "fetch_inbox_counts",
            return_value=None,
        ):
            missing = FETCH.fetch_waiting("tok", "US", "ws", 5, waiting_payload)
        self.assertNotIn("closedCount", missing)
        self.assertNotIn("snoozedCount", missing)
        self.assertNotIn("allCount", missing)

    def test_search_all_body_includes_closed(self):
        body = FETCH.search_all_body(150)
        states = {item["value"] for item in body["query"]["value"]}
        self.assertEqual(body["query"]["operator"], "OR")
        self.assertEqual(states, {"open", "closed", "snoozed"})
        self.assertNotIn("waiting_since", json.dumps(body))
        self.assertEqual(body["pagination"]["per_page"], 150)
        self.assertNotIn("starting_after", body["pagination"])
        paged = FETCH.search_all_body(50, "cursor-9")
        self.assertEqual(paged["pagination"]["per_page"], 50)
        self.assertEqual(paged["pagination"]["starting_after"], "cursor-9")
        self.assertEqual(
            FETCH.search_next_cursor({"pages": {"next": {"starting_after": "abc"}}}),
            "abc",
        )
        self.assertEqual(FETCH.search_next_cursor({"pages": {"next": "abc"}}), "abc")
        self.assertEqual(FETCH.search_next_cursor({}), "")
        self.assertEqual(FETCH.conversation_state({"state": "closed"}), "closed")
        self.assertEqual(FETCH.conversation_state({"open": False}), "closed")
        self.assertEqual(FETCH.conversation_state({"state": "open"}), "open")
        self.assertEqual(FETCH.conversation_state({"state": "snoozed"}), "snoozed")
        self.assertEqual(
            FETCH.conversation_state({"state": "open", "snoozed_until": 9_999_999_999}),
            "snoozed",
        )
        self.assertEqual(
            FETCH.conversation_state({"state": "closed", "snoozed_until": 9_999_999_999}),
            "closed",
        )
        self.assertFalse(FETCH.should_fetch_archive_thread("closed", True))
        self.assertTrue(FETCH.should_fetch_archive_thread("closed", False))
        self.assertTrue(FETCH.should_fetch_archive_thread("open", True))
        record = FETCH.archive_thread_record(
            {
                "id": "1295",
                "title": "Billing",
                "state": "closed",
                "updated_at": 400,
                "source": {
                    "body": "<p>Hi</p>",
                    "author": {"type": "user", "name": "Ada"},
                    "created_at": 10,
                },
                "conversation_parts": {"conversation_parts": []},
            },
            "US",
            "ws",
        )
        self.assertEqual(record["id"], "1295")
        self.assertEqual(record["state"], "closed")
        self.assertEqual(record["from"], "Ada")
        self.assertEqual(record["updatedAt"], 400)
        self.assertEqual(len(record["messages"]), 1)
        row = FETCH.archive_index_row(record)
        self.assertEqual(row["id"], "1295")
        self.assertEqual(row["state"], "closed")
        self.assertEqual(row["snippet"], "Hi")

    def test_search_remote_body_and_local_archive(self):
        body = FETCH.search_remote_body("billing ada")
        self.assertEqual(body["query"]["operator"], "OR")
        fields = [item.get("field") for item in body["query"]["value"] if isinstance(item, dict)]
        self.assertIn("source.author.name", fields)
        self.assertTrue(any(item.get("operator") == "AND" for item in body["query"]["value"]))
        self.assertEqual(FETCH.search_tokens("  Billing  Ada "), ["billing", "ada"])
        empty = FETCH.search_conversations(None, "   ")
        self.assertEqual(empty["state"], "error")
        FETCH.write_json_file(
            FETCH.archive_index_path(),
            {
                "syncedAt": 1,
                "count": 1,
                "conversations": {
                    "1": {
                        "id": "1",
                        "title": "Billing question",
                        "from": "Ada",
                        "email": "ada@example.com",
                        "snippet": "Please refund",
                        "state": "closed",
                    }
                },
            },
        )
        FETCH.write_json_file(
            FETCH.archive_thread_path("2"),
            {
                "id": "2",
                "title": "Login",
                "from": "Bo",
                "state": "open",
                "messages": [{"body": "I cannot reset my password"}],
            },
        )
        local = FETCH.search_conversations(None, "password")
        self.assertEqual(local["state"], "ready")
        self.assertEqual([row["id"] for row in local["conversations"]], ["2"])
        titled = FETCH.search_conversations(None, "billing ada")
        self.assertEqual([row["id"] for row in titled["conversations"]], ["1"])
        self.assertTrue(FETCH.parse_args(["--search", "billing", "--remote"]).remote)
        self.assertEqual(FETCH.parse_args(["--search", "billing"]).search, "billing")

    def test_parse_inbox_search_open_skips_snoozed_and_sorts_recent(self):
        payload = {
            "total_count": 4,
            "conversations": [
                {
                    "id": "old",
                    "title": "Older",
                    "updated_at": 100,
                    "waiting_since": 50,
                    "source": {"body": "Hi", "author": {"name": "Ada"}},
                },
                {
                    "id": "new",
                    "title": "Newer",
                    "updated_at": 300,
                    "waiting_since": None,
                    "source": {"body": "Later", "author": {"name": "Bo"}},
                },
                {
                    "id": "snoozed",
                    "title": "Snoozed",
                    "updated_at": 400,
                    "state": "snoozed",
                    "source": {"body": "Wait"},
                },
                {
                    "id": "until",
                    "title": "Snoozed until",
                    "updated_at": 500,
                    "state": "open",
                    "snoozed_until": 9_999_999_999,
                    "source": {"body": "Later"},
                },
            ],
        }
        parsed = FETCH.parse_inbox_search(payload, "US", "ws", 20, "open")
        self.assertEqual([row["id"] for row in parsed["conversations"]], ["new", "old"])
        self.assertEqual(parsed["conversations"][0]["updatedAt"], 300)
        self.assertEqual(parsed["conversations"][0]["from"], "Bo")
        self.assertEqual(parsed["conversations"][1]["waitingSince"], 50)
        self.assertEqual(parsed["openCount"], 2)
        self.assertEqual(parsed["waitingCount"], 1)
        self.assertEqual(parsed["conversations"][0]["state"], "open")
        closed = FETCH.parse_inbox_search(
            {
                "total_count": 2,
                "conversations": [
                    {
                        "id": "done",
                        "title": "Closed",
                        "state": "closed",
                        "updated_at": 200,
                        "source": {"body": "Thanks", "author": {"name": "Ada"}},
                    },
                    {
                        "id": "open",
                        "title": "Still open",
                        "state": "open",
                        "updated_at": 300,
                        "source": {"body": "Hi", "author": {"name": "Bo"}},
                    },
                ],
            },
            "US",
            "ws",
            20,
            "closed",
        )
        self.assertEqual([row["id"] for row in closed["conversations"]], ["done"])
        self.assertEqual(closed["inboxCount"], 2)
        self.assertEqual(closed["openCount"], 0)
        snoozed = FETCH.parse_inbox_search(
            {
                "total_count": 1,
                "conversations": [
                    {
                        "id": "later",
                        "title": "Snoozed",
                        "state": "snoozed",
                        "updated_at": 400,
                        "source": {"body": "Wait", "author": {"name": "Cy"}},
                    }
                ],
            },
            "US",
            "ws",
            20,
            "snoozed",
        )
        self.assertEqual([row["id"] for row in snoozed["conversations"]], ["later"])
        self.assertEqual(snoozed["conversations"][0]["state"], "snoozed")
        snoozed_until = FETCH.parse_inbox_search(
            {
                "total_count": 2,
                "conversations": [
                    {
                        "id": "later",
                        "title": "Snoozed",
                        "state": "open",
                        "snoozed_until": 9_999_999_999,
                        "updated_at": 400,
                        "source": {"body": "Wait", "author": {"name": "Cy"}},
                    },
                    {
                        "id": "also",
                        "title": "Also snoozed",
                        "snoozed_until": 9_999_999_999,
                        "updated_at": 300,
                        "source": {"body": "Hold", "author": {"name": "Di"}},
                    },
                ],
            },
            "US",
            "ws",
            20,
            "snoozed",
        )
        self.assertEqual([row["id"] for row in snoozed_until["conversations"]], ["later", "also"])
        self.assertEqual({row["state"] for row in snoozed_until["conversations"]}, {"snoozed"})
        self.assertEqual(snoozed_until["inboxCount"], 2)
        mixed = FETCH.parse_inbox_search(
            {
                "total_count": 3,
                "conversations": [
                    {
                        "id": "done",
                        "state": "closed",
                        "updated_at": 200,
                        "source": {"body": "Thanks"},
                    },
                    {
                        "id": "later",
                        "state": "snoozed",
                        "updated_at": 400,
                        "source": {"body": "Wait"},
                    },
                    {
                        "id": "open",
                        "state": "open",
                        "updated_at": 300,
                        "source": {"body": "Hi"},
                    },
                ],
            },
            "US",
            "ws",
            20,
            "all",
        )
        self.assertEqual([row["id"] for row in mixed["conversations"]], ["later", "open", "done"])
        self.assertEqual(mixed["inboxCount"], 3)

    def test_parse_inbox_search_open_uses_latest_parts(self):
        payload = {
            "total_count": 1,
            "conversations": [
                {
                    "id": "1",
                    "title": "Billing",
                    "updated_at": 300,
                    "source": {
                        "body": "Hi",
                        "author": {"name": "Ada", "email": "ada@example.com", "type": "user"},
                    },
                    "conversation_parts": {
                        "conversation_parts": [
                            {
                                "part_type": "comment",
                                "created_at": 400,
                                "body": "<p>Latest from customer</p>",
                                "author": {
                                    "name": "Bo",
                                    "email": "bo@example.com",
                                    "type": "user",
                                },
                            }
                        ]
                    },
                }
            ],
        }
        parsed = FETCH.parse_inbox_search(payload, "US", "ws", 20, "open")
        row = parsed["conversations"][0]
        self.assertEqual(row["from"], "Bo")
        self.assertEqual(row["email"], "bo@example.com")
        self.assertEqual(row["snippet"], "Latest from customer")

    def test_attach_latest_messages_copies_snoozed_state(self):
        def fake_detail(token, region, conv_id):
            return {
                "id": conv_id,
                "state": "snoozed",
                "open": True,
                "snoozed_until": 9_999_999_999,
                "source": {"body": "Hi"},
            }

        with patch.object(FETCH, "fetch_conversation_detail", side_effect=fake_detail):
            merged = FETCH.attach_latest_messages(
                "tok",
                "US",
                [{"id": "1", "state": "open", "source": {"body": "old"}}],
            )
        self.assertEqual(merged[0]["state"], "snoozed")
        self.assertEqual(merged[0]["snoozed_until"], 9_999_999_999)
        self.assertTrue(merged[0]["open"])

    def test_fetch_open_attaches_latest_messages(self):
        search_payload = {
            "total_count": 1,
            "conversations": [
                {
                    "id": "1",
                    "title": "Billing",
                    "updated_at": 300,
                    "source": {"body": "Hi", "author": {"name": "Ada", "type": "user"}},
                }
            ],
        }
        enriched = [
            {
                "id": "1",
                "title": "Billing",
                "updated_at": 300,
                "source": {"body": "Hi", "author": {"name": "Ada", "type": "user"}},
                "conversation_parts": {
                    "conversation_parts": [
                        {
                            "part_type": "comment",
                            "created_at": 400,
                            "body": "Latest from customer",
                            "author": {
                                "name": "Bo",
                                "email": "bo@example.com",
                                "type": "user",
                            },
                        }
                    ]
                },
            }
        ]
        with patch.object(FETCH, "read_token", return_value="tok"), patch.object(
            FETCH,
            "search_first_region",
            return_value={
                "ok": True,
                "region": "US",
                "workspace": "ws",
                "payload": search_payload,
            },
        ), patch.object(FETCH, "attach_latest_messages", return_value=enriched) as attach:
            result = FETCH.fetch_open("/tmp/tok", 5)
        attach.assert_called_once_with("tok", "US", search_payload["conversations"])
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["conversations"][0]["from"], "Bo")
        self.assertEqual(result["conversations"][0]["email"], "bo@example.com")
        self.assertEqual(result["conversations"][0]["snippet"], "Latest from customer")

    def test_extract_messages_keeps_notes_and_skips_system_parts(self):
        conv = {
            "id": "9",
            "created_at": 100,
            "source": {
                "id": "src",
                "created_at": 100,
                "body": "<p>First question</p>",
                "author": {
                    "name": "Ada",
                    "email": "ada@example.com",
                    "type": "user",
                },
            },
            "conversation_parts": {
                "type": "conversation_part.list",
                "total_count": 7,
                "conversation_parts": [
                    {
                        "id": "n1",
                        "part_type": "note",
                        "created_at": 150,
                        "body": "Internal context",
                        "author": {"name": "Teammate", "type": "admin"},
                    },
                    {
                        "id": "c1",
                        "part_type": "comment",
                        "created_at": 200,
                        "body": "<p>We can help</p>",
                        "author": {"name": "Bo", "type": "admin"},
                    },
                    {
                        "id": "a1",
                        "part_type": "assignment",
                        "created_at": 180,
                        "body": "Assigned to inbox",
                        "author": {"name": "Operator", "type": "bot"},
                    },
                    {
                        "id": "z1",
                        "part_type": "snoozed",
                        "created_at": 190,
                        "body": "Snoozed until Monday",
                        "author": {"name": "Bo", "type": "admin"},
                    },
                    {
                        "id": "r1",
                        "part_type": "assignment",
                        "created_at": 250,
                        "body": "<p>We will take this from here.</p>",
                        "author": {"name": "Bo", "type": "admin"},
                    },
                    {
                        "id": "nr1",
                        "part_type": "note_and_reopen",
                        "created_at": 260,
                        "body": "Reopened to follow up",
                        "author": {"name": "Bo", "type": "admin"},
                    },
                    {
                        "id": "cl1",
                        "part_type": "close",
                        "created_at": 270,
                        "body": "<p>Closing this out.</p>",
                        "author": {"name": "Bo", "type": "admin"},
                    },
                ],
            },
        }
        messages = FETCH.extract_messages(conv)
        self.assertEqual([row["id"] for row in messages], ["src", "n1", "c1", "r1", "nr1", "cl1"])
        self.assertEqual(messages[0]["kind"], "customer")
        self.assertEqual(messages[1]["kind"], "note")
        self.assertEqual(messages[1]["body"], "Internal context")
        self.assertEqual(messages[0]["from"], "Ada")
        self.assertEqual(messages[0]["email"], "ada@example.com")
        self.assertEqual(messages[2]["kind"], "teammate")
        self.assertEqual(messages[2]["from"], "Bo")
        self.assertEqual(messages[2]["email"], "")
        self.assertEqual(messages[3]["kind"], "teammate")
        self.assertEqual(messages[3]["body"], "We will take this from here.")
        self.assertEqual(messages[4]["kind"], "note")
        self.assertEqual(messages[4]["body"], "Reopened to follow up")
        self.assertEqual(messages[5]["kind"], "teammate")
        self.assertEqual(messages[5]["body"], "Closing this out.")
        self.assertEqual(FETCH.message_kind("comment", {"type": "bot"}), "bot")
        self.assertEqual(FETCH.message_kind("note_and_reopen", {"type": "admin"}), "note")
        thread = FETCH.normalize_thread(conv, "US", "ws")
        self.assertEqual(thread["id"], "9")
        self.assertEqual(thread["state"], "open")
        self.assertEqual(len(thread["messages"]), 6)
        self.assertEqual(FETCH.conversation_identity(conv), ("Bo", "", "Closing this out."))

    def test_permission_errors(self):
        missing = FETCH.ApiError(
            401,
            json.dumps({
                "type": "error.list",
                "errors": [{"code": "token_unauthorized", "message": "Not authorized to access resource"}],
            }),
        )
        wrong_region = FETCH.ApiError(
            401,
            json.dumps({
                "type": "error.list",
                "errors": [{"code": "unauthorized", "message": "Access Token Invalid"}],
            }),
        )
        self.assertTrue(FETCH.is_missing_permission(missing))
        self.assertFalse(FETCH.is_wrong_region(missing))
        self.assertTrue(FETCH.is_wrong_region(wrong_region))
        self.assertFalse(FETCH.is_missing_permission(wrong_region))
        self.assertIn("missing a permission", FETCH.summarize_error(401, missing.body))

    def test_read_token_env_wins(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "from-env"
        try:
            self.assertEqual(FETCH.read_token("/no/such/file"), "from-env")
        finally:
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_read_token_file(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as handle:
            handle.write(" file-token \n")
            path = handle.name
        try:
            self.assertEqual(FETCH.read_token(path), "file-token")
        finally:
            os.unlink(path)

    def test_unconfigured_without_token(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        result = FETCH.fetch("/no/such/token", 5)
        self.assertEqual(result["state"], "unconfigured")
        self.assertIn("Sign in", result["message"])
        self.assertEqual(result["waitingCount"], 0)
        self.assertEqual(FETCH.fetch_open("/no/such/token", 5)["state"], "unconfigured")
        self.assertEqual(FETCH.fetch_thread("/no/such/token", "1295")["state"], "unconfigured")

    def test_parse_args_open_and_conversation(self):
        open_args = FETCH.parse_args(["--open", "--limit", "15"])
        self.assertTrue(open_args.open)
        self.assertEqual(open_args.limit, 15)
        self.assertEqual(open_args.conversation, "")
        thread_args = FETCH.parse_args(["--conversation", "1295"])
        self.assertEqual(thread_args.conversation, "1295")
        self.assertFalse(thread_args.open)
        self.assertEqual(FETCH.parse_args(["--reply", "1295"]).reply, "1295")
        self.assertEqual(FETCH.parse_args(["--close", "1295"]).close, "1295")
        self.assertEqual(FETCH.parse_args(["--reopen", "1295"]).reopen, "1295")
        self.assertTrue(FETCH.parse_args(["--sync"]).sync)
        self.assertTrue(FETCH.parse_args(["--login"]).login)
        self.assertTrue(FETCH.parse_args(["--save-oauth"]).save_oauth)
        panel_args = FETCH.parse_args(["--panel", "expanded"])
        self.assertEqual(panel_args.panel, "expanded")

    def test_save_prefs_persists_in_config(self):
        self.assertEqual(FETCH.panel_mode(""), "expanded")
        self.assertEqual(FETCH.panel_mode("expanded"), "expanded")
        self.assertEqual(FETCH.panel_mode("large"), "large")
        self.assertEqual(FETCH.panel_mode("LARGE"), "large")
        self.assertEqual(FETCH.panel_mode("COMPACT"), "expanded")
        result = FETCH.save_prefs(panel="expanded")
        self.assertEqual(result["state"], "saved")
        self.assertEqual(result["panel"], "expanded")
        self.assertEqual(FETCH.load_config().get("panel"), "expanded")
        self.assertEqual(FETCH.panel_mode(), "expanded")
        large = FETCH.save_prefs(panel="large")
        self.assertEqual(large["panel"], "large")
        self.assertEqual(FETCH.load_config().get("panel"), "large")
        compact = FETCH.save_prefs(panel="compact")
        self.assertEqual(compact["panel"], "expanded")
        self.assertEqual(FETCH.load_config().get("panel"), "expanded")
        with open(FETCH.config_path(), "w", encoding="utf-8") as handle:
            json.dump({"panel": "compact", "filter": "open"}, handle)
        self.assertEqual(FETCH.load_config().get("panel"), "expanded")
        self.assertEqual(FETCH.panel_mode(), "expanded")
        self.assertEqual(FETCH.normalize_panel_mode("nope"), "expanded")
        self.assertEqual(FETCH.normalize_panel_mode(None), "expanded")
        waiting = FETCH.save_prefs(inbox_filter="waiting")
        self.assertEqual(waiting["filter"], "waiting")
        self.assertEqual(FETCH.filter_mode(), "waiting")
        self.assertEqual(FETCH.load_config().get("filter"), "waiting")
        opened = FETCH.save_prefs(inbox_filter="open")
        self.assertEqual(opened["filter"], "open")
        closed = FETCH.save_prefs(inbox_filter="closed")
        self.assertEqual(closed["filter"], "closed")
        self.assertEqual(FETCH.filter_mode(), "closed")
        snoozed = FETCH.save_prefs(inbox_filter="snoozed")
        self.assertEqual(snoozed["filter"], "snoozed")
        all_filter = FETCH.save_prefs(inbox_filter="all")
        self.assertEqual(all_filter["filter"], "all")
        self.assertEqual(FETCH.filter_mode("nope"), "open")
        filter_args = FETCH.parse_args(["--filter", "waiting"])
        self.assertEqual(filter_args.filter, "waiting")
        self.assertEqual(FETCH.parse_args(["--inbox", "closed"]).inbox, "closed")
        self.assertEqual(FETCH.viewed_conversation(""), "")
        self.assertEqual(FETCH.viewed_conversation("1295/other"), "")
        viewed = FETCH.save_prefs(viewed="1295")
        self.assertEqual(viewed["viewed"], "1295")
        self.assertEqual(FETCH.load_config().get("viewed"), "1295")
        self.assertEqual(FETCH.viewed_conversation(), "1295")
        self.assertEqual(FETCH.parse_args(["--viewed", "1295"]).viewed, "1295")
        self.assertEqual(FETCH.save_prefs(viewed="bad id")["state"], "error")

    def test_save_token_writes_mode_600(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "omarchy-intercom-client", "token")
            result = FETCH.save_token("  secret-token  \n", path)
            self.assertEqual(result["state"], "saved")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(os.stat(os.path.dirname(path)).st_mode & 0o777, 0o700)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "secret-token\n")
            self.assertEqual(FETCH.read_token(path), "secret-token")

    def test_save_token_rejects_empty(self):
        result = FETCH.save_token("   \n", "/tmp/unused-token")
        self.assertEqual(result["state"], "error")
        self.assertIn("Paste", result["message"])

    def test_read_token_next_to_plugin(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        plugin_token = ROOT / "token"
        created = not plugin_token.exists()
        if created:
            plugin_token.write_text(" plugin-token \n", encoding="utf-8")
        try:
            if created:
                self.assertEqual(FETCH.read_token("/no/such/token"), "plugin-token")
        finally:
            if created:
                plugin_token.unlink()

    def test_markdown_to_html(self):
        self.assertEqual(FETCH.markdown_to_html("**bold**"), "<b>bold</b>")
        self.assertEqual(FETCH.markdown_to_html("__bold__"), "<b>bold</b>")
        self.assertEqual(FETCH.markdown_to_html("*italic*"), "<i>italic</i>")
        self.assertEqual(FETCH.markdown_to_html("_italic_"), "<i>italic</i>")
        self.assertEqual(
            FETCH.markdown_to_html("[docs](https://example.com/path)"),
            '<a href="https://example.com/path">docs</a>',
        )
        self.assertEqual(FETCH.markdown_to_html("line1\nline2"), "line1<br>line2")
        self.assertEqual(FETCH.markdown_to_html("<script>x</script>"), "&lt;script&gt;x&lt;/script&gt;")
        self.assertEqual(FETCH.markdown_to_html("[x](javascript:alert(1))"), "[x](javascript:alert(1))")
        self.assertEqual(FETCH.markdown_to_html("not_mid_word"), "not_mid_word")
        self.assertEqual(FETCH.markdown_to_html("   "), "")
        self.assertEqual(
            FETCH.markdown_to_html("`code goes here`"),
            "<code>code goes here</code>",
        )
        self.assertEqual(
            FETCH.markdown_to_html("see `*raw*` and **bold**"),
            "see <code>*raw*</code> and <b>bold</b>",
        )
        self.assertEqual(
            FETCH.markdown_to_html("```\ncode goes here\n```"),
            "<pre><code>code goes here</code></pre>",
        )
        self.assertEqual(
            FETCH.markdown_to_html("```code block\nacross\nmultiple\nlines\n```"),
            "<pre><code>across\nmultiple\nlines</code></pre>",
        )
        self.assertEqual(
            FETCH.markdown_to_html("```python\nprint(1)\nprint(2)\n```"),
            "<pre><code>print(1)\nprint(2)</code></pre>",
        )
        self.assertEqual(
            FETCH.markdown_to_html("before\n```\n*not italic*\n<script>\n```\nafter"),
            "before<br><pre><code>*not italic*\n&lt;script&gt;</code></pre><br>after",
        )
        self.assertEqual(
            FETCH.markdown_to_html("```\nstill open\nmore"),
            "<pre><code>still open\nmore</code></pre>",
        )

    def test_parse_reply_markdown(self):
        self.assertEqual(FETCH.parse_reply_markdown('{"body":"Hello **there**"}'), "Hello **there**")
        self.assertEqual(FETCH.parse_reply_markdown("plain"), "plain")
        self.assertEqual(FETCH.parse_reply_markdown('{"body":""}'), "")
        body, seen, note = FETCH.parse_reply_request('{"body":"Hi","seen":[{"id":"c1","createdAt":9}]}')
        self.assertEqual(body, "Hi")
        self.assertEqual(seen, [{"id": "c1", "createdAt": 9}])
        self.assertFalse(note)
        self.assertEqual(FETCH.parse_reply_request('{"body":"Hi"}')[1], None)
        self.assertEqual(FETCH.parse_reply_request('{"body":"Hi","seen":[]}')[1], [])
        self.assertTrue(FETCH.parse_reply_request('{"body":"Hi","note":true}')[2])
        self.assertFalse(FETCH.parse_reply_request('{"body":"Hi","note":false}')[2])

    def test_newer_comments_includes_notes_and_ignores_older_unseen_parts(self):
        fresh = [
            {"id": "old", "kind": "customer", "createdAt": 50, "body": "Hi"},
            {"id": "seen", "kind": "customer", "createdAt": 100, "body": "There"},
            {"id": "note", "kind": "note", "createdAt": 150, "body": "Internal"},
            {"id": "new", "kind": "teammate", "createdAt": 200, "body": "On it"},
        ]
        seen = [{"id": "seen", "createdAt": 100}]
        new_rows = FETCH.newer_comments(fresh, seen)
        self.assertEqual([row["id"] for row in new_rows], ["note", "new"])
        self.assertEqual(FETCH.newer_comments(fresh[:2], seen), [])
        self.assertEqual(FETCH.newer_comments(fresh, []), [])

    def test_admin_reply_body_uses_me_id_only(self):
        body = FETCH.admin_reply_body("9912", "<b>Hi</b>")
        self.assertEqual(body["message_type"], "comment")
        self.assertEqual(body["type"], "admin")
        self.assertEqual(body["admin_id"], "9912")
        self.assertEqual(body["body"], "<b>Hi</b>")
        self.assertEqual(list(body.keys()), ["message_type", "type", "admin_id", "body"])
        note = FETCH.admin_reply_body("9912", "<i>Private</i>", "note")
        self.assertEqual(note["message_type"], "note")
        self.assertEqual(note["body"], "<i>Private</i>")
        self.assertEqual(FETCH.admin_reply_body("9912", "Hi", "NOTE")["message_type"], "note")
        self.assertEqual(FETCH.admin_reply_body("9912", "Hi", "comment")["message_type"], "comment")
        close_body = FETCH.admin_part_body("9912", "close")
        self.assertEqual(close_body, {
            "message_type": "close",
            "type": "admin",
            "admin_id": "9912",
        })
        self.assertEqual(FETCH.admin_part_body("9912", "open"), {
            "message_type": "open",
            "type": "admin",
            "admin_id": "9912",
        })

    def test_oauth_authorize_url(self):
        url = FETCH.oauth_authorize_url("abc", "state-1", "EU")
        self.assertTrue(url.startswith("https://app.eu.intercom.com/oauth?"))
        self.assertIn("client_id=abc", url)
        self.assertIn("state=state-1", url)
        self.assertIn("redirect_uri=", url)
        self.assertIn("localhost%3A18741", url)

    def test_revoked_token_is_unconfigured(self):
        revoked = FETCH.ApiError(
            401,
            json.dumps({
                "type": "error.list",
                "errors": [{"code": "unauthorized", "message": "Access Token Invalid"}],
            }),
        )
        missing = FETCH.ApiError(
            401,
            json.dumps({
                "type": "error.list",
                "errors": [{"code": "token_unauthorized", "message": "Not authorized to access resource"}],
            }),
        )
        self.assertTrue(FETCH.is_revoked_token(revoked))
        self.assertFalse(FETCH.is_revoked_token(missing))
        payload = FETCH.region_failure_payload(revoked)
        self.assertEqual(payload["state"], "unconfigured")
        self.assertIn("Sign in", payload["message"])
        self.assertNotIn("refresh", payload["message"].lower())
        self.assertEqual(FETCH.region_failure_payload(missing)["state"], "error")

    def test_reply_empty_body_does_not_call_network(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        try:
            empty = FETCH.reply_conversation(None, "1295", "")
            self.assertEqual(empty["state"], "error")
            self.assertIn("Write a message", empty["message"])
            wrapped = FETCH.reply_conversation(None, "1295", '{"body":"   "}')
            self.assertEqual(wrapped["state"], "error")
            missing_id = FETCH.reply_conversation(None, "", '{"body":"Hi"}')
            self.assertEqual(missing_id["state"], "error")
            self.assertIn("conversation id", missing_id["message"])
            unsafe_id = FETCH.reply_conversation(None, "1295/other", '{"body":"Hi"}')
            self.assertEqual(unsafe_id["state"], "error")
            self.assertIn("conversation id", unsafe_id["message"])
        finally:
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reply_404_does_not_post_to_another_region(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {
                "conversation_parts": [
                    {
                        "id": "old",
                        "part_type": "comment",
                        "body": "<p>Old</p>",
                        "created_at": 100,
                        "author": {"type": "user", "name": "Ada"},
                    }
                ]
            },
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if "/conversations/1295" in url and not url.endswith("/reply"):
                return thread
            raise FETCH.ApiError(404, '{"errors":[{"message":"Not Found"}]}', url)

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reply_conversation(
                None,
                "1295",
                json.dumps({
                    "body": "Hi",
                    "seen": [{"id": "src", "createdAt": 10}, {"id": "old", "createdAt": 100}],
                }),
            )
            self.assertEqual(result["state"], "error")
            reply_posts = [url for method, url in calls if method == "POST" and url.endswith("/reply")]
            self.assertEqual(len(reply_posts), 1)
            self.assertIn("/conversations/1295/reply", reply_posts[0])
            me_calls = [url for method, url in calls if url.endswith("/me")]
            self.assertEqual(len(me_calls), 1)
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reply_aborts_when_new_comments_appear(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {
                "conversation_parts": [
                    {
                        "id": "old",
                        "part_type": "comment",
                        "body": "<p>Old</p>",
                        "created_at": 100,
                        "author": {"type": "user", "name": "Ada"},
                    },
                    {
                        "id": "dup",
                        "part_type": "comment",
                        "body": "<p>Already sent</p>",
                        "created_at": 200,
                        "author": {"type": "admin", "name": "Bo"},
                    },
                ]
            },
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if "/conversations/1295" in url:
                self.assertNotEqual(method, "POST")
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reply_conversation(
                None,
                "1295",
                json.dumps({
                    "body": "Hi",
                    "seen": [{"id": "src", "createdAt": 10}, {"id": "old", "createdAt": 100}],
                }),
            )
            self.assertEqual(result["state"], "error")
            self.assertIn("new comments", result["message"].lower())
            self.assertEqual(result["conversation"]["id"], "1295")
            self.assertTrue(any(row["id"] == "dup" for row in result["conversation"]["messages"]))
            self.assertFalse(any(method == "POST" for method, _url in calls))
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reply_aborts_when_new_note_appears(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {
                "conversation_parts": [
                    {
                        "id": "old",
                        "part_type": "comment",
                        "body": "<p>Old</p>",
                        "created_at": 100,
                        "author": {"type": "user", "name": "Ada"},
                    },
                    {
                        "id": "note1",
                        "part_type": "note",
                        "body": "<p>Internal</p>",
                        "created_at": 150,
                        "author": {"type": "admin", "name": "Bo"},
                    },
                ]
            },
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if "/conversations/1295" in url:
                self.assertNotEqual(method, "POST")
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reply_conversation(
                None,
                "1295",
                json.dumps({
                    "body": "Hi",
                    "seen": [{"id": "src", "createdAt": 10}, {"id": "old", "createdAt": 100}],
                }),
            )
            self.assertEqual(result["state"], "error")
            self.assertIn("new comments", result["message"].lower())
            self.assertTrue(any(row["id"] == "note1" for row in result["conversation"]["messages"]))
            self.assertFalse(any(method == "POST" for method, _url in calls))
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reply_posts_when_thread_is_unchanged(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {
                "conversation_parts": [
                    {
                        "id": "old",
                        "part_type": "comment",
                        "body": "<p>Old</p>",
                        "created_at": 100,
                        "author": {"type": "user", "name": "Ada"},
                    }
                ]
            },
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if method == "POST" and url.endswith("/reply"):
                return thread
            if "/conversations/1295" in url:
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reply_conversation(
                None,
                "1295",
                json.dumps({
                    "body": "Hi",
                    "seen": [{"id": "src", "createdAt": 10}, {"id": "old", "createdAt": 100}],
                }),
            )
            self.assertEqual(result["state"], "ready")
            reply_posts = [url for method, url in calls if method == "POST" and url.endswith("/reply")]
            self.assertEqual(len(reply_posts), 1)
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reply_posts_note_when_requested(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        posted = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {"conversation_parts": []},
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if method == "POST" and url.endswith("/reply"):
                posted.append(payload)
                return thread
            if "/conversations/1295" in url:
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reply_conversation(
                None,
                "1295",
                json.dumps({"body": "Internal", "seen": [], "note": True}),
            )
            self.assertEqual(result["state"], "ready")
            self.assertEqual(len(posted), 1)
            self.assertEqual(posted[0]["message_type"], "note")
            self.assertEqual(posted[0]["admin_id"], "9912")
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reply_posts_when_seen_is_empty(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {
                "conversation_parts": [
                    {
                        "id": "old",
                        "part_type": "comment",
                        "body": "<p>Old</p>",
                        "created_at": 100,
                        "author": {"type": "user", "name": "Ada"},
                    }
                ]
            },
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if method == "POST" and url.endswith("/reply"):
                return thread
            if "/conversations/1295" in url:
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reply_conversation(
                None,
                "1295",
                json.dumps({"body": "Hi", "seen": []}),
            )
            self.assertEqual(result["state"], "ready")
            reply_posts = [url for method, url in calls if method == "POST" and url.endswith("/reply")]
            self.assertEqual(len(reply_posts), 1)
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_save_oauth_writes_mode_600(self):
        result = FETCH.save_oauth('{"clientId":"id-1","clientSecret":"sec-1"}')
        self.assertEqual(result["state"], "saved")
        path = FETCH.oauth_path()
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        loaded = FETCH.load_oauth()
        self.assertEqual(loaded["clientId"], "id-1")
        self.assertEqual(loaded["clientSecret"], "sec-1")
        kept = FETCH.save_oauth('{"clientId":"id-2"}')
        self.assertEqual(kept["state"], "saved")
        self.assertEqual(FETCH.load_oauth()["clientSecret"], "sec-1")
        self.assertEqual(FETCH.save_oauth("{}")["state"], "saved")
        self.assertEqual(FETCH.save_oauth("not-json")["state"], "error")

    def test_logout_removes_token_and_identity(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        plugin_token = Path(FETCH.plugin_token_path())
        plugin_backup = plugin_token.read_text(encoding="utf-8") if plugin_token.is_file() else None
        try:
            path = FETCH.default_token_path()
            saved = FETCH.save_token("secret-token", path)
            self.assertEqual(saved["state"], "saved")
            FETCH.save_config(adminId="42", adminName="Ada", adminEmail="ada@example.com")
            FETCH.save_oauth('{"clientId":"id-1","clientSecret":"sec-1"}')
            result = FETCH.logout(path)
            self.assertEqual(result["state"], "unconfigured")
            self.assertIn("Signed out", result["message"])
            self.assertFalse(os.path.isfile(path))
            self.assertEqual(result["adminName"], "")
            self.assertEqual(result["adminId"], "")
            self.assertEqual(FETCH.load_config().get("adminName"), "")
            self.assertEqual(FETCH.load_oauth()["clientId"], "id-1")
            self.assertTrue(FETCH.parse_args(["--logout"]).logout)
        finally:
            if plugin_backup is None:
                if plugin_token.is_file():
                    plugin_token.unlink()
            else:
                plugin_token.write_text(plugin_backup, encoding="utf-8")

    def test_logout_blocked_by_env_token(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "env-token"
        plugin_token = Path(FETCH.plugin_token_path())
        plugin_backup = plugin_token.read_text(encoding="utf-8") if plugin_token.is_file() else None
        try:
            FETCH.save_config(adminId="42", adminName="Ada")
            result = FETCH.logout(None)
            self.assertEqual(result["state"], "error")
            self.assertIn("INTERCOM_ACCESS_TOKEN", result["message"])
        finally:
            if plugin_backup is None:
                if plugin_token.is_file():
                    plugin_token.unlink()
            else:
                plugin_token.write_text(plugin_backup, encoding="utf-8")

    def test_unconfigured_reply_without_token(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        result = FETCH.reply_conversation("/no/such/token", "1295", '{"body":"Hi"}')
        self.assertEqual(result["state"], "unconfigured")
        self.assertIn("Sign in", result["message"])

    def test_close_conversation_posts_parts(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        posted = []
        calls = []
        thread = {
            "id": "1295",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {"conversation_parts": []},
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if method == "POST" and url.endswith("/parts"):
                posted.append(payload)
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            missing = FETCH.close_conversation(None, "")
            self.assertEqual(missing["state"], "error")
            self.assertIn("conversation id", missing["message"])
            unsafe = FETCH.close_conversation(None, "1295/other")
            self.assertEqual(unsafe["state"], "error")
            result = FETCH.close_conversation(None, "1295")
            self.assertEqual(result["state"], "ready")
            self.assertEqual(result["conversation"]["id"], "1295")
            self.assertEqual(result["conversation"]["state"], "closed")
            self.assertEqual(len(posted), 1)
            self.assertEqual(posted[0]["message_type"], "close")
            self.assertEqual(posted[0]["type"], "admin")
            self.assertEqual(posted[0]["admin_id"], "9912")
            self.assertEqual(len([url for method, url in calls if method == "POST"]), 1)
            self.assertIn("/conversations/1295/parts", calls[-1][1])
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_close_404_does_not_post_to_another_region(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            raise FETCH.ApiError(404, '{"errors":[{"message":"Not Found"}]}', url)

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.close_conversation(None, "1295")
            self.assertEqual(result["state"], "error")
            parts_posts = [url for method, url in calls if method == "POST" and url.endswith("/parts")]
            self.assertEqual(len(parts_posts), 1)
            me_calls = [url for method, url in calls if url.endswith("/me")]
            self.assertEqual(len(me_calls), 1)
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reopen_conversation_posts_open_part(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        posted = []
        calls = []
        thread = {
            "id": "1295",
            "state": "open",
            "source": {
                "id": "src",
                "body": "<p>Hello</p>",
                "created_at": 10,
                "author": {"type": "user", "name": "Ada"},
            },
            "conversation_parts": {"conversation_parts": []},
        }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            if method == "POST" and url.endswith("/parts"):
                posted.append(payload)
                return thread
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            missing = FETCH.reopen_conversation(None, "")
            self.assertEqual(missing["state"], "error")
            self.assertIn("conversation id", missing["message"])
            unsafe = FETCH.reopen_conversation(None, "1295/other")
            self.assertEqual(unsafe["state"], "error")
            result = FETCH.reopen_conversation(None, "1295")
            self.assertEqual(result["state"], "ready")
            self.assertEqual(result["conversation"]["id"], "1295")
            self.assertEqual(result["conversation"]["state"], "open")
            self.assertEqual(len(posted), 1)
            self.assertEqual(posted[0]["message_type"], "open")
            self.assertEqual(posted[0]["type"], "admin")
            self.assertEqual(posted[0]["admin_id"], "9912")
            self.assertEqual(len([url for method, url in calls if method == "POST"]), 1)
            self.assertIn("/conversations/1295/parts", calls[-1][1])
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_reopen_404_does_not_post_to_another_region(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        calls = []

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            calls.append((method, url))
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US"}}
            raise FETCH.ApiError(404, '{"errors":[{"message":"Not Found"}]}', url)

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.reopen_conversation(None, "1295")
            self.assertEqual(result["state"], "error")
            parts_posts = [url for method, url in calls if method == "POST" and url.endswith("/parts")]
            self.assertEqual(len(parts_posts), 1)
            me_calls = [url for method, url in calls if url.endswith("/me")]
            self.assertEqual(len(me_calls), 1)
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_unconfigured_reopen_without_token(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        result = FETCH.reopen_conversation("/no/such/token", "1295")
        self.assertEqual(result["state"], "unconfigured")
        self.assertIn("Sign in", result["message"])

    def test_unconfigured_close_without_token(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        result = FETCH.close_conversation("/no/such/token", "1295")
        self.assertEqual(result["state"], "unconfigured")
        self.assertIn("Sign in", result["message"])

    def test_unconfigured_sync_without_token(self):
        os.environ.pop("INTERCOM_ACCESS_TOKEN", None)
        result = FETCH.sync_conversations("/no/such/token")
        self.assertEqual(result["state"], "unconfigured")
        self.assertIn("Sign in", result["message"])

    def test_sync_stores_new_threads_and_skips_stored_closed(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        FETCH.write_json_file(
            FETCH.archive_thread_path("old-closed"),
            {"id": "old-closed", "state": "closed", "contentVersion": FETCH.CONTENT_VERSION, "messages": [{"body": "Stored"}]},
        )
        gets = []
        searches = []

        def thread(conv_id, state, body):
            return {
                "id": conv_id,
                "title": conv_id,
                "state": state,
                "updated_at": 50,
                "source": {
                    "id": "src-" + conv_id,
                    "body": f"<p>{body}</p>",
                    "created_at": 10,
                    "author": {"type": "user", "name": "Ada"},
                },
                "conversation_parts": {"conversation_parts": []},
            }

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US", "id_code": "ws1"}}
            if method == "POST" and url.endswith("/conversations/search"):
                searches.append(payload)
                cursor = (payload.get("pagination") or {}).get("starting_after") or ""
                if cursor == "":
                    return {
                        "total_count": 3,
                        "conversations": [
                            thread("open-1", "open", "Still waiting"),
                            thread("new-closed", "closed", "Thanks"),
                        ],
                        "pages": {"next": {"starting_after": "page-2"}},
                    }
                return {
                    "total_count": 3,
                    "conversations": [thread("old-closed", "closed", "Ignore me")],
                    "pages": {},
                }
            if method == "GET" and "/conversations/" in url:
                conv_id = url.rsplit("/", 1)[-1].split("?")[0]
                gets.append(conv_id)
                if conv_id == "open-1":
                    return thread("open-1", "open", "Still waiting")
                if conv_id == "new-closed":
                    return thread("new-closed", "closed", "Thanks")
                raise AssertionError(f"unexpected GET {conv_id}")
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.sync_conversations(None)
            self.assertEqual(result["state"], "ready")
            self.assertEqual(result["scanned"], 3)
            self.assertEqual(result["stored"], 2)
            self.assertEqual(result["skipped"], 1)
            self.assertEqual(sorted(gets), ["new-closed", "open-1"])
            self.assertEqual(len(searches), 2)
            self.assertEqual(searches[1]["pagination"]["starting_after"], "page-2")
            stored = FETCH.read_json_file(FETCH.archive_thread_path("new-closed"))
            self.assertEqual(stored["state"], "closed")
            self.assertEqual(stored["messages"][0]["body"], "Thanks")
            skipped = FETCH.read_json_file(FETCH.archive_thread_path("old-closed"))
            self.assertEqual(skipped["messages"][0]["body"], "Stored")
            index = FETCH.load_archive_index()
            self.assertIn("open-1", index)
            self.assertIn("new-closed", index)
            self.assertIn("old-closed", index)
            status = FETCH.read_json_file(FETCH.archive_status_path())
            self.assertEqual(status["state"], "ready")
            self.assertEqual(status["skipped"], 1)
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]

    def test_search_remote_uses_intercom_query(self):
        os.environ["INTERCOM_ACCESS_TOKEN"] = "test-token"
        posted = []

        def fake_request_json(url, token, method="GET", payload=None, version=None):
            if url.endswith("/me"):
                return {"id": "9912", "name": "Bo", "email": "bo@example.com", "app": {"region": "US", "id_code": "ws1"}}
            if method == "POST" and url.endswith("/conversations/search"):
                posted.append(payload)
                return {
                    "total_count": 1,
                    "conversations": [
                        {
                            "id": "9",
                            "title": "Refund",
                            "state": "closed",
                            "updated_at": 40,
                            "source": {
                                "body": "Please refund",
                                "author": {"type": "user", "name": "Ada", "email": "ada@example.com"},
                            },
                        }
                    ],
                }
            raise AssertionError(f"unexpected {method} {url}")

        original = FETCH.request_json
        FETCH.request_json = fake_request_json
        try:
            result = FETCH.search_conversations(None, "refund", True)
            self.assertEqual(result["state"], "ready")
            self.assertEqual(result["conversations"][0]["id"], "9")
            self.assertEqual(result["conversations"][0]["state"], "closed")
            self.assertEqual(len(posted), 1)
            self.assertEqual(posted[0]["query"]["operator"], "OR")
        finally:
            FETCH.request_json = original
            del os.environ["INTERCOM_ACCESS_TOKEN"]


if __name__ == "__main__":
    unittest.main()

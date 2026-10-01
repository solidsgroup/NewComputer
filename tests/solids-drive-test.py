#!/usr/bin/env python3
"""Exercise Drive lifecycle without Google accounts; optionally mount real FUSE."""
import configparser
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1] / "drive/solids-drive"
loader = importlib.machinery.SourceFileLoader("solids_drive", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
drive = importlib.util.module_from_spec(spec)
loader.exec_module(drive)
CLIENT = {"client_id": "test.apps.googleusercontent.com", "client_secret": "test-secret"}
TOKEN = {"access_token": "test-access", "refresh_token": "test-refresh", "expiry": "2099-01-01T00:00:00Z"}


class DriveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.app = drive.Drive(self.home, "brunnels")
        self.client = self.home / "client.json"
        self.client.write_text(json.dumps({"installed": CLIENT}))
        self.lock = self.home / "oauth.lock"
        self.lock.touch()
        self.addCleanup(patch.stopall)
        patch.object(drive, "CLIENT_FILE", self.client).start()
        patch.object(drive, "AUTH_LOCK", self.lock).start()
        self.message = patch.object(drive, "message").start()

    def config(self, token=TOKEN):
        config = configparser.ConfigParser(interpolation=None)
        config["solids"] = {"type": "drive", "team_drive": drive.DRIVE_ID, **CLIENT,
                            "token": json.dumps(token)}
        stream = io.StringIO()
        config.write(stream)
        drive.atomic_write(self.app.config, stream.getvalue())

    def test_desktop_client_validation_and_private_user_storage(self):
        self.assertEqual(drive.read_client(self.client), CLIENT)
        for data in ({"web": CLIENT}, {"installed": {**CLIENT, "client_secret": "a\nb"}}, {},
                     {"installed": {**CLIENT, "client_id": "wrong-host"}}):
            self.client.write_text(json.dumps(data))
            with self.assertRaises(drive.SetupError):
                drive.read_client(self.client)
        self.config()
        self.assertEqual(self.app.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.app.config.stat().st_mode & 0o777, 0o600)

    def test_existing_credentials_reused_on_repeated_logins(self):
        self.config()
        for _ in range(2):
            self.app.stopping = False
            with patch.object(self.app, "authorize") as auth, \
                 patch.object(self.app, "access", return_value=(0, "")), \
                 patch.object(self.app, "mount", side_effect=lambda: self.app.stop()), \
                 patch.object(self.app, "stop_mount"):
                self.app.run()
                auth.assert_not_called()

    def test_cancel_preserves_credentials_and_retries_next_login(self):
        self.config()
        before = self.app.config.read_bytes()
        with patch.object(self.app, "execute", return_value=(1, "cancelled")):
            self.assertFalse(self.app.authorize(CLIENT))
        self.assertEqual(self.app.config.read_bytes(), before)
        self.app.config.unlink()
        with patch.object(self.app, "authorize", return_value=False) as auth:
            self.app.run()
            self.app.run()
            self.assertEqual(auth.call_count, 2)

    def test_successful_auth_atomic_and_no_secrets_in_arguments(self):
        def authorize(*args, config, timeout):
            self.assertEqual(args[:3], ("config", "update", "solids"))
            for secret in (*CLIENT.values(), *TOKEN.values()):
                self.assertNotIn(secret, args)
            self.assertIn(CLIENT["client_secret"], config.read_text())
            with config.open("a") as stream:
                stream.write("token = " + json.dumps(TOKEN) + "\n")
            return 0, ""
        with patch.object(self.app, "execute", side_effect=authorize):
            self.assertTrue(self.app.authorize(CLIENT))
        self.assertTrue(self.app.configured(CLIENT))
        self.assertEqual(self.app.config.stat().st_mode & 0o777, 0o600)

    def test_failed_token_result_does_not_replace_existing_config(self):
        self.config()
        before = self.app.config.read_bytes()
        with patch.object(self.app, "execute", return_value=(0, "")):
            self.assertFalse(self.app.authorize(CLIENT))
        self.assertEqual(self.app.config.read_bytes(), before)

    def test_offline_and_permission_errors_never_trigger_browser(self):
        self.config()
        for error in ("no such host", "403 Forbidden", "quota exceeded", "Request timed out"):
            self.app.stopping = False
            with patch.object(self.app, "access", return_value=(1, error)), \
                 patch.object(self.app, "authorize") as auth, \
                 patch.object(self.app, "wait_retry", side_effect=self.app.stop):
                self.app.run()
                auth.assert_not_called()

    def test_revoked_token_prompts_only_once_per_login(self):
        self.config()
        with patch.object(self.app, "access", return_value=(1, "oauth2: invalid_grant")), \
             patch.object(self.app, "authorize", return_value=True) as auth:
            self.app.run()
            auth.assert_called_once()

    def test_different_users_have_separate_config_cache_and_mounts(self):
        other = drive.Drive(self.home / "alice", "alice")
        for attribute in ("config", "cache", "mountpoint"):
            self.assertNotEqual(getattr(self.app, attribute), getattr(other, attribute))
        self.config()
        self.assertFalse(other.configured(CLIENT))

    def test_fixed_drive_and_environment_cannot_be_redirected(self):
        self.config()
        self.app.config.write_text(self.app.config.read_text().replace(drive.DRIVE_ID, "wrong"))
        with self.assertRaises(drive.SetupError):
            self.app.configured(CLIENT)
        with patch.dict(os.environ, {"RCLONE_DRIVE_TEAM_DRIVE": "wrong", "RCLONE_CONFIG": "wrong"}):
            self.assertFalse(any(key.startswith("RCLONE_") for key in self.app.environment()))

    def test_nonempty_and_symlink_mountpoints_are_preserved(self):
        self.app.mountpoint.mkdir()
        file = self.app.mountpoint / "important.txt"
        file.write_text("keep")
        with self.assertRaises(drive.SetupError):
            self.app.prepare_mountpoint()
        self.assertEqual(file.read_text(), "keep")
        file.unlink()
        self.app.mountpoint.rmdir()
        self.app.mountpoint.symlink_to(self.home)
        with self.assertRaises(drive.SetupError):
            self.app.prepare_mountpoint()

    def test_username_cannot_escape_remote_directory(self):
        for name in ("../alice", "a/b", "", ".", "--delete"):
            with self.assertRaises(drive.SetupError):
                drive.Drive(self.home, name)

    def test_folder_only_created_after_mount_and_never_locally(self):
        process = Mock()
        process.poll.return_value = None
        def ismount(path):
            return self.app.child is not None
        with patch.object(drive.subprocess, "Popen", return_value=process) as popen, \
             patch.object(drive.os.path, "ismount", side_effect=ismount), \
             patch.object(self.app, "ensure_user_folder") as folder:
            self.assertTrue(self.app.mount())
            folder.assert_called_once()
            args = popen.call_args.args[0]
            self.assertNotIn("--allow-other", args)
            self.assertNotIn("--daemon", args)
            self.assertIn(str(self.app.cache), args)
        self.assertFalse((self.app.mountpoint / "brunnels").exists())

    def test_lost_mount_cannot_create_local_user_folder(self):
        self.app.mountpoint.mkdir()
        with self.assertRaises(drive.SetupError):
            self.app.ensure_user_folder()
        self.assertFalse((self.app.mountpoint / "brunnels").exists())

    def test_failed_mount_never_creates_user_folder(self):
        process = Mock()
        process.poll.return_value = 1
        with patch.object(drive.subprocess, "Popen", return_value=process), \
             patch.object(self.app, "ensure_user_folder") as folder:
            self.assertFalse(self.app.mount())
            folder.assert_not_called()

    def test_bookmark_is_idempotent_and_preserves_existing_places(self):
        path = self.home / ".local/share/user-places.xbel"
        drive.atomic_write(path, '<xbel><bookmark href="file:///existing"><title>Keep</title></bookmark></xbel>')
        drive.add_bookmark(self.home)
        drive.add_bookmark(self.home)
        bookmarks = ET.fromstring(path.read_bytes()).findall("bookmark")
        self.assertEqual(len(bookmarks), 2)
        self.assertEqual(bookmarks[0].get("href"), "file:///existing")
        self.assertEqual(bookmarks[1].get("href"), self.app.mountpoint.as_uri())

    @unittest.skipUnless(os.environ.get("TEST_REAL_RCLONE"), "real rclone integration enabled in CI")
    def test_real_rclone_oauth_configuration_with_local_provider(self):
        # Verify Ubuntu's actual rclone flags/state machine, callback, and
        # refresh-token persistence without Google or a graphical browser.
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        import threading
        import urllib.parse
        class Provider(BaseHTTPRequestHandler):
            def do_GET(self):
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                redirect = query["redirect_uri"][0]
                self.send_response(302)
                self.send_header("Location", redirect + "?" + urllib.parse.urlencode(
                    {"state": query["state"][0], "code": "test-code"}))
                self.end_headers()

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"access_token": "local-access", "refresh_token": "local-refresh",
                                            "token_type": "Bearer", "expires_in": 3600}).encode())

            def log_message(self, *_):
                pass

        provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        thread = threading.Thread(target=provider.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(provider.server_close)
        self.addCleanup(provider.shutdown)
        endpoint = f"http://127.0.0.1:{provider.server_port}"
        browser = self.home / "bin/xdg-open"
        drive.atomic_write(browser, '#!/usr/bin/python3\nimport sys, urllib.request\n'
                           'urllib.request.urlopen(sys.argv[1], timeout=20).read()\n', mode=0o700)
        original = drive.atomic_write
        def write(path, content, mode=0o600):
            if path.name == "rclone.conf":
                content += f"auth_url = {endpoint}/auth\ntoken_url = {endpoint}/token\n"
            original(path, content, mode)
        self.app.rclone = os.environ.get("RCLONE_TEST_BINARY", "/usr/bin/rclone")
        diagnostics = []
        execute = self.app.execute
        def capture(*args, **kwargs):
            result = execute(*args, **kwargs)
            diagnostics.append(result)
            return result
        with patch.object(drive, "atomic_write", side_effect=write), \
             patch.object(self.app, "execute", side_effect=capture), \
             patch.dict(os.environ, {"PATH": str(browser.parent) + ":" + os.environ["PATH"]}):
            self.assertTrue(self.app.authorize(CLIENT), diagnostics)
        config = self.app.parser()["solids"]
        self.assertEqual(config["team_drive"], drive.DRIVE_ID)
        self.assertEqual(json.loads(config["token"])["refresh_token"], "local-refresh")
        self.assertTrue(self.app.configured(CLIENT))

    @unittest.skipUnless(os.environ.get("TEST_REAL_RCLONE"), "real rclone integration enabled in CI")
    def test_real_rclone_mount_write_unmount_and_remount(self):
        self.app.rclone = os.environ.get("RCLONE_TEST_BINARY", "/usr/bin/rclone")
        storage = self.home / "remote"
        storage.mkdir()
        # Local backend exercises real FUSE/VFS and folder creation without Google.
        drive.atomic_write(self.app.config, f"[solids]\ntype = alias\nremote = {storage}\n")
        try:
            self.assertTrue(self.app.mount(), "rclone could not mount the temporary backend")
            self.assertTrue((storage / "brunnels").is_dir())
            (self.app.mountpoint / "brunnels/check.txt").write_text("persisted")
            import time
            deadline = time.monotonic() + 20
            while not (storage / "brunnels/check.txt").exists() and time.monotonic() < deadline:
                time.sleep(0.2)
            self.assertEqual((storage / "brunnels/check.txt").read_text(), "persisted")
        finally:
            self.app.stop_mount()
        self.assertFalse(os.path.ismount(self.app.mountpoint))
        self.assertEqual(self.app.mountpoint.stat().st_mode & 0o777, 0o500)
        try:
            self.assertTrue(self.app.mount())
            self.assertEqual((self.app.mountpoint / "brunnels/check.txt").read_text(), "persisted")
        finally:
            self.app.stop_mount()


if __name__ == "__main__":
    unittest.main()

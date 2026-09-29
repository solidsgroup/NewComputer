#!/usr/bin/env python3
"""Exercise the real shell UI and renderer in a PTY, never running installation."""
import fcntl
import importlib.util
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('display', ROOT / 'ui/installer-display.py')
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)


class DisplayTests(unittest.TestCase):
    def test_layout_and_escape_filtering(self):
        checklist = ['Title', 'Subtitle', 'Rule', 'Progress'] + [f'○ step {i}' for i in range(16)] + ['Status', 'Log']
        checklist[14] = '● Install and configure ISU VPN'
        for width, height in [(132, 30), (80, 24), (45, 12), (20, 5)]:
            frame = display.frame(checklist, ['live output\x1b[2J', '\x1b]0;bad title\x07safe'], width, height)
            self.assertLessEqual(len(frame.split('\r\n')), height - 1)
            self.assertIn('LIVE OUTPUT', frame)
            self.assertNotIn('bad title', frame)
            self.assertNotIn('\x1b[2J', frame)
            if width >= 45:
                self.assertIn('● Install and configure ISU VPN', frame)
        self.assertEqual(display.plain('\x1b[31mred\x1b[0m'), 'red')

    def test_toggle_layout_and_active_highlight(self):
        active = '  ●  Install and configure ISU VPN'
        checklist = ['Title', 'Subtitle', 'Rule', 'Progress', active, 'Status', 'Log']
        with patch.dict(os.environ, {'NO_COLOR': ''}):
            first = display.styled(active, 60, phase=0)
            second = display.styled(active, 60, phase=1)
            self.assertNotEqual(first, second)
            self.assertEqual(display.plain(first), display.plain(second))
            self.assertIn(';48;2;', second)
            for line in ['  ✓  Finished', '  ○  Pending', '  ×  Failed', '  ● Working']:
                self.assertEqual(display.styled(line, 60, phase=0),
                                 display.styled(line, 60, phase=1))
        with patch.dict(os.environ, {'NO_COLOR': '1'}):
            self.assertEqual(display.styled(active, 60, phase=0),
                             display.styled(active, 60, phase=1))
        for width in [80, 132]:
            hidden = display.frame(checklist, ['log-only marker'], width, 24, show_log=False)
            shown = display.frame(checklist, ['log-only marker'], width, 24, show_log=True)
            self.assertNotIn('log-only marker', hidden)
            self.assertIn('log-only marker', shown)
            self.assertIn('L: show log', hidden)
            self.assertIn('L: hide log', shown)

    def test_log_starts_at_current_run_and_includes_partial_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log'
            path.write_text('old run\n')
            tail = display.LogTail(path, path.stat().st_size)
            try:
                with path.open('a') as log:
                    log.write('new stderr\nprogress 50%'); log.flush()
                    self.assertEqual(tail.read(), ['new stderr', 'progress 50%'])
                    log.write('\rprogress 100%\n'); log.flush()
                    self.assertEqual(tail.read()[-1], 'progress 100%')
            finally:
                tail.file.close()

    def test_real_shell_renderer_success_failure_cancel_and_resize(self):
        source = (ROOT / 'new-computer-configure.sh').read_text()
        constants = source[source.index('readonly C0='):source.index('if [[ $EUID')]
        functions = source[source.index('UI_IS_TTY=false'):source.index('export DEBIAN_FRONTEND=')]
        for mode, expected, message in [('success', 0, 'Setup complete'), ('failure', 1, 'Setup stopped'), ('cancel', 130, 'Setup cancelled')]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                harness = path / 'harness.sh'
                # Only the extracted UI declarations and functions execute.
                harness.write_text('''#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR="$1"
LOG_FILE="$2/log"
VERSION_ID=26.04
FAILED_LINE=unknown
PROGRESS_PERCENT=0
UI_CURRENT_STEP=-1
UI_STATE=running
CANCELLED_SIGNAL=""
UI_DISPLAY_DIR=""
UI_DISPLAY_PID=""
UI_LOG_OFFSET=0
exec 3>&1
exec >"$LOG_FILE" 2>&1
''' + constants + functions + '''
show_progress 0 Starting
show_progress 5 "Refresh Ubuntu package metadata"
printf 'live stdout marker\\n'
printf 'live stderr marker\\n' >&2
printf 'renderer=%s\\n' "$UI_DISPLAY_PID" >"$2/child"
sleep 0.6
sleep 0.4
case "$3" in
 success) show_progress 100 "Configuration complete";;
 failure) false;;
 cancel) kill -INT "$$";;
esac
''')
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 132, 0, 0))
                saved_mode = termios.tcgetattr(slave)
                def terminal_session():
                    os.setsid()
                    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
                process = subprocess.Popen(['bash' , str(harness), str(ROOT), str(path), mode], stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal_session,
                                           env={**os.environ, 'TERM': 'xterm-256color', 'NO_COLOR': '1'})
                output = bytearray()
                deadline = time.monotonic() + 8
                resized = False
                toggle_step = 0
                try:
                    while time.monotonic() < deadline:
                        if select.select([master], [], [], 0.1)[0]:
                            try:
                                data = os.read(master, 65536)
                            except OSError:
                                break
                            if not data:
                                break
                            output.extend(data)
                            if b'live stderr marker' in output and not resized:
                                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
                                resized = True
                        if toggle_step == 0 and b'live stderr marker' in output:
                            os.write(master, b'l')
                            toggle_step = 1
                        elif toggle_step == 1 and b'L: show log' in output:
                            os.write(master, b'L')
                            toggle_step = 2
                        elif toggle_step == 2 and output.rfind(b'L: hide log') > output.rfind(b'L: show log'):
                            toggle_step = 3
                            if mode == 'cancel':
                                os.write(master, b'\x03')
                        if process.poll() is not None and not select.select([master], [], [], 0.1)[0]:
                            break
                    self.assertEqual(process.wait(timeout=2), expected)
                    text = output.decode(errors='replace')
                    self.assertIn('LIVE OUTPUT', text)
                    self.assertIn('live stdout marker', text)
                    self.assertIn('live stderr marker', text)
                    self.assertIn(message, text)
                    self.assertIn('\x1b[?25h', text)
                    self.assertTrue(resized)
                    self.assertEqual(toggle_step, 3)
                    self.assertEqual(termios.tcgetattr(slave), saved_mode)
                    child = int((path / 'child').read_text().split('=')[1])
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child, 0)
                finally:
                    if process.poll() is None:
                        process.kill(); process.wait()
                    os.close(master)
                    os.close(slave)


if __name__ == '__main__':
    unittest.main()

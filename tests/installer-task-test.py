#!/usr/bin/env python3
"""Run the actual phase runner/traps with harmless tasks, never system setup."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'new-computer-configure.sh').read_text()
CONSTANTS = SOURCE[SOURCE.index('readonly C0='):SOURCE.index('if [[ $EUID')]
FUNCTIONS = SOURCE[SOURCE.index('UI_IS_TTY=false'):SOURCE.index('export DEBIAN_FRONTEND=')]


class TaskTests(unittest.TestCase):
    def run_tasks(self, body):
        script = '''set -Eeuo pipefail
exec 3>&1
TERM=dumb
VERSION_ID=test
LOG_FILE=/dev/null
UI_CURRENT_STEP=-1
PROGRESS_PERCENT=0
UI_STATE=running
FAILED_LINE=unknown
CANCELLED_SIGNAL=''
UI_DISPLAY_PID=''
UI_DISPLAY_DIR=''
''' + CONSTANTS + FUNCTIONS + body
        return subprocess.run(['bash'], input=script, text=True, capture_output=True)

    def test_failure_isolated_and_later_tasks_attempted(self):
        for failure in ['false', 'false | cat', 'nested() { false; echo BAD; }; nested', 'exit 42']:
            with self.subTest(failure=failure):
                result = self.run_tasks('''
first() { echo FIRST; }
broken() { ''' + failure + '''; echo BAD; }
last() { echo LAST; }
run_step 5 "${UI_STEPS[0]}" first
run_step 12 "${UI_STEPS[1]}" broken
run_step 18 "${UI_STEPS[2]}" last
show_progress 100 "Configuration complete"
''')
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('LAST', result.stdout)
                self.assertNotIn('BAD', result.stdout)
                self.assertIn('✗ Upgrade installed Ubuntu packages (failed)', result.stdout)
                self.assertIn('✓ Check required Ubuntu repositories (succeeded)', result.stdout)
                self.assertNotIn('completed successfully', result.stdout)

    def test_final_checklist_keeps_failed_item_red(self):
        result = self.run_tasks('''
fail() { false; }
pass() { true; }
run_step 5 "${UI_STEPS[0]}" fail
run_step 12 "${UI_STEPS[1]}" pass
show_progress 100 "Configuration complete"
UI_IS_TTY=true
UI_USE_COLOR=true
render_checklist
UI_IS_TTY=false
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn('\x1b[38;2;220;70;70m✗', result.stdout)
        self.assertIn('1/17 complete', result.stdout)
        self.assertIn('Setup finished with 1 failed task(s)', result.stdout)

    def test_cancellation_stops_later_tasks(self):
        for signal, status in [('INT', 130), ('TERM', 143)]:
            result = self.run_tasks('''
cancel() { kill -''' + signal + ''' "$BASHPID"; echo BAD; }
run_step 5 "${UI_STEPS[0]}" cancel
echo BAD
''')
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertNotIn('BAD', result.stdout)
            self.assertIn('Configuration cancelled', result.stdout)

    def test_success_and_multiple_failures(self):
        for command, status, summary in [('true', 0, 'completed successfully'), ('false', 1, '2 failed task(s)')]:
            result = self.run_tasks('''
task() { ''' + command + '''; }
run_step 5 "${UI_STEPS[0]}" task
run_step 12 "${UI_STEPS[1]}" task
show_progress 100 "Configuration complete"
''')
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertIn(summary, result.stdout)


if __name__ == '__main__':
    unittest.main()

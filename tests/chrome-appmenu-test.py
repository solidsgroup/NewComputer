#!/usr/bin/python3
"""Test real GSettings persistence in an isolated home, schema, and D-Bus session."""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'kde/protect-chrome-appmenu'


class ChromeAppmenuTests(unittest.TestCase):
    def test_existing_choices_persist_and_repeated_runs_are_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'test.gschema.xml').write_text('''<schemalist>
<schema id="org.appmenu.gtk-module" path="/org/appmenu/gtk-module/">
<key name="blacklist" type="as"><default>['existing-default']</default></key>
</schema></schemalist>''')
            subprocess.run(['glib-compile-schemas', directory], check=True)
            env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
                       GSETTINGS_SCHEMA_DIR=directory, GSETTINGS_BACKEND='dconf')
            env.pop('DCONF_PROFILE', None)
            env.pop('DBUS_SESSION_BUS_ADDRESS', None)
            script = '''
import subprocess, sys
from gi.repository import Gio
s = Gio.Settings.new('org.appmenu.gtk-module')
subprocess.run(['/usr/bin/python3', sys.argv[1]], check=True)
Gio.Settings.sync()
# Check using a fresh process so the test also verifies on-disk persistence.
def read():
    return subprocess.check_output(['gsettings', 'get', 'org.appmenu.gtk-module', 'blacklist'], text=True)
assert 'existing-default' in read()
subprocess.run(['gsettings', 'set', 'org.appmenu.gtk-module', 'blacklist', "['my-app', 'chrome']"], check=True)
for _ in range(2):
    subprocess.run(['/usr/bin/python3', sys.argv[1]], check=True)
assert read().strip() == "['my-app', 'chrome', 'google-chrome', 'google-chrome-stable']", read()
'''
            result = subprocess.run(['dbus-run-session', '--', '/usr/bin/python3',
                                     '-c', script, str(HELPER)], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_existing_accounts_use_their_own_bus_or_a_private_bus(self):
        module = runpy.run_path(str(HELPER))
        users = [SimpleNamespace(pw_uid=1000, pw_name='alice', pw_dir='/home/alice', pw_shell='/bin/bash'),
                 SimpleNamespace(pw_uid=1001, pw_name='bob', pw_dir='/home/bob', pw_shell='/bin/bash'),
                 SimpleNamespace(pw_uid=1, pw_name='daemon', pw_dir='/', pw_shell='/bin/false')]
        with patch('os.geteuid', return_value=0), patch('pwd.getpwall', return_value=users), \
             patch.object(Path, 'read_text', return_value='UID_MIN 1000\nUID_MAX 60000'), \
             patch.object(Path, 'is_dir', return_value=True), \
             patch.object(Path, 'is_socket', side_effect=[True, False]), \
             patch('subprocess.run') as run:
            module['protect_all_users']()
        self.assertEqual(run.call_count, 2)
        alice, bob = [call.args[0] for call in run.call_args_list]
        self.assertIn('DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus', alice)
        self.assertNotIn('dbus-run-session', alice)
        self.assertIn('dbus-run-session', bob)
        self.assertIn('HOME=/home/bob', bob)

    def test_absent_module_is_a_noop(self):
        module = runpy.run_path(str(HELPER))
        with patch.object(module['Gio'].SettingsSchemaSource, 'get_default', return_value=None):
            module['protect_user']()


if __name__ == '__main__':
    unittest.main()

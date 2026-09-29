#!/usr/bin/env python3
"""Check profile migration and credential handling without an ISU account."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
path = Path(__file__).resolve().parents[1] / 'vpn/isu-vpn'
loader = importlib.machinery.SourceFileLoader('isu_vpn', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
vpn = importlib.util.module_from_spec(spec)
loader.exec_module(vpn)


class VPNTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.exists = False
        self.service = vpn.SERVICE

    def fake_run(self, *args, **kwargs):
        self.calls.append(args)
        output = ''
        if args[:4] == ('nmcli', '-t', '-f', 'UUID,NAME'):
            output = 'other:Ethernet\n' + ('kept-uuid:ISU\n' if self.exists else '')
        elif args[:3] == ('nmcli', '-g', 'vpn.service-type'):
            output = self.service
        elif args[:3] == ('nmcli', 'connection', 'add'):
            self.exists = True
        return subprocess.CompletedProcess(args, 0, stdout=output)

    def test_create_then_update_preserves_identity_and_does_not_connect(self):
        with patch.object(vpn, 'run', side_effect=self.fake_run):
            vpn.configure()
            vpn.configure()
        adds = [c for c in self.calls if c[1:3] == ('connection', 'add')]
        mods = [c for c in self.calls if c[1:3] == ('connection', 'modify')]
        self.assertEqual(len(adds), 1)
        self.assertEqual(len(mods), 1)
        self.assertEqual(mods[0][3:5], ('uuid', 'kept-uuid'))
        for cmd in adds + mods:
            self.assertIn('useragent=AnyConnect', cmd[cmd.index('vpn.data') + 1])
            for key, value in [('connection.autoconnect', 'no'),
                               ('ipv4.never-default', 'yes'), ('ipv6.never-default', 'yes'),
                               ('vpn.secrets', '')]:
                self.assertEqual(cmd[cmd.index(key) + 1], value)
        self.assertFalse(any('up' in c or 'delete' in c for c in self.calls))

    def test_refuse_unrelated_profile_and_duplicate_name(self):
        self.exists = True
        self.service = 'org.freedesktop.NetworkManager.openvpn'
        with patch.object(vpn, 'run', side_effect=self.fake_run):
            with self.assertRaises(ValueError):
                vpn.configure()
        with patch.object(vpn, 'run', return_value=subprocess.CompletedProcess(
                [], 0, stdout='one:ISU\ntwo:ISU\n')):
            with self.assertRaises(ValueError):
                vpn.configure()
        self.assertFalse(any('modify' in c for c in self.calls))

    def test_reject_bad_auth_output(self):
        for output in ['', "COOKIE='unterminated", 'COOKIE=a\nCOOKIE=b',
                       'COOKIE=a; touch /tmp/should-not-exist',
                       'COOKIE=a\nCONNECT_URL=http://bad\nFINGERPRINT=x',
                       "COOKIE='a\nb'\nCONNECT_URL=https://host\nFINGERPRINT=x"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                vpn.parse_auth(output)

    def test_token_passed_in_memory_not_arguments(self):
        calls = []
        secret_fd = None
        def run(*args, **kwargs):
            nonlocal secret_fd
            calls.append(args)
            if args[0] == 'openconnect':
                self.assertIn('--authgroup=Primary', args)
                self.assertIn('--external-browser=/usr/bin/xdg-open', args)
                return subprocess.CompletedProcess(args, 0, stdout=(
                    "COOKIE='test-sensitive-token'\nCONNECT_URL='https://vpn.iastate.edu'\n"
                    "FINGERPRINT='sha256:abc'\nRESOLVE='vpn.iastate.edu:192.0.2.1'\n"))
            secret_fd = kwargs['pass_fds'][0]
            self.assertEqual(args[-1], f'/proc/self/fd/{secret_fd}')
            data = os.read(secret_fd, 8192).decode()
            self.assertIn('vpn.secrets.cookie:test-sensitive-token\n', data)
            self.assertIn('vpn.secrets.resolve:vpn.iastate.edu:192.0.2.1\n', data)
            return subprocess.CompletedProcess(args, 0)
        with patch.object(vpn.os, 'geteuid', return_value=1000), \
                patch.object(vpn, 'profile_uuid', return_value='kept-uuid'), \
                patch.object(vpn, 'run', side_effect=run):
            vpn.connect()
        self.assertNotIn('test-sensitive-token', repr(calls))
        with self.assertRaises(OSError):
            os.fstat(secret_fd)

    def test_auth_failure_never_activates(self):
        with patch.object(vpn.os, 'geteuid', return_value=1000), \
                patch.object(vpn, 'profile_uuid', return_value='kept-uuid'), \
                patch.object(vpn, 'run', side_effect=subprocess.CalledProcessError(1, ['openconnect'])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                vpn.connect()
            self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()

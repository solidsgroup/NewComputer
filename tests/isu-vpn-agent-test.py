#!/usr/bin/env python3
"""Test isolation, cancellation, and token handling in the KDE login agent."""
import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('isu_agent', str(
    Path(__file__).resolve().parents[1] / 'vpn/isu-vpn-agent'))
spec = importlib.util.spec_from_loader(loader.name, loader)
agent = importlib.util.module_from_spec(spec)
loader.exec_module(agent)


class AgentTests(unittest.TestCase):
    def test_only_handles_isu_openconnect_gateway(self):
        profile = {'connection': {'id': 'ISU'}, 'vpn': {
            'service-type': agent.vpn['SERVICE'], 'data': {'gateway': 'vpn.iastate.edu'}}}
        self.assertTrue(agent.handles(profile))
        self.assertFalse(agent.handles(profile, '802-11-wireless-security'))
        self.assertFalse(agent.handles({}))
        profile['vpn']['data']['gateway'] = 'other.example.org'
        self.assertFalse(agent.handles(profile))
        profile['vpn']['data']['gateway'] = 'vpn.iastate.edu'
        profile['connection']['id'] = 'Other VPN'
        self.assertFalse(agent.handles(profile))
        profile['connection']['id'] = 'ISU'
        profile['vpn']['service-type'] = 'org.freedesktop.NetworkManager.openvpn'
        self.assertFalse(agent.handles(profile))

    def login(self, process):
        with patch.object(agent.subprocess, 'Popen', return_value=process) as spawn:
            login = agent.Login()
            self.assertEqual(spawn.call_args.args[0], agent.vpn['AUTH_COMMAND'])
            self.assertEqual(spawn.call_args.kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(spawn.call_args.kwargs['stderr'], subprocess.DEVNULL)
            return login

    def test_success_returns_tokens_without_notification_before_tunnel(self):
        process = Mock(returncode=0)
        process.poll.return_value = 0
        process.communicate.return_value = (
            "COOKIE='test-token'\nCONNECT_URL='https://vpn.iastate.edu'\n"
            "FINGERPRINT='sha256:abc'\nRESOLVE='vpn.iastate.edu:192.0.2.1'\n", None)
        with patch.object(agent, 'notify') as notify:
            secrets = self.login(process).poll()
            self.assertEqual(secrets['cookie'], 'test-token')
            self.assertEqual(secrets['resolve'], 'vpn.iastate.edu:192.0.2.1')
            notify.assert_not_called()

    def test_pending_and_cancel_reaps_process(self):
        process = Mock()
        process.poll.return_value = None
        login = self.login(process)
        self.assertIsNone(login.poll())
        login.cancel()
        process.kill.assert_called_once()
        process.communicate.assert_called_once()

    def test_timeout_reaps_process(self):
        process = Mock()
        process.poll.return_value = None
        login = self.login(process)
        with patch.object(agent.time, 'monotonic', return_value=login.started + 181):
            with self.assertRaisesRegex(ValueError, 'timed out'):
                login.poll()
        process.kill.assert_called_once()
        process.communicate.assert_called_once()

    def test_failure_never_returns_partial_tokens(self):
        process = Mock(returncode=1)
        process.poll.return_value = 1
        process.communicate.return_value = ("COOKIE='partial-token'", None)
        with self.assertRaises(ValueError):
            self.login(process).poll()

    def test_notification_failure_is_nonfatal(self):
        with patch.object(agent.subprocess, 'run', side_effect=FileNotFoundError):
            agent.notify('Connected')


if __name__ == '__main__':
    unittest.main()

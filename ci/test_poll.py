import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('poll', Path(__file__).with_name('poll-upstream.py'))
poll = importlib.util.module_from_spec(spec)
spec.loader.exec_module(poll)
SHA = 'a' * 40

class PollTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_state = poll.STATE
        poll.STATE = Path(self.tmp.name) / 'state.json'
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(setattr, poll, 'STATE', self.old_state)

    def run_poll(self, responses, sha=SHA):
        with patch.object(poll, 'wp_request', side_effect=responses) as api, \
             patch.object(poll.subprocess, 'check_output', return_value=sha+'\trefs/heads/master\n'), \
             patch.object(poll.sys, 'argv', ['poll']), contextlib.redirect_stdout(io.StringIO()):
            poll.main()
        return api

    def test_new_revision_is_pinned(self):
        api = self.run_poll([{'full_name':'StreamVersus/linux-tkg'}, [], {'number':7}])
        self.assertEqual(api.call_args.args[2]['variables'], {'TKG_UPSTREAM_COMMIT':SHA})
        self.assertEqual(json.loads(poll.STATE.read_text())['pipeline'], 7)

    def test_unchanged_revision_is_not_queued(self):
        poll.STATE.write_text(json.dumps({'last_dispatched_sha':SHA}))
        api = self.run_poll([{'full_name':'StreamVersus/linux-tkg'}])
        self.assertEqual(api.call_count, 1)

    def test_duplicate_creation_is_avoided(self):
        api = self.run_poll([{'full_name':'StreamVersus/linux-tkg'},
            [{'number':8,'message':'MANUAL: upstream linux-tkg '+SHA+' @ master'}]])
        self.assertEqual(api.call_count, 2)
        self.assertEqual(json.loads(poll.STATE.read_text())['pipeline'], 8)

    def test_failed_dispatch_does_not_advance_state(self):
        with self.assertRaises(RuntimeError):
            self.run_poll([{'full_name':'StreamVersus/linux-tkg'}, [], RuntimeError('API unavailable')])
        self.assertFalse(poll.STATE.exists())

    def test_invalid_sha_rejected(self):
        with self.assertRaises(RuntimeError):
            self.run_poll([{'full_name':'StreamVersus/linux-tkg'}], sha='not-a-sha')
        self.assertFalse(poll.STATE.exists())

    def test_wrong_repository_rejected(self):
        with self.assertRaises(RuntimeError):
            self.run_poll([{'full_name':'someone/else'}])
        self.assertFalse(poll.STATE.exists())

if __name__ == '__main__':
    unittest.main()

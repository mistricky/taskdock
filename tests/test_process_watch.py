import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/process_watch.py'
spec = importlib.util.spec_from_file_location('process_watch', SCRIPT)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


class ProcessWatchTests(unittest.TestCase):
    def setUp(self):
        self.children = []
        self.watcher = watch.Watcher()

    def tearDown(self):
        self.watcher.close()
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)

    def child(self):
        child = subprocess.Popen(['sleep', '60'])
        self.children.append(child)
        return child

    def sync(self, *windows):
        self.watcher.sync({'generation': 1, 'windows': list(windows)})

    def drain_exit(self):
        events = self.watcher.selector.select(timeout=3)
        self.assertTrue(events, 'missing kernel exit event')
        for event, _ in events:
            self.watcher.drop(event.data)

    def test_window_closes_but_process_lives_then_exits(self):
        child = self.child()
        self.sync({'id': 'w1', 'pid': child.pid})
        self.sync()
        self.assertIn('w1', self.watcher.windows)
        child.terminate()
        # Deliberately do not reap first: pidfd must notify even for zombies.
        self.drain_exit()
        self.assertEqual(self.watcher.windows, {})

    def test_shared_process_is_watched_once(self):
        child = self.child()
        self.sync({'id': 'w1', 'pid': child.pid}, {'id': 'w2', 'pid': child.pid})
        self.assertEqual(len(self.watcher.watches), 1)
        child.terminate()
        self.drain_exit()
        self.assertFalse(self.watcher.windows)

    def test_independent_instances_exit_independently(self):
        first, second = self.child(), self.child()
        self.sync({'id': 'w1', 'pid': first.pid}, {'id': 'w2', 'pid': second.pid})
        first.terminate()
        self.drain_exit()
        self.assertEqual(set(self.watcher.windows), {'w2'})

    def test_dead_pid_never_registers(self):
        child = self.child()
        child.terminate()
        child.wait()
        self.sync({'id': 'gone', 'pid': child.pid}, {'id': 'unknown', 'pid': 0})
        self.assertFalse(self.watcher.windows)

    def test_pid_reuse_during_registration_is_rejected(self):
        child = self.child()
        original = watch.process_info(child.pid)
        changed = dict(original, start=original['start'] + 1)
        with patch.object(watch, 'main_process', return_value=original), \
                patch.object(watch, 'process_info', side_effect=[original, changed]):
            self.sync({'id': 'race', 'pid': child.pid})
        self.assertFalse(self.watcher.windows)
        self.assertFalse(self.watcher.watches)

    def test_reused_window_id_replaces_owner(self):
        first, second = self.child(), self.child()
        self.sync({'id': 'reused', 'pid': first.pid})
        self.sync({'id': 'reused', 'pid': second.pid})
        self.assertEqual(len(self.watcher.watches), 1)
        self.assertEqual(self.watcher.windows['reused'][0][0], second.pid)

    def test_unknown_pid_clears_old_association(self):
        child = self.child()
        self.sync({'id': 'w', 'pid': child.pid})
        self.sync({'id': 'w', 'pid': 0})
        self.assertFalse(self.watcher.windows)
        self.assertFalse(self.watcher.watches)

    def test_main_process_boundaries(self):
        root = dict(pid=10, ppid=1, start=1, state='S', uid=1000,
                    exe=(1, 1), name='chrome')
        child = dict(root, pid=20, ppid=10)
        self.assertEqual(watch.main_process(child, lambda _: root)['pid'], 10)
        for parent in (dict(root, exe=(1, 2)), dict(root, uid=0), dict(root, state='Z')):
            self.assertEqual(watch.main_process(child, lambda _: parent)['pid'], 20)
        for runtime in ('python3.14', 'node', 'electron', 'java', 'bash'):
            self.assertEqual(watch.main_process(dict(child, name=runtime),
                                               lambda _: root)['pid'], 20)

    def test_stream_protocol_exit_and_eof(self):
        child = self.child()
        helper = subprocess.Popen([sys.executable, '-u', str(SCRIPT)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0)
        def receive():
            self.assertTrue(select.select([helper.stdout], [], [], 3)[0])
            return json.loads(helper.stdout.readline())
        try:
            self.assertEqual(receive(), {'ready': True})
            message = json.dumps({'generation': 7, 'windows': [{'id': 'w', 'pid': child.pid}]})
            # One JSON record split across writes must still be one command.
            helper.stdin.write(message[:10].encode())
            helper.stdin.write((message[10:] + '\n').encode())
            self.assertEqual(receive(), {'generation': 7, 'alive': ['w']})
            child.terminate()
            self.assertEqual(receive(), {'generation': 7, 'alive': []})
            helper.stdin.close()
            self.assertEqual(helper.wait(timeout=3), 0)
        finally:
            if helper.poll() is None:
                helper.kill()
            helper.wait(timeout=3)
            for stream in (helper.stdin, helper.stdout, helper.stderr):
                stream.close()


if __name__ == '__main__':
    unittest.main()

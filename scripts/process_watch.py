#!/usr/bin/env python3
"""TaskDock JSON-lines protocol: window snapshots in, pidfd liveness events out.

No process-name searches, timers, third-party modules or privileged interfaces.
Removed windows keep their association until their observed process exits.
"""
import json
import os
from pathlib import Path
import selectors
import sys


def process_info(pid):
    base = Path('/proc') / str(pid)
    # comm may contain spaces and closing parentheses. Fields after the LAST
    # ')' start at field 3; starttime is field 22.
    fields = (base / 'stat').read_text().rsplit(')', 1)[1].split()
    exe = (base / 'exe').stat()
    return {
        'pid': pid, 'ppid': int(fields[1]), 'start': int(fields[19]),
        'state': fields[0], 'uid': base.stat().st_uid,
        'exe': (exe.st_dev, exe.st_ino),
        'name': (base / 'exe').readlink().name,
    }


def identity(info):
    return info['pid'], info['start']


def main_process(info, read=process_info):
    """Only climb demonstrably same-executable ancestors, never generic hosts.

    This deliberately does not guess across different helper executables or
    shared runtimes (two unrelated apps can both execute node/electron/java).
    """
    generic = ('python', 'node', 'electron', 'java', 'ruby', 'perl', 'bash',
               'zsh', 'dash', 'sh', 'fish', 'env', 'flatpak', 'bwrap')
    if any(info['name'] == n or info['name'].startswith(n + '.')
           or (n in ('python', 'electron') and info['name'].startswith(n))
           for n in generic):
        return info
    visited = {info['pid']}
    for _ in range(64):
        if info['ppid'] <= 1 or info['ppid'] in visited:
            break
        try:
            parent = read(info['ppid'])
        except (OSError, ValueError, IndexError):
            break
        if (parent['uid'] != info['uid'] or parent['exe'] != info['exe']
                or parent['state'] in ('Z', 'X')):
            break
        visited.add(parent['pid'])
        info = parent
    return info


class Watcher:
    def __init__(self):
        self.selector = selectors.DefaultSelector()
        self.watches = {}  # (pid, starttime) -> pidfd
        self.windows = {}  # window id -> (original identity, watched identity)
        self.generation = 0

    def track(self, window):
        wid, pid = str(window['id']), int(window['pid'])
        if not wid or pid <= 0:
            self.windows.pop(wid, None)
            return
        try:
            original = process_info(pid)
            if original['state'] in ('Z', 'X'):
                return
            old = self.windows.get(wid)
            if old and old[0] == identity(original) and old[1] in self.watches:
                return
            # A reused compositor address must not retain the previous owner.
            self.windows.pop(wid, None)
            main = main_process(original)
            key = identity(main)
            fd = os.pidfd_open(main['pid'])
            try:
                # Close both process-discovery and pidfd_open reuse races.
                if (identity(process_info(main['pid'])) != key
                        or identity(process_info(pid)) != identity(original)):
                    return
                if key not in self.watches:
                    self.selector.register(fd, selectors.EVENT_READ, key)
                    self.watches[key] = fd
                    fd = None
                self.windows[wid] = (identity(original), key)
            finally:
                if fd is not None:
                    os.close(fd)
        except (OSError, ValueError, IndexError):
            # Unknown is not proof of liveness. Real windows remain visible in
            # QML; only successfully registered identities can be background.
            self.windows.pop(wid, None)
            return

    def sync(self, message):
        self.generation = int(message['generation'])
        for window in message['windows']:
            self.track(window)
        self.collect_unused()

    def collect_unused(self):
        used = {value[1] for value in self.windows.values()}
        for key in list(self.watches):
            if key not in used:
                self.drop(key)

    def drop(self, key):
        fd = self.watches.pop(key, None)
        if fd is not None:
            self.selector.unregister(fd)
            os.close(fd)
        self.windows = {wid: value for wid, value in self.windows.items()
                        if value[1] != key}

    def emit(self):
        print(json.dumps({'generation': self.generation,
                          'alive': list(self.windows)}), flush=True)

    def close(self):
        for key in list(self.watches):
            self.drop(key)
        self.selector.close()

    def run(self):
        self.selector.register(sys.stdin.fileno(), selectors.EVENT_READ, None)
        buffer = b''
        print('{"ready":true}', flush=True)
        while True:
            # No timeout: stdin commands and kernel process-exit notifications
            # are the only wakeups. EOF stops the helper with its QML owner.
            events = self.selector.select()
            changed = False
            for event, _ in events:
                if event.data is not None:
                    self.drop(event.data)
                    changed = True
                    continue
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    return
                buffer += data
                if len(buffer) > 4 * 1024 * 1024:
                    raise ValueError('oversized input')
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    self.sync(json.loads(line))
                    changed = True
            if changed:
                self.emit()


if __name__ == '__main__':
    watcher = Watcher()
    try:
        watcher.run()
    finally:
        watcher.close()

#!/usr/bin/env python3
"""Render the installer's checklist snapshot beside a live, bounded log tail."""
import argparse
from collections import deque
import os
from pathlib import Path
import re
import shutil
import select
import termios
import signal
import time
import unicodedata

ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')


def plain(text):
    return ''.join(c for c in ANSI.sub('', text) if c == '\t' or not unicodedata.category(c).startswith('C')).expandtabs(4)


def clip(text, width):
    result = ''
    used = 0
    for char in plain(text):
        size = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in 'WF' else 1)
        if used + size > width:
            break
        result += char
        used += size
    return result + ' ' * max(0, width - used)


def shimmer(text, phase):
    match = re.match(r'^(\s*●  )(.+)$', plain(text))
    if not match:
        return text
    prefix, label = match.groups()
    center = (phase * 16) % (len(label) + 18) - 9
    result = '\x1b[38;2;255;127;14m' + prefix + '\x1b[0m\x1b[1m'
    for index, char in enumerate(label):
        strength = max(0, 1 - abs(index - center) / 5)
        if strength:
            shade = int(35 + 40 * strength)
            result += f'\x1b[38;2;255;235;204;48;2;{shade};{int(shade * .7)};{int(shade * .4)}m{char}\x1b[0m\x1b[1m'
        else:
            result += char
    return result + '\x1b[0m'


def styled(text, width, phase=None):
    """Clip checklist text while retaining its original per-element SGR colors."""
    if os.environ.get('NO_COLOR'):
        return clip(text, width)
    if phase is not None:
        text = shimmer(text, phase)
    result = ''
    used = 0
    for part in re.split(r'(\x1b\[[0-9;]*m)', text):
        if re.fullmatch(r'\x1b\[[0-9;]*m', part):
            result += part
            continue
        for char in plain(part):
            size = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in 'WF' else 1)
            if used + size > width:
                return result + '\x1b[0m' + ' ' * (width - used)
            result += char
            used += size
    return result + '\x1b[0m' + ' ' * max(0, width - used)


def muted(text, width):
    line = clip(text, width)
    if os.environ.get('NO_COLOR'):
        return line
    return '\x1b[38;2;145;151;160m' + line + '\x1b[0m'


def checklist_view(lines, height):
    if len(lines) <= height:
        return lines + [''] * (height - len(lines))
    # Keep the active phase visible while retaining summary and result lines.
    if height < 7:
        active = next((line for line in lines if '●' in line or '×' in line or '■' in line), '')
        return ([lines[0], active] + lines[-2:])[:height]
    head, foot = lines[:4], lines[-2:]
    body = lines[4:-2]
    count = height - len(head) - len(foot)
    current = next((i for i, line in enumerate(body) if any(c in line for c in '●×■')), len(body) - 1)
    start = min(max(0, current - count // 2), max(0, len(body) - count))
    return head + body[start:start + count] + foot


def frame(checklist, logs, columns, rows, show_log=True, phase=None, keyboard=True):
    # Leave the last column and row unused to avoid terminal autowrap/scroll.
    width, height = max(1, columns - 1), max(1, rows - 1)
    footer = keyboard and height > 3
    if footer:
        height -= 1
    if not show_log:
        lines = [styled(x, width, phase) for x in checklist_view(checklist, height)]
    elif width >= 110:
        left = min(66, width // 2)
        right = width - left - 3
        a = checklist_view(checklist, height - 1)
        b = list(logs)[-(height - 1):]
        b += [''] * (height - 1 - len(b))
        lines = [styled('\x1b[1;38;2;31;119;180m INSTALLATION CHECKLIST', left) + muted(' │ ', 3) + muted('LIVE OUTPUT', right)]
        lines += [styled(x, left, phase) + muted(' │ ', 3) + muted(y, right) for x, y in zip(a, b)]
    else:
        log_height = max(1, height // 3)
        checklist_height = max(0, height - log_height - 1)
        lines = [styled(x, width, phase) for x in checklist_view(checklist, checklist_height)]
        lines += [muted('─ LIVE OUTPUT ' + '─' * width, width)]
        lines += [muted(x, width) for x in list(logs)[-log_height:]]
    lines = (lines + [''] * height)[:height]
    if footer:
        lines.append(muted(' L: ' + ('hide log' if show_log else 'show log') + '  ·  Ctrl+C: cancel', width))
    return '\x1b[H' + '\r\n'.join(line + '\x1b[K' for line in lines) + '\x1b[J'


class LogTail:
    def __init__(self, path, offset):
        self.file = open(path, encoding='utf-8', errors='replace')
        self.file.seek(offset)
        self.lines = deque(maxlen=300)
        self.partial = ''

    def read(self):
        # Bound each frame's work when a package generates a large output burst.
        end = os.fstat(self.file.fileno()).st_size
        if end - self.file.tell() > 65536:
            self.file.seek(end - 65536)
            self.file.readline()  # Discard a partial line after skipping a burst.
            self.partial = ''
        data = self.file.read(65536)
        if data:
            parts = (self.partial + data).replace('\r\n', '\n').replace('\r', '\n').split('\n')
            self.lines.extend(plain(line) for line in parts[:-1])
            self.partial = parts[-1][-4096:]
        return list(self.lines) + ([plain(self.partial)] if self.partial else [])


class Keyboard:
    """Read shortcuts from the controlling terminal, including curl | sudo bash."""
    def __init__(self):
        self.fd = None
        self.saved = None
        try:
            self.fd = os.open('/dev/tty', os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
            self.saved = termios.tcgetattr(self.fd)
            mode = termios.tcgetattr(self.fd)
            mode[3] &= ~(termios.ICANON | termios.ECHO)
            # Preserve ISIG so Ctrl+C still cancels the foreground installer.
            mode[6][termios.VMIN] = 0
            mode[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, mode)
        except (OSError, termios.error):
            self.close()

    def toggled(self):
        if self.fd is None or not select.select([self.fd], [], [], 0)[0]:
            return False
        try:
            return sum(c in b'lL' for c in os.read(self.fd, 1024)) % 2 == 1
        except (OSError, BlockingIOError):
            return False

    def close(self):
        if self.fd is not None:
            try:
                if self.saved is not None:
                    termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
            finally:
                os.close(self.fd)
                self.fd = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--log', required=True)
    parser.add_argument('--offset', type=int, default=0)
    parser.add_argument('--parent', type=int, required=True)
    args = parser.parse_args()
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    tail = LogTail(args.log, args.offset)
    previous = None
    keyboard = Keyboard()
    show_log = True
    print('\x1b[?25l\x1b[2J', end='', flush=True)
    try:
        while True:
            try:
                checklist = args.state.read_text().splitlines()
            except FileNotFoundError:
                checklist = ['Starting installer…']
            size = shutil.get_terminal_size((80, 24))
            if keyboard.toggled():
                show_log = not show_log
            output = frame(checklist, tail.read(), size.columns, size.lines,
                           show_log=show_log, phase=time.monotonic(), keyboard=keyboard.fd is not None)
            if output != previous:
                print(output, end='', flush=True)
                previous = output
            if stopping or os.getppid() != args.parent:
                break
            time.sleep(0.08)
    finally:
        keyboard.close()
        tail.file.close()
        print(f'\x1b[0m\x1b[?25h\x1b[{shutil.get_terminal_size((80, 24)).lines};1H', end='', flush=True)


if __name__ == '__main__':
    main()

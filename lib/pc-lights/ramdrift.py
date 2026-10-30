#!/usr/bin/env python3
# lib/pc-lights/ramdrift.py — the RAM drift: a theme's RAM gradient sliding
# slowly along the sticks (docs/THEMES.md "RAM drift", docs/BACKENDS.md).
#
# One module for both halves, so they can never disagree:
#   - the frame math: openrgb_py (backend-openrgb.sh) imports frame() and
#     check() and writes frame 0 as the static Direct colours of an apply;
#   - the animator: "pc-lights ram-drift run" (lumenaire-ram-drift.service),
#     started by the engine after an apply of a theme whose ram has "drift".
#     It owns a private OpenRGB server that detects only the ENE DRAM sticks
#     and writes frame 1, 2, ... to them through the OpenRGB SDK.
#
# CLI (the engine calls these; stdlib only):
#   ramdrift.py params <eff.json> "<ram ids>" <orgb.json> [<listing>]
#       the animator's parameters as JSON on stdout, or nothing when the
#       theme's ram doesn't drift
#   ramdrift.py describe <params.json>   one line for render
#   ramdrift.py run                      the animator (see run())
#
# Theme key: ram = {"gradient": [2-8 stops], "span": "across"|"stick",
#   "drift": {"period": 20-3600 s (120), "window": 0.1-1 (0.5),
#             "reverse": false, "fps": 1-10 (4)}}
# With drift the stops are a closed loop (the last blends back into the first);
# "window" is the share of that loop the span shows at once; the pattern moves
# toward higher LED indices (stick 0 into stick 1 with span "across"; reverse
# turns it round) and passes a whole loop once per period.
import errno
import fcntl
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time

DEFAULTS = {'period': 120, 'window': 0.5, 'reverse': False, 'fps': 4}
PORT = int(os.environ.get('PCL_RAM_DRIFT_PORT', '6797'))
UNIT = 'lumenaire-ram-drift.service'


# ---- the frame math -----------------------------------------------------------------
def _rgb(s):
    s = str(s).strip().lstrip('#')
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def check(r):
    """Problems with a ram value's drift, one string each (empty = fine)."""
    d = r.get('drift') if isinstance(r, dict) else None
    if d is None:
        return []
    errs = []
    if not isinstance(d, dict):
        return ['ram.drift must be an object {period, window, reverse, fps}']
    g = r.get('gradient')
    if not isinstance(g, list) or not 2 <= len(g) <= 8:
        errs.append('ram.drift needs a ram gradient of 2-8 colours')
    if r.get('span', 'across') not in ('across', 'stick'):
        errs.append('ram.span must be across or stick')
    for k in d:
        if not str(k).startswith('_') and k not in DEFAULTS:
            errs.append('ram.drift.%s is not a drift key (period, window, reverse, fps)' % k)

    def num(k, lo, hi, whole=False):
        v = d.get(k)
        if v is None:
            return
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi \
                or (whole and v != int(v)):
            errs.append('ram.drift.%s must be %s %s-%s' % (k, 'a whole number' if whole else 'a number', lo, hi))
    num('period', 20, 3600)
    num('window', 0.1, 1)
    num('fps', 1, 10, whole=True)
    if 'reverse' in d and not isinstance(d['reverse'], bool):
        errs.append('ram.drift.reverse must be true or false')
    return errs


def settings(r):
    """The drift's settings with the defaults filled in."""
    d = r.get('drift') or {}
    out = {k: d.get(k, v) for k, v in DEFAULTS.items()}
    out['fps'] = int(out['fps'])
    return out


def frame(stops, n, phase, window=0.5, reverse=False):
    """n colours (tuples of 0-255 ints) at phase (0..1 of the period).

    LED i sits at x = i / n of the span; its colour is the closed loop of
    stops at u = x * window - phase (+ phase with reverse), mod 1: as the
    phase grows, every colour moves toward higher indices."""
    cs = [_rgb(h) for h in stops]
    k = len(cs)
    out = []
    for i in range(n):
        u = (i / n * window + (phase if reverse else -phase)) % 1.0
        t = u * k
        j = min(int(t), k - 1)
        f = t - j
        a, b = cs[j], cs[(j + 1) % k]
        out.append(tuple(round(a[c] + (b[c] - a[c]) * f) for c in range(3)))
    return out


def stick_frames(stops, span, sticks, lpd, phase, window=0.5, reverse=False):
    """One list of lpd colours per stick."""
    if span == 'stick':
        return [frame(stops, lpd, phase, window, reverse)] * sticks
    cs = frame(stops, lpd * sticks, phase, window, reverse) if sticks else []
    return [cs[lpd * i:lpd * i + lpd] for i in range(sticks)]


# ---- params (the engine's side) -------------------------------------------------------
def listing_locations(path, ids):
    """{id: location} for the given listing indices, from an OpenRGB listing."""
    locs, cur = {}, None
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return {}
    for line in text.splitlines():
        m = re.match(r'^(\d+): ', line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r'^\s+Location:\s*(.*\S)', line)
        if m and cur in ids and cur not in locs:
            locs[cur] = m.group(1)
    return locs


def params(eff, ram_ids, orgb, listing=None):
    th = json.load(open(eff))
    r = th.get('ram')
    if not isinstance(r, dict) or 'drift' not in r:
        return None
    errs = check(r)
    if errs:
        raise ValueError('; '.join(errs))
    op = json.load(open(orgb)) if orgb else {}
    ram_p = op.get('ram') or {}
    ids = ram_ids.split()
    s = settings(r)
    locs = listing_locations(listing, ids) if listing else {}
    return {'v': 1, 'stops': [str(h).lstrip('#').lower() for h in r['gradient']],
            'span': r.get('span', 'across'), 'period': s['period'], 'window': s['window'],
            'reverse': s['reverse'], 'fps': s['fps'],
            'leds_per_device': int(ram_p.get('leds_per_device') or 8),
            'match_name': ram_p.get('match_name') or 'ENE DRAM',
            'count': len(ids), 'ids': ids,
            'locations': [locs[i] for i in ids] if ids and all(i in locs for i in ids) else []}


def describe(p):
    return ('# ram drift: %s over %d stick%s, period %g s, window %g, fps %d%s (%s animates from the frame above)'
            % (' '.join(p['stops']), p['count'], '' if p['count'] == 1 else 's', p['period'], p['window'],
               p['fps'], ', reversed' if p['reverse'] else '', UNIT))


# ---- the OpenRGB SDK client (just what the animator needs) ------------------------------
class SDKError(Exception):
    pass


class Client:
    MAGIC = b'ORGB'
    HDR = struct.Struct('<4sIII')

    def __init__(self, host='127.0.0.1', port=PORT, timeout=10.0, name='lumenaire ram-drift'):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.send(0, 40, struct.pack('<I', 4))
        server = struct.unpack('<I', self.recv(0, 40)[:4])[0]
        self.proto = min(server, 4)
        self.send(0, 50, name.encode() + b'\0')

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, dev, pid, data=b''):
        self.sock.sendall(self.HDR.pack(self.MAGIC, dev, pid, len(data)) + data)

    def _exact(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise SDKError('the OpenRGB server closed the connection')
            buf += chunk
        return buf

    def recv(self, dev, pid):
        # Unsolicited packets (DEVICE_LIST_UPDATED) are read and dropped.
        while True:
            magic, d, p, size = self.HDR.unpack(self._exact(self.HDR.size))
            if magic != self.MAGIC:
                raise SDKError('not an OpenRGB SDK reply')
            data = self._exact(size) if size else b''
            if p == pid and d == dev:
                return data

    def count(self):
        self.send(0, 0)
        return struct.unpack('<I', self.recv(0, 0)[:4])[0]

    def controller(self, idx):
        """{type, name, vendor, description, version, serial, location}."""
        self.send(idx, 1, struct.pack('<I', self.proto))
        data = self.recv(idx, 1)
        pos = 4 + 4
        ctype = struct.unpack_from('<i', data, 4)[0]

        def string():
            nonlocal pos
            n = struct.unpack_from('<H', data, pos)[0]
            s = data[pos + 2:pos + 2 + n].rstrip(b'\0').decode('utf-8', 'replace')
            pos += 2 + n
            return s
        out = {'type': ctype, 'name': string()}
        out['vendor'] = string() if self.proto >= 1 else ''
        for k in ('description', 'version', 'serial', 'location'):
            out[k] = string()
        return out

    def custom_mode(self, idx):
        self.send(idx, 1100)

    def update_leds(self, idx, colours):
        body = struct.pack('<H', len(colours)) + b''.join(struct.pack('<BBBx', *c) for c in colours)
        self.send(idx, 1050, struct.pack('<I', 4 + len(body)) + body)


def _address(loc):
    m = re.search(r'address 0x([0-9a-fA-F]+)', loc)
    return int(m.group(1), 16) if m else 1 << 16


def pick_sticks(ctrls, p):
    """The SDK indices of the sticks the engine drove, in the engine's order."""
    named = [(i, c) for i, c in enumerate(ctrls) if c['name'] == p['match_name']]
    if p.get('locations'):
        by_loc = {c['location'].strip(): i for i, c in named}
        if all(loc in by_loc for loc in p['locations']):
            return [by_loc[loc] for loc in p['locations']]
        return None
    if len(named) != p['count']:
        return None
    return [i for i, c in sorted(named, key=lambda ic: (_address(ic[1]['location']), ic[1]['location']))]


# ---- the animator ---------------------------------------------------------------------
def log(msg):
    print('pc-lights: ram-drift: ' + msg, file=sys.stderr, flush=True)
    if not os.environ.get('PCL_RAM_DRIFT_NO_LOGGER'):
        try:
            subprocess.run(['logger', '-t', 'pc-lights', '--', 'ram-drift: ' + msg], timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            pass


def private_config(user_json, out_dir, keep='ENE SMBus DRAM'):
    """The private OpenRGB config: the user's detector list, every detector
    off but <keep>. None if the user's list is missing (a detector missing
    from the list is ON, so without the full list we'd detect everything)."""
    try:
        dets = json.load(open(user_json))['Detectors']['detectors']
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not isinstance(dets, dict) or keep not in dets:
        return None
    os.makedirs(out_dir, exist_ok=True)
    cfg = {'Detectors': {'detectors': {k: (k == keep) for k in dets}}}
    tmp = os.path.join(out_dir, 'OpenRGB.json.tmp')
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=4)
    os.replace(tmp, os.path.join(out_dir, 'OpenRGB.json'))
    return out_dir


class Stop(Exception):
    pass


def run():
    home = os.environ['HOME']
    cache = os.environ.get('PCL_CACHE', os.path.join(home, '.cache/pc-lights'))
    state = os.environ.get('PCL_STATE_DIR', os.path.join(home, '.config/pc-lights'))
    pfile = os.path.join(cache, 'ram-drift.json')
    openrgb = os.environ.get('PCL_OPENRGB', 'openrgb')
    user_json = os.environ.get('PCL_OPENRGB_CONFIG', os.path.join(home, '.config/OpenRGB/OpenRGB.json'))
    wait_port = float(os.environ.get('PCL_RAM_DRIFT_WAIT', '90'))
    os.makedirs(cache, exist_ok=True)

    def lights():
        try:
            return open(os.path.join(state, 'lights')).read().strip() or 'on'
        except OSError:
            return 'on'

    # One OpenRGB on the SMBus at a time: the engine takes this lock (after
    # stopping this unit) around every OpenRGB call it makes.
    lk = open(os.path.join(cache, 'openrgb.lock'), 'a')
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            log('OpenRGB is busy (openrgb.lock is held by an apply); not starting')
            return 0
        raise
    try:
        p = json.load(open(pfile))
    except (OSError, ValueError):
        log('no %s (the active theme does not drift); nothing to do' % pfile)
        return 0
    if lights() == 'off':
        log('the lights are off; nothing to do')
        return 0
    if not p.get('count'):
        log('no RAM sticks were driven by the last apply; nothing to do')
        return 0

    stop = {'why': None}

    def on_term(signum, _frame):
        stop['why'] = signal.Signals(signum).name
        raise Stop()
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    child = client = None
    try:
        cdir = private_config(user_json, os.path.join(cache, 'ram-drift', 'openrgb'))
        if cdir is None:
            log('cannot build a DRAM-only OpenRGB config from %s (no detector list with "ENE SMBus DRAM"); '
                'not starting a second OpenRGB that would detect everything' % user_json)
            return 1
        errlog = open(os.path.join(cache, 'ram-drift', 'openrgb.log'), 'w')
        child = subprocess.Popen([openrgb, '--config', cdir, '--server', '--server-host', '127.0.0.1',
                                  '--server-port', str(PORT), '--noautoconnect'],
                                 stdin=subprocess.DEVNULL, stdout=errlog, stderr=errlog)
        t0 = time.monotonic()
        while True:
            if child.poll() is not None:
                log('OpenRGB exited (%s) before its server came up; see %s' % (child.returncode, errlog.name))
                return 1
            try:
                client = Client(port=PORT)
                break
            except OSError:
                if time.monotonic() - t0 > wait_port:
                    log('OpenRGB server did not come up within %g s' % wait_port)
                    return 1
                time.sleep(0.5)
        # Devices appear as they are detected: wait for the sticks.
        sticks = None
        while sticks is None:
            ctrls = [client.controller(i) for i in range(client.count())]
            sticks = pick_sticks(ctrls, p)
            if sticks is None:
                if time.monotonic() - t0 > wait_port:
                    log('found %d controller(s) %s, not the %d "%s" stick(s) the apply drove%s; giving up'
                        % (len(ctrls), [c['name'] for c in ctrls], p['count'], p['match_name'],
                           ' at %s' % p['locations'] if p.get('locations') else ''))
                    return 1
                time.sleep(1.0)
        for i in sticks:
            client.custom_mode(i)
        lpd, fps = int(p['leds_per_device']), int(p['fps'])
        log('driving %d stick(s) (SDK %s), period %g s, window %g, fps %d'
            % (len(sticks), sticks, p['period'], p['window'], fps))
        start = time.monotonic()
        last = [None] * len(sticks)
        n = writes = 0
        next_check = start
        while True:
            now = time.monotonic()
            if now >= next_check:
                if child.poll() is not None:
                    log('OpenRGB exited (%s); stopping' % child.returncode)
                    return 1
                if lights() == 'off':
                    log('the lights went off; stopping')
                    return 0
                next_check = now + 3
            # Phase from the frame number on the start's grid: frame 0 is
            # exactly the static apply's colours.
            phase = (n / (fps * p['period'])) % 1.0
            for k, cs in enumerate(stick_frames(p['stops'], p['span'], len(sticks), lpd, phase,
                                                p['window'], p['reverse'])):
                if cs != last[k]:
                    client.update_leds(sticks[k], cs)
                    last[k] = cs
                    writes += 1
            n += 1
            # Sleep to the next frame on the start's grid (no drift, no catch-up burst).
            time.sleep(max(0.0, start + n / fps - time.monotonic()))
    except Stop:
        log('stopped (%s)' % stop['why'])
        return 0
    except (OSError, SDKError, struct.error) as e:
        log('OpenRGB SDK: %s' % e)
        return 1
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if client:
            client.close()
        if child and child.poll() is None:
            child.terminate()
            try:
                child.wait(10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def main(argv):
    if len(argv) >= 3 and argv[1] == 'params':
        try:
            p = params(argv[2], argv[3] if len(argv) > 3 else '', argv[4] if len(argv) > 4 else '',
                       argv[5] if len(argv) > 5 else None)
        except ValueError as e:
            print('pc-lights: %s' % e, file=sys.stderr)
            return 1
        if p is not None:
            print(json.dumps(p))
        return 0
    if len(argv) == 3 and argv[1] == 'describe':
        print(describe(json.load(open(argv[2]))))
        return 0
    if len(argv) == 2 and argv[1] == 'run':
        return run()
    print('usage: ramdrift.py params <eff> "<ram ids>" <orgb.json> [listing] | describe <params> | run',
          file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
# check.py — the RAM drift's python half: the frame math, params, and the
# animator against fake_openrgb.py (a fake SDK server; no hardware, no real
# OpenRGB). Called by run.sh; prints "ok"/"FAIL" lines and a total.
#   check.py <lib dir> [--real-openrgb]
# --real-openrgb also starts the real openrgb with --nodetect (no hardware
# detection at all) on a scratch config and port, checks the SDK handshake and
# measures the idle server's CPU.
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time

LIB = sys.argv[1]
sys.path.insert(0, LIB)
import ramdrift  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
passed = failed = 0


def ok(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print('ok   ' + msg)
    else:
        failed += 1
        print('FAIL ' + msg)


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


STOPS = ['ff6a2a', 'ff1a70', '9020d8', 'ff4a9a']

# ---- frame math -----------------------------------------------------------------------
f0 = ramdrift.frame(STOPS, 16, 0.0, 0.5)
ok(f0[0] == (0xff, 0x6a, 0x2a), 'frame 0 starts on the first stop')
ok(f0[8] == (0xff, 0x1a, 0x70), 'window 0.5 over 4 stops: LED 8 of 16 (a quarter of the loop) is the second stop')
ok(ramdrift.frame(STOPS, 16, 1.0, 0.5) == f0, 'periodic: phase 1 == phase 0')
ok(ramdrift.frame(STOPS, 16, 0.25, 0.5) != f0, 'it moves')
# the pattern moves toward higher indices: LED i at phase p shows what LED
# i - n*window*... ; simplest: the colour at LED 4 after 1/32 of a loop (one
# LED's worth with window 0.5 over 16 LEDs) is the colour LED 3 had.
ok(ramdrift.frame(STOPS, 16, 1 / 32, 0.5)[4] == f0[3], 'forward: colours move from LED i to LED i+1')
ok(ramdrift.frame(STOPS, 16, 1 / 32, 0.5, reverse=True)[3] == f0[4], 'reverse: from LED i+1 to LED i')
# smoothness at the defaults (period 120, fps 4): per frame, per channel
steps = [ramdrift.frame(STOPS, 16, k / (120 * 4), 0.5) for k in range(120 * 4 + 1)]
mx = max(abs(a[c] - b[c]) for s0, s1 in zip(steps, steps[1:]) for a, b in zip(s0, s1) for c in range(3))
ok(mx <= 4, 'per-frame change at period 120 s / 4 fps is small (max %d levels)' % mx)
ok(steps[-1] == steps[0], 'the last frame of the period is frame 0 again')
sf = ramdrift.stick_frames(STOPS, 'across', 2, 8, 0.0, 0.5)
ok(sf[0] + sf[1] == f0, 'across: stick 0 then stick 1 = one 16-LED frame')
ss = ramdrift.stick_frames(STOPS, 'stick', 2, 8, 0.0, 0.5)
ok(ss[0] == ss[1] == ramdrift.frame(STOPS, 8, 0.0, 0.5), 'stick: the same 8-LED frame on each')
ok(ramdrift.check({'gradient': STOPS}) == [], 'no drift = no problems')
ok(ramdrift.check({'gradient': STOPS, 'drift': {'period': 120, '_note': 'x'}}) == [], 'a valid drift, "_" keys allowed')
bad = ramdrift.check({'leds': [], 'drift': {'period': 1, 'window': 0, 'fps': 11, 'reverse': 1, 'speed': 2}})
ok(len(bad) == 6, 'every drift problem reported (%d)' % len(bad))
ok(ramdrift.settings({'drift': {}}) == {'period': 120, 'window': 0.5, 'reverse': False, 'fps': 4}, 'defaults')

# ---- params ---------------------------------------------------------------------------
tmp = tempfile.mkdtemp()
eff = os.path.join(tmp, 'eff.json')
json.dump({'ram': {'gradient': ['#FF6A2A', 'ff1a70'], 'span': 'across', 'drift': {'period': 60}}}, open(eff, 'w'))
orgb = os.path.join(tmp, 'orgb.json')
json.dump({'ram': {'match_name': 'ENE DRAM', 'leds_per_device': 8}}, open(orgb, 'w'))
listing = os.path.join(tmp, 'list.txt')
open(listing, 'w').write('0: ENE DRAM\n  Type: DRAM\n  Location:       I2C: bus, address 0x71\n\n'
                         '1: ENE DRAM\n  Location:       I2C: bus, address 0x73\n\n2: GPU\n  Location: x\n')
p = ramdrift.params(eff, '0 1 ', orgb, listing)
ok(p['stops'] == ['ff6a2a', 'ff1a70'] and p['period'] == 60 and p['fps'] == 4 and p['count'] == 2,
   'params: stops normalised, defaults filled')
ok(p['locations'] == ['I2C: bus, address 0x71', 'I2C: bus, address 0x73'], 'params: locations from the listing')
json.dump({'ram': {'gradient': STOPS}}, open(eff, 'w'))
ok(ramdrift.params(eff, '0 1', orgb, listing) is None, 'params: no drift = None')

# ---- pick_sticks ------------------------------------------------------------------------
C = [{'name': 'ENE DRAM', 'location': 'x address 0x73'}, {'name': 'GPU', 'location': 'g'},
     {'name': 'ENE DRAM', 'location': 'x address 0x71'}]
ok(ramdrift.pick_sticks(C, {'match_name': 'ENE DRAM', 'count': 2, 'locations': []}) == [2, 0],
   'pick: sorted by SMBus address')
ok(ramdrift.pick_sticks(C, {'match_name': 'ENE DRAM', 'count': 2,
                            'locations': ['x address 0x73', 'x address 0x71']}) == [0, 2], 'pick: by the listing locations')
ok(ramdrift.pick_sticks(C, {'match_name': 'ENE DRAM', 'count': 3, 'locations': []}) is None, 'pick: wrong count = None')


# ---- the animator against the fake server -------------------------------------------------
def fixture(params=None, lights='on'):
    home = tempfile.mkdtemp()
    cache = os.path.join(home, '.cache/pc-lights')
    state = os.path.join(home, '.config/pc-lights')
    os.makedirs(cache)
    os.makedirs(state)
    os.makedirs(os.path.join(home, '.config/OpenRGB'))
    json.dump({'Detectors': {'detectors': {'ENE SMBus DRAM': True, 'ASUS Aura SMBus Motherboard': True,
                                           'Razer Deathadder Elite': True}}, 'Other': 1},
              open(os.path.join(home, '.config/OpenRGB/OpenRGB.json'), 'w'))
    open(os.path.join(state, 'lights'), 'w').write(lights + '\n')
    if params is not False:
        pr = params or {'v': 1, 'stops': STOPS, 'span': 'across', 'period': 120, 'window': 0.5, 'reverse': False,
                        'fps': 4, 'leds_per_device': 8, 'match_name': 'ENE DRAM', 'count': 2, 'ids': ['0', '1'],
                        'locations': []}
        json.dump(pr, open(os.path.join(cache, 'ram-drift.json'), 'w'))
    port = free_port()
    env = dict(os.environ, HOME=home, PCL_OPENRGB=os.path.join(HERE, 'fake_openrgb.py'),
               PCL_RAM_DRIFT_PORT=str(port), PCL_RAM_DRIFT_NO_LOGGER='1', PCL_RAM_DRIFT_WAIT='15',
               FAKE_ORGB_LOG=os.path.join(home, 'orgb.log'))
    return home, env


def start(env):
    return subprocess.Popen([sys.executable, os.path.join(LIB, 'ramdrift.py'), 'run'], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def packets(home):
    try:
        return [json.loads(line) for line in open(os.path.join(home, 'orgb.log'))]
    except OSError:
        return []


def cpu_s(pid):
    f = open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()
    return (int(f[11]) + int(f[12])) / os.sysconf('SC_CLK_TCK')


def fake_pids(home):
    out = []
    for d in os.listdir('/proc'):
        if d.isdigit():
            try:
                if ('fake_openrgb.py' in open('/proc/%s/cmdline' % d).read()
                        and home in open('/proc/%s/environ' % d, errors='replace').read()):
                    out.append(int(d))
            except OSError:
                pass
    return out


home, env = fixture()
env['FAKE_ORGB_DELAY'] = '1.5'
pr = start(env)
time.sleep(8)
cpu = cpu_s(pr.pid)
pr.send_signal(signal.SIGTERM)
try:
    rc = pr.wait(15)
except subprocess.TimeoutExpired:
    pr.kill()
    rc = 'hung'
err = pr.stderr.read()
pk = packets(home)
ok(rc == 0 and 'stopped (SIGTERM)' in err, 'SIGTERM: clean exit 0 (%s)' % rc)
time.sleep(0.5)
ok(not fake_pids(home), 'SIGTERM: the OpenRGB child is gone too')
started = [x for x in pk if x.get('started')]
ok(started and started[0]['args'][:1] == ['--config'] and '--noautoconnect' in started[0]['args']
   and '127.0.0.1' in started[0]['args'], 'the child: private --config, localhost, --noautoconnect')
cfg = json.load(open(os.path.join(home, 'orgb.log.config')))
ok(cfg == {'Detectors': {'detectors': {'ENE SMBus DRAM': True, 'ASUS Aura SMBus Motherboard': False,
                                       'Razer Deathadder Elite': False}}},
   'private OpenRGB.json: every detector off but ENE SMBus DRAM')
ok(any(x.get('pid') == 40 and x['client'] == 4 for x in pk) and any(x.get('pid') == 50 for x in pk),
   'handshake: protocol version, client name')
ok(sorted(x['addr'] for x in pk if x.get('pid') == 1100) == ['71', '73'], 'custom (Direct) mode on both sticks')
upd = [x for x in pk if x.get('pid') == 1050]
ok(upd and all(x['size_ok'] and len(x['colours']) == 8 for x in upd), 'UPDATELEDS: 8 colours, size fields right')
first = {}
for x in upd:
    first.setdefault(x['addr'], x['colours'])
ok(first.get('71') == [list(c) for c in f0[:8]] and first.get('73') == [list(c) for c in f0[8:]],
   'the first frame is frame 0: 0x71 = stick 0, 0x73 = stick 1 (sorted by address)')
n71 = sum(1 for x in upd if x['addr'] == '71')
ok(15 <= n71 <= 32, '~4 frames/s written (%d on 0x71 in ~6 s)' % n71)
ok(cpu < 0.4, 'animator CPU over ~8 s at 4 fps: %.2f s' % cpu)
print('# animator CPU: %.3f s over ~8 s (%.2f %%)' % (cpu, cpu / 8 * 100))

# unchanged frames are skipped: an hour's period at 10 fps barely moves
home, env = fixture({'v': 1, 'stops': STOPS, 'span': 'stick', 'period': 3600, 'window': 0.5, 'reverse': False,
                     'fps': 10, 'leds_per_device': 8, 'match_name': 'ENE DRAM', 'count': 2, 'ids': ['0', '1'],
                     'locations': []})
pr = start(env)
time.sleep(5)
os.kill(pr.pid, signal.SIGTERM)
pr.wait(15)
upd = [x for x in packets(home) if x.get('pid') == 1050]
ok(0 < len(upd) < 20, 'unchanged frames are not re-sent (%d writes in ~4 s at 10 fps, 2 sticks)' % len(upd))

# lights go off: it stops by itself within a few seconds
home, env = fixture()
pr = start(env)
time.sleep(3)
open(os.path.join(home, '.config/pc-lights/lights'), 'w').write('off\n')
try:
    rc = pr.wait(8)
except subprocess.TimeoutExpired:
    pr.kill()
    rc = 'hung'
ok(rc == 0 and 'lights went off' in pr.stderr.read(), 'lights off: exits 0 on its own (%s)' % rc)

# openrgb.lock held (an apply): it doesn't start at all
home, env = fixture()
lk = open(os.path.join(home, '.cache/pc-lights/openrgb.lock'), 'a')
fcntl.flock(lk, fcntl.LOCK_EX)
pr = start(env)
rc = pr.wait(10)
ok(rc == 0 and 'busy' in pr.stderr.read() and not packets(home), 'openrgb.lock held: exit 0, no OpenRGB started')
lk.close()

# no params / lights off at start: nothing
home, env = fixture(params=False)
pr = start(env)
ok(pr.wait(10) == 0 and not packets(home), 'no ram-drift.json: exit 0, nothing started')
home, env = fixture(lights='off')
pr = start(env)
ok(pr.wait(10) == 0 and not packets(home), 'lights off at start: exit 0, nothing started')

# the child dies: it stops with a failure (Restart=on-failure takes over)
home, env = fixture()
env['FAKE_ORGB_EXIT'] = '2'
pr = start(env)
try:
    rc = pr.wait(15)
except subprocess.TimeoutExpired:
    pr.kill()
    rc = 'hung'
ok(rc == 1, 'the OpenRGB child dies: exit 1 (%s)' % rc)

# the sticks never show up: gives up with a failure
home, env = fixture()
env['FAKE_ORGB_STICKS'] = '71'
env['PCL_RAM_DRIFT_WAIT'] = '3'
pr = start(env)
rc = pr.wait(20)
ok(rc == 1 and 'giving up' in pr.stderr.read(), 'one stick instead of two: exit 1, logged')

# the user's OpenRGB.json has no detector list: refuses (would detect everything)
home, env = fixture()
os.remove(os.path.join(home, '.config/OpenRGB/OpenRGB.json'))
pr = start(env)
ok(pr.wait(10) == 1 and not packets(home), 'no detector list to copy: exit 1, nothing started')

# ---- the real OpenRGB, --nodetect (no hardware detection at all) -------------------------------
if '--real-openrgb' in sys.argv:
    cdir = tempfile.mkdtemp()
    port = free_port()
    child = subprocess.Popen(['openrgb', '--config', cdir, '--server', '--server-host', '127.0.0.1',
                              '--server-port', str(port), '--noautoconnect', '--nodetect'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cl = None
    for _ in range(60):
        try:
            cl = ramdrift.Client(port=port)
            break
        except OSError:
            time.sleep(0.25)
    ok(cl is not None and cl.proto >= 1, 'real openrgb --nodetect: SDK handshake (protocol %s)' % (cl and cl.proto))
    ok(cl is not None and cl.count() == 0, 'real openrgb --nodetect: 0 controllers')
    c0 = cpu_s(child.pid)
    time.sleep(10)
    c1 = cpu_s(child.pid)
    print('# openrgb --server --nodetect idle CPU: %.3f s over 10 s (%.2f %%), RSS %s' % (
        c1 - c0, (c1 - c0) * 10, [ln.split()[1] + ' kB' for ln in open('/proc/%d/status' % child.pid)
                                  if ln.startswith('VmRSS')][0]))
    ok(c1 - c0 < 0.5, 'real openrgb server idles (%.2f s CPU in 10 s)' % (c1 - c0))
    if cl:
        cl.close()
    child.terminate()
    child.wait(10)

print('# ramdrift python: %d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)

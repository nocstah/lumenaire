#!/usr/bin/env python3
# fake_openrgb.py — stands in for "openrgb --config DIR --server ..." in the
# ramdrift tests: a tiny OpenRGB SDK server with fake "ENE DRAM" sticks. It
# never touches hardware. Every packet it gets is logged as a JSON line to
# $FAKE_ORGB_LOG; the config dir's OpenRGB.json is copied to $FAKE_ORGB_LOG.config.
#   FAKE_ORGB_STICKS  addresses, in the server's order (default "73 71": out of
#                     order on purpose, the animator must sort them)
#   FAKE_ORGB_DELAY   seconds before the sticks appear (count 0 until then)
#   FAKE_ORGB_EXIT    exit after this many seconds (the child dying)
import json
import os
import shutil
import socket
import struct
import sys
import threading
import time

args = sys.argv[1:]


def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default


LOG = os.environ['FAKE_ORGB_LOG']
port = int(opt('--server-port', '6742'))
cfg = opt('--config')
if '--server' not in args:
    print('fake_openrgb: only --server is faked', file=sys.stderr)
    sys.exit(2)
if cfg:
    shutil.copy(os.path.join(cfg, 'OpenRGB.json'), LOG + '.config')
sticks = os.environ.get('FAKE_ORGB_STICKS', '73 71').split()
delay = float(os.environ.get('FAKE_ORGB_DELAY', '0'))
t0 = time.monotonic()
lock = threading.Lock()


def log(**kw):
    with lock, open(LOG, 'a') as f:
        f.write(json.dumps(kw) + '\n')


def sstr(s):
    b = s.encode() + b'\0'
    return struct.pack('<H', len(b)) + b


def ctrl_data(addr):
    body = struct.pack('<i', 1) + sstr('ENE DRAM') + sstr('ENE') + sstr('ENE SMBus Device') \
        + sstr('DIMM_LED-0103') + sstr('') \
        + sstr('I2C: SMBus PIIX4 adapter port 0 at 0b00 (/dev/i2c-15), address 0x%s' % addr) \
        + b'\x00' * 40   # the modes/zones/LEDs a real reply carries (never parsed)
    return struct.pack('<I', 4 + len(body)) + body


def reply(conn, dev, pid, data):
    conn.sendall(b'ORGB' + struct.pack('<III', dev, pid, len(data)) + data)


def exact(conn, n):
    buf = b''
    while len(buf) < n:
        c = conn.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


def serve(conn):
    try:
        while True:
            magic, dev, pid, size = struct.unpack('<4sIII', exact(conn, 16))
            data = exact(conn, size) if size else b''
            if magic != b'ORGB':
                log(error='bad magic')
                return
            visible = time.monotonic() - t0 >= delay
            if pid == 40:
                log(pid=40, client=struct.unpack('<I', data)[0])
                reply(conn, 0, 40, struct.pack('<I', 5))
                reply(conn, 0, 100, b'')    # an unsolicited DEVICE_LIST_UPDATED
            elif pid == 50:
                log(pid=50, name=data.rstrip(b'\0').decode())
            elif pid == 0:
                reply(conn, 0, 0, struct.pack('<I', len(sticks) if visible else 0))
            elif pid == 1:
                log(pid=1, dev=dev, proto=struct.unpack('<I', data)[0])
                reply(conn, dev, 1, ctrl_data(sticks[dev]))
            elif pid == 1100:
                log(pid=1100, dev=dev, addr=sticks[dev])
            elif pid == 1050:
                total, n = struct.unpack_from('<IH', data)
                cs = [list(struct.unpack_from('<BBB', data, 6 + 4 * i)) for i in range(n)]
                log(pid=1050, dev=dev, addr=sticks[dev], size_ok=(total == size == 6 + 4 * n), colours=cs,
                    t=round(time.monotonic() - t0, 3))
            else:
                log(pid=pid, dev=dev, unexpected=True)
    except (EOFError, OSError):
        return


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', port))
srv.listen(4)
log(started=True, args=args)
life = os.environ.get('FAKE_ORGB_EXIT')
if life:
    threading.Timer(float(life), lambda: os._exit(3)).start()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()

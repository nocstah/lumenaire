"""Minimal MS-NRBF (.NET BinaryFormatter) reader -> plain Python objects.

Classes become dicts with "__class" plus member values; references are
resolved after the stream is read. Enough for L-Connect .template files.
"""
import struct
import sys

PRIM = {1: '?', 2: 'B', 7: 'h', 8: 'i', 9: 'q', 10: 'b', 11: 'f', 6: 'd',
        12: 'q', 13: 'Q', 14: 'H', 15: 'I', 16: 'Q'}


class Ref:
    def __init__(self, idref):
        self.idref = idref


class Reader:
    def __init__(self, data):
        self.d = data
        self.i = 0
        self.objs = {}
        self.meta = {}  # metadata object id -> (name, members, types, extras)

    def u8(self):
        v = self.d[self.i]
        self.i += 1
        return v

    def i32(self):
        v = struct.unpack_from('<i', self.d, self.i)[0]
        self.i += 4
        return v

    def lps(self):
        n = shift = 0
        while True:
            b = self.u8()
            n |= (b & 0x7F) << shift
            shift += 7
            if not b & 0x80:
                break
        s = self.d[self.i:self.i + n].decode('utf-8', 'replace')
        self.i += n
        return s

    def prim(self, t):
        if t == 18:
            return self.lps()
        if t == 5:
            return self.lps()
        if t == 3:  # UTF-8 char
            b = self.d[self.i]
            n = 1 if b < 0x80 else 2 if b < 0xE0 else 3 if b < 0xF0 else 4
            s = self.d[self.i:self.i + n].decode('utf-8', 'replace')
            self.i += n
            return s
        if t == 17:
            return None
        fmt = PRIM[t]
        v = struct.unpack_from('<' + fmt, self.d, self.i)[0]
        self.i += struct.calcsize(fmt)
        return v

    def class_info(self):
        oid = self.i32()
        name = self.lps()
        n = self.i32()
        members = [self.lps() for _ in range(n)]
        return oid, name, members

    def type_info(self, n):
        types = [self.u8() for _ in range(n)]
        extras = []
        for t in types:
            if t in (0, 7):
                extras.append(self.u8())
            elif t == 3:
                extras.append(self.lps())
            elif t == 4:
                extras.append((self.lps(), self.i32()))
            else:
                extras.append(None)
        return types, extras

    def values(self, oid, name, members, types, extras):
        obj = {'__class': name}
        self.objs[oid] = obj
        for m, t, x in zip(members, types, extras):
            if t == 0:
                obj[m] = self.prim(x)
            else:
                obj[m] = self.record()
        return obj

    def elements(self, count, prim_type=None):
        out = []
        while len(out) < count:
            if prim_type is not None:
                out.append(self.prim(prim_type))
                continue
            r = self.record()
            if isinstance(r, tuple) and r[0] == 'nulls':
                out.extend([None] * r[1])
            else:
                out.append(r)
        return out

    def record(self):
        rt = self.u8()
        if rt == 0:
            self.i += 16
            return self.record()
        if rt == 12:  # BinaryLibrary
            self.i32()
            self.lps()
            return self.record()
        if rt in (5, 4):
            oid, name, members = self.class_info()
            types, extras = self.type_info(len(members))
            if rt == 5:
                self.i32()
            self.meta[oid] = (name, members, types, extras)
            return self.values(oid, name, members, types, extras)
        if rt in (3, 2):
            oid, name, members = self.class_info()
            if rt == 3:
                self.i32()
            types, extras = [2] * len(members), [None] * len(members)
            self.meta[oid] = (name, members, types, extras)
            return self.values(oid, name, members, types, extras)
        if rt == 1:
            oid = self.i32()
            mid = self.i32()
            name, members, types, extras = self.meta[mid]
            self.meta[oid] = self.meta[mid]
            return self.values(oid, name, members, types, extras)
        if rt == 6:
            oid = self.i32()
            s = self.lps()
            self.objs[oid] = s
            return s
        if rt == 7:
            oid = self.i32()
            atype = self.u8()
            rank = self.i32()
            lengths = [self.i32() for _ in range(rank)]
            if atype in (3, 4, 5):
                [self.i32() for _ in range(rank)]
            t = self.u8()
            x = None
            if t in (0, 7):
                x = self.u8()
            elif t == 3:
                x = self.lps()
            elif t == 4:
                x = (self.lps(), self.i32())
            count = 1
            for n in lengths:
                count *= n
            arr = self.elements(count, x if t == 0 else None)
            self.objs[oid] = arr
            return arr
        if rt == 8:
            t = self.u8()
            return self.prim(t)
        if rt == 9:
            return Ref(self.i32())
        if rt == 10:
            return None
        if rt == 11:
            return 'END'
        if rt == 13:
            return ('nulls', self.u8())
        if rt == 14:
            return ('nulls', self.i32())
        if rt == 15:
            oid = self.i32()
            n = self.i32()
            t = self.u8()
            if t == 2:  # byte[] — keep as bytes
                b = self.d[self.i:self.i + n]
                self.i += n
                self.objs[oid] = b
                return b
            arr = [self.prim(t) for _ in range(n)]
            self.objs[oid] = arr
            return arr
        if rt in (16, 17):
            oid = self.i32()
            n = self.i32()
            arr = self.elements(n)
            self.objs[oid] = arr
            return arr
        raise ValueError(f'unknown record type {rt} at offset {self.i - 1}')


def resolve(o, objs, seen=None):
    if seen is None:
        seen = set()
    if isinstance(o, Ref):
        if o.idref in seen:
            return f'<cycle {o.idref}>'
        target = objs.get(o.idref)
        return resolve(target, objs, seen | {o.idref})
    if isinstance(o, dict):
        return {k: resolve(v, objs, seen) for k, v in o.items()}
    if isinstance(o, list):
        return [resolve(v, objs, seen) for v in o]
    return o


def load(path):
    r = Reader(open(path, 'rb').read())
    root = None
    while r.i < len(r.d):
        rec = r.record()
        if rec == 'END':
            break
        if root is None and isinstance(rec, dict):
            root = rec
    return resolve(root, r.objs)


if __name__ == '__main__':
    import json
    obj = load(sys.argv[1])

    def enc(o):
        if isinstance(o, (bytes, bytearray)):
            return f'<bytes {len(o)}>'
        return str(o)
    json.dump(obj, open(sys.argv[2], 'w'), default=enc, indent=1)
    print('ok')

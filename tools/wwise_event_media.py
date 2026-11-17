"""Which .wem media an Audiokinetic Wwise event can play (heuristic, no full HIRC decoder).

    python wwise_event_media.py <bank.bnk> <Wwise_IDs.h> <wem id list file> EVENT_NAME [...]

Walks the bank's HIRC objects from the event: an object's payload is scanned for 4-byte values
that are other object IDs (children/targets) or known .wem IDs (media). Parent links are skipped
by not walking into objects of the container types that sit above the target (actor-mixers,
buses) and by limiting depth. Prints candidate .wem IDs per event; check durations with vgmstream.
"""
import re, struct, sys

TYPES = {2: "sound", 3: "action", 4: "event", 5: "rand/seq", 6: "switch", 7: "actor-mixer", 9: "layer",
         10: "music segment", 11: "music track", 12: "music switch", 13: "music playlist", 14: "attenuation"}


def sections(data):
    p = 0
    while p + 8 <= len(data):
        tag, size = data[p:p + 4].decode("latin1"), struct.unpack_from("<I", data, p + 4)[0]
        yield tag, data[p + 8:p + 8 + size]; p += 8 + size


def hirc(data):
    objs = {}
    for tag, body in sections(data):
        if tag != "HIRC": continue
        n, p = struct.unpack_from("<I", body, 0)[0], 4
        for _ in range(n):
            t, size = body[p], struct.unpack_from("<I", body, p + 1)[0]
            oid = struct.unpack_from("<I", body, p + 5)[0]
            objs[oid] = (t, body[p + 9:p + 5 + size]); p += 5 + size
    return objs


def u32s(b):
    return {struct.unpack_from("<I", b, i)[0] for i in range(0, len(b) - 3)}


def main():
    bnk, ids_h, wems_file, *events = sys.argv[1:]
    data = open(bnk, "rb").read()
    objs = hirc(data)
    names = dict((m.group(1), int(m.group(2))) for m in re.finditer(r"AkUniqueID (\w+) = (\d+)U", open(ids_h).read()))
    wems = {int(x) for x in open(wems_file).read().split()}
    for ev in events:
        eid = names.get(ev)
        if eid is None or eid not in objs: print(ev, "not in this bank"); continue
        seen, media, frontier = {eid}, {}, [(eid, 0)]
        while frontier:
            oid, depth = frontier.pop()
            t, payload = objs[oid]
            for v in u32s(payload):
                if v in wems: media.setdefault(v, TYPES.get(t, t))
                if v in objs and v not in seen and depth < 6:
                    ct = objs[v][0]
                    if ct in (7, 14) or v == oid: continue   # actor-mixers / attenuations are above, not below
                    seen.add(v); frontier.append((v, depth + 1))
        print(ev, eid, "->", " ".join(f"{m}({k})" for m, k in sorted(media.items())) or "no media found")


if __name__ == "__main__":
    main()

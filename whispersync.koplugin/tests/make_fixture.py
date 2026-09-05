#!/usr/bin/env python3
"""
Build a synthetic MOBI file for the Lua tests.

Uses a small greedy PalmDOC compressor (literals, back-references and the
space+char shorthand) and appends MOBI trailing entries to every text record,
so the Lua decoder is exercised on the parts that bite: back-references,
record boundaries and extra_flags stripping. palmdoc_oracle.py (the dashboard's
validated Python decoder) is the oracle.
"""
import struct, sys, pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import palmdoc_oracle as book_text  # noqa: E402

HTML = ("<html><head><guide></guide></head><body>"
        "<h1>Chapter One</h1>"
        "<p>It was a bright cold day in April, and the clocks were striking thirteen. "
        "Winston Smith, his chin nuzzled into his breast &amp; his coat, slipped quickly "
        "through the glass doors &mdash; though not quickly enough.</p>"
        "<p>The hallway smelt of boiled cabbage and old rag mats.   At one end of it a "
        "coloured poster, too large for indoor display, had been tacked to the wall.</p>"
        + "".join(f"<p>Paragraph number {i} repeats the phrase the clocks were striking "
                  f"for testing, with caf&eacute; and &#8220;quotes&#8221; number {i}.</p>"
                  for i in range(3, 400))
        + "<mbp:pagebreak/><h2>Chapter Two</h2><p>The end of the fixture text.</p>"
        "</body></html>")


def palmdoc_compress(data: bytes) -> bytes:
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        # Try a back-reference of length 3..10 within distance 1..2047.
        best_len, best_dist = 0, 0
        lo = max(0, i - 2047)
        for length in range(10, 2, -1):
            if i + length > n:
                continue
            chunk = data[i:i + length]
            pos = data.rfind(chunk, lo, i + length - 1)
            if pos != -1 and pos < i:
                best_len, best_dist = length, i - pos
                break
        if best_len:
            pair = 0x8000 | (best_dist << 3) | (best_len - 3)
            out += struct.pack(">H", pair)
            i += best_len
            continue
        b = data[i]
        if b == 0x20 and i + 1 < n and 0x40 <= data[i + 1] <= 0x7F:
            out.append(data[i + 1] | 0x80)
            i += 2
        elif 0x09 <= b <= 0x7F:
            out.append(b)
            i += 1
        else:
            run = bytearray()
            while i < n and len(run) < 8 and not (0x09 <= data[i] <= 0x7F):
                run.append(data[i]); i += 1
            out.append(len(run)); out += run
    return bytes(out)


def build_mobi(html: bytes, compress=True) -> bytes:
    RECSIZE = 4096
    text_recs = [html[i:i + RECSIZE] for i in range(0, len(html), RECSIZE)]
    payload = []
    for r in text_recs:
        body = palmdoc_compress(r) if compress else r
        # Trailing entries: one flagged entry (flag bit 1) of 3 bytes with a
        # backward varint size, plus a multibyte overlap (bit 0) of 0 chars.
        tbs = b"\x01\x02" + bytes([0x80 | 3])   # size 3 incl. the size byte
        mb = bytes([0x00])                        # multibyte: 0 overlap bytes
        payload.append(body + mb + tbs)  # multibyte entry sits closest to the text
    extra_flags = 0b11

    # EXTH
    def exth_rec(t, v):
        return struct.pack(">II", t, 8 + len(v)) + v
    exth_recs = [exth_rec(100, b"George Orwell"), exth_rec(503, b"Nineteen Eighty-Four (fixture)"),
                 exth_rec(113, b"TESTPDOCKEY0123456789ABCDEFGHIJK"), exth_rec(100, b"Second Author"),
                 exth_rec(201, struct.pack(">I", 0))]
    exth_body = b"".join(exth_recs)
    exth = b"EXTH" + struct.pack(">II", 12 + len(exth_body), len(exth_recs)) + exth_body
    exth += b"\x00" * ((4 - len(exth) % 4) % 4)

    mobi_len = 0xE8
    mobi = bytearray(b"\x00" * mobi_len)
    mobi[0:4] = b"MOBI"
    mobi[4:8] = struct.pack(">I", mobi_len)
    mobi[8:12] = struct.pack(">I", 2)          # mobi type: book
    mobi[12:16] = struct.pack(">I", 65001)     # utf-8
    mobi[92:96] = struct.pack(">I", len(text_recs) + 1)  # first image index
    mobi[0x80 - 16:0x84 - 16] = struct.pack(">I", 0x50)   # exth flags (unreliable on purpose: set)
    # extra_flags at record0 + 242 => mobi offset 242 - 16 = 226
    mobi[226:228] = struct.pack(">H", extra_flags)

    rec0 = struct.pack(">HHIHHH", 2 if compress else 1, 0, len(html), len(text_recs), RECSIZE, 0) + b"\x00\x00" + bytes(mobi) + exth
    records = [rec0] + payload + [b"\xff\xd8\xff\xe0" + b"FAKEJPEG" * 200]  # one image record
    nrec = len(records)
    header = bytearray(b"\x00" * 78)
    header[0:32] = b"CR!FIXTUREACRNAME00000000000000".ljust(32, b"\x00")
    header[60:68] = b"BOOKMOBI"
    header[76:78] = struct.pack(">H", nrec)
    table = bytearray()
    offset = 78 + 8 * nrec + 2
    for i, r in enumerate(records):
        table += struct.pack(">IBBH", offset, 0, 0, i)  # simplified attrs/uid
        offset += len(r)
    return bytes(header) + bytes(table) + b"\x00\x00" + b"".join(records)


if __name__ == "__main__":
    out = pathlib.Path(__file__).parent / "fixture"
    out.mkdir(exist_ok=True)
    html = HTML.encode("utf-8")
    blob = build_mobi(html)
    (out / "fixture.mobi").write_bytes(blob)
    (out / "fixture.html").write_bytes(html)
    # Oracle: round-trip through the Python decoder.
    recs = []
    nrec = struct.unpack(">H", blob[76:78])[0]
    offs = [struct.unpack(">I", blob[78 + 8 * i:82 + 8 * i])[0] for i in range(nrec)]
    for i in range(1, len(offs) - 1):
        rec = blob[offs[i]:offs[i + 1]]
        rec = book_text.strip_extra_bytes(rec, 0b11)
        recs.append(book_text.palmdoc_decompress(rec))
    assert b"".join(recs) == html, "python oracle failed to round-trip"
    # A standalone opcode torture stream, decoded by the oracle.
    torture = bytes([0x00, 0x03, 0xC3, 0xA9, 0x01, 0x41, 0x42, 0x43]) + struct.pack(">H", 0x8000 | (3 << 3) | 0) + bytes([0xC1, 0x7F])
    (out / "torture.bin").write_bytes(torture)
    (out / "torture.expected").write_bytes(book_text.palmdoc_decompress(torture))
    print(f"fixture: {len(blob)} bytes, text {len(html)} bytes, {len(recs)} records")

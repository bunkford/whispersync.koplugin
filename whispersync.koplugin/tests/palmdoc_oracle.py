"""
Reference PalmDOC decoder used as the test oracle.

Copied verbatim from book_text.py in the Kindle dashboard repository
(https://github.com/bunkford/Kindle-sync), where it was validated against
real Send-to-Kindle documents: extracted text came to exactly the header's
text_length once trailing entries were stripped before decompression.
"""

from __future__ import annotations

def palmdoc_decompress(data: bytes) -> bytes:
    """
    PalmDOC (compression type 2) decompression.

    Byte-driven: literals, short literal runs, back-references into the output,
    and a space-plus-character shorthand for the high range.
    """
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        b = data[i]
        i += 1
        if b == 0x00:
            out.append(0)
        elif b <= 0x08:                       # next b bytes are literal
            out += data[i:i + b]
            i += b
        elif b <= 0x7F:                       # plain ASCII
            out.append(b)
        elif b <= 0xBF:                       # back-reference
            if i >= n:
                break
            pair = (b << 8) | data[i]
            i += 1
            dist = (pair >> 3) & 0x07FF
            length = (pair & 0x07) + 3
            if dist == 0 or dist > len(out):
                break
            start = len(out) - dist
            for k in range(length):
                out.append(out[start + k])
        else:                                 # space + literal
            out.append(0x20)
            out.append(b ^ 0x80)
    return bytes(out)

def strip_extra_bytes(rec: bytes, extra_flags: int) -> bytes:
    """
    Remove the trailing metadata MOBI appends to each text record.

    Text records don't end at the text: MOBI tacks on optional trailing entries
    (indexing data, and a multibyte-character overlap fixup) whose presence is
    described by `extra_flags`. They must come off *before* decompression —
    leaving them on corrupts the tail of each record, which shows up as
    scrambled words at record boundaries ("where we {erere they?" instead of
    "where were they?").

    Each flagged entry is length-prefixed backwards: the size is encoded in the
    final bytes, with bit 7 marking the end of the varint.
    """
    if not extra_flags:
        return rec

    def backward_varint(buf: bytes) -> int:
        """Decode the size stored at the end of buf, per MOBI's scheme."""
        n = 0
        shift = 0
        for byte in reversed(buf[-4:]):
            n |= (byte & 0x7F) << shift
            shift += 7
            if byte & 0x80:
                break
        return n

    # Bits 1..15 each describe one trailing entry.
    flags = extra_flags >> 1
    while flags:
        if flags & 1:
            size = backward_varint(rec)
            if size <= 0 or size > len(rec):
                break
            rec = rec[:-size]
        flags >>= 1

    # Bit 0: a multibyte-character overlap, whose length is in the last byte.
    if extra_flags & 1 and rec:
        n = (rec[-1] & 0x3) + 1
        if n <= len(rec):
            rec = rec[:-n]
    return rec


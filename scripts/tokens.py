"""A small, slow DEFLATE decoder in pure Python that records what it reads:
block types, the code lengths of dynamic blocks, and the tokens (literals
and back-references). Used for the explanatory figures; it is independent of
the Zig code, so it also serves as a third decoder for the round trip.
"""

LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195,
               227, 258]
LENGTH_EXTRA = [0] * 8 + [1] * 4 + [2] * 4 + [3] * 4 + [4] * 4 + [5] * 4 + [0]
DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
             4097, 6145, 8193, 12289, 16385, 24577]
DIST_EXTRA = [0, 0, 0, 0] + [i // 2 for i in range(2, 28)]
ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


class Bits:
    def __init__(self, data):
        self.data, self.pos = data, 0  # pos in bits

    def bit(self):
        b = (self.data[self.pos >> 3] >> (self.pos & 7)) & 1
        self.pos += 1
        return b

    def bits(self, n):
        v = 0
        for i in range(n):
            v |= self.bit() << i
        return v


def code_table(lengths):
    """(length, code) -> symbol for a canonical Huffman code."""
    count = [0] * 16
    for n in lengths:
        if n:
            count[n] += 1
    code, nxt = 0, [0] * 16
    for n in range(1, 16):
        code = (code + count[n - 1]) << 1
        nxt[n] = code
    table = {}
    for sym, n in enumerate(lengths):
        if n:
            table[(n, nxt[n])] = sym
            nxt[n] += 1
    return table


def decode(r, table):
    code = n = 0
    while True:
        code = (code << 1) | r.bit()
        n += 1
        if (n, code) in table:
            return table[(n, code)]
        if n > 15:
            raise ValueError("invalid code")


def parse(data):
    """Returns (output, blocks). Each block is a dict with its type, its
    literal/length and distance code lengths, and its tokens: ("lit", byte)
    or ("match", length, distance), each with the output offset it starts at."""
    r, out, blocks = Bits(data), bytearray(), []
    while True:
        final, kind = r.bit(), r.bits(2)
        block = {"type": ["stored", "fixed", "dynamic"][kind], "tokens": []}
        blocks.append(block)
        if kind == 0:
            r.pos = (r.pos + 7) & ~7
            n = r.bits(16)
            r.bits(16)
            start = r.pos >> 3
            out += data[start:start + n]
            r.pos += 8 * n
        else:
            if kind == 1:
                lit = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
                dist = [5] * 30
            else:
                hlit, hdist, hclen = r.bits(5) + 257, r.bits(5) + 1, r.bits(4) + 4
                cl = [0] * 19
                for s in ORDER[:hclen]:
                    cl[s] = r.bits(3)
                ct = code_table(cl)
                lengths = []
                while len(lengths) < hlit + hdist:
                    s = decode(r, ct)
                    if s < 16:
                        lengths.append(s)
                    elif s == 16:
                        lengths += [lengths[-1]] * (3 + r.bits(2))
                    elif s == 17:
                        lengths += [0] * (3 + r.bits(3))
                    else:
                        lengths += [0] * (11 + r.bits(7))
                lit, dist = lengths[:hlit], lengths[hlit:]
            block["lit_lengths"], block["dist_lengths"] = lit, dist
            lt, dt = code_table(lit), code_table(dist)
            while True:
                s = decode(r, lt)
                if s < 256:
                    block["tokens"].append(("lit", s, len(out)))
                    out.append(s)
                elif s == 256:
                    break
                else:
                    length = LENGTH_BASE[s - 257] + r.bits(LENGTH_EXTRA[s - 257])
                    d = decode(r, dt)
                    distance = DIST_BASE[d] + r.bits(DIST_EXTRA[d])
                    block["tokens"].append(("match", length, distance, len(out)))
                    for _ in range(length):
                        out.append(out[-distance])
        if final:
            return bytes(out), blocks

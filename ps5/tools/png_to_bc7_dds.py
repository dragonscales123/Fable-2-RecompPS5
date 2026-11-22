#!/usr/bin/env python3
"""PNG -> BC7 DDS for the PS5 home screen art (sce_sys / appmeta pic0.dds).

The home screen draws a title's background from pic0.dds / pic1.dds
(3840x2160, BC7, one mip, linear, DX10 header) - retail titles carry them, a
homebrew title's registration only copies the PNG. Usage:

    png_to_bc7_dds.py pic0.png pic0.dds

Needs numpy and Pillow. A simple BC7 mode 6 encoder (one subset, principal
axis endpoints): plenty for a background picture.
"""
import struct
import sys

import numpy as np

W4 = np.array([0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64], np.int32)


def _blocks(img):
    h, w, c = img.shape
    b = img.reshape(h // 4, 4, w // 4, 4, c).transpose(0, 2, 1, 3, 4).reshape(-1, 16, c)
    return b


def _quant_endpoint(v):
    # v: [...,3] float 0..255 -> (c7 [...,3] int, p [...] int) minimizing error
    best = None
    for p in (0, 1):
        c7 = np.clip(np.rint((v - p) / 2.0), 0, 127).astype(np.int32)
        rec = (c7 << 1) | p
        err = ((rec - v) ** 2).sum(-1)
        if best is None:
            best = (c7, np.full(err.shape, p, np.int32), err)
        else:
            m = err < best[2]
            best = (np.where(m[..., None], c7, best[0]), np.where(m, p, best[1]),
                    np.where(m, err, best[2]))
    return best[0], best[1]


def encode(rgb):
    blocks = _blocks(rgb.astype(np.float32))  # [N,16,3]
    n = blocks.shape[0]
    mean = blocks.mean(1, keepdims=True)
    d = blocks - mean
    cov = np.einsum('nki,nkj->nij', d, d)
    axis = np.ones((n, 3), np.float32)
    for _ in range(8):
        axis = np.einsum('nij,nj->ni', cov, axis)
        norm = np.linalg.norm(axis, axis=1, keepdims=True)
        axis = np.where(norm > 1e-6, axis / np.maximum(norm, 1e-6), np.array([0.577, 0.577, 0.577], np.float32))
    proj = np.einsum('nki,ni->nk', d, axis)
    e0 = mean[:, 0] + axis * proj.min(1, keepdims=True)
    e1 = mean[:, 0] + axis * proj.max(1, keepdims=True)
    e0 = np.clip(e0, 0, 255)
    e1 = np.clip(e1, 0, 255)
    c0, p0 = _quant_endpoint(e0)
    c1, p1 = _quant_endpoint(e1)
    r0 = ((c0 << 1) | p0[:, None]).astype(np.int32)
    r1 = ((c1 << 1) | p1[:, None]).astype(np.int32)
    pal = ((64 - W4)[None, :, None] * r0[:, None, :] + W4[None, :, None] * r1[:, None, :] + 32) >> 6
    dist = ((blocks[:, :, None, :] - pal[:, None, :, :].astype(np.float32)) ** 2).sum(-1)
    idx = dist.argmin(-1).astype(np.int32)  # [N,16]
    # Anchor (pixel 0) index must have MSB 0: swap endpoints if needed.
    swap = idx[:, 0] >= 8
    c0s = np.where(swap[:, None], c1, c0)
    c1s = np.where(swap[:, None], c0, c1)
    p0s = np.where(swap, p1, p0)
    p1s = np.where(swap, p0, p1)
    idx = np.where(swap[:, None], 15 - idx, idx)
    # Pack 128 bits LSB first into two uint64.
    lo = np.zeros(n, np.uint64)
    hi = np.zeros(n, np.uint64)
    pos = 0
    fields = [(np.full(n, 1 << 6, np.uint64), 7)]
    for ch in range(3):
        fields.append((c0s[:, ch].astype(np.uint64), 7))
        fields.append((c1s[:, ch].astype(np.uint64), 7))
    fields.append((np.full(n, 127, np.uint64), 7))  # A0 -> 255 with p=1
    fields.append((np.full(n, 127, np.uint64), 7))  # A1
    fields.append((p0s.astype(np.uint64), 1))
    fields.append((p1s.astype(np.uint64), 1))
    for k in range(16):
        fields.append((idx[:, k].astype(np.uint64), 3 if k == 0 else 4))
    # Note: alpha p-bits are the same as color p-bits in mode 6 (RGBA endpoint
    # shares one p-bit), so A = (127<<1)|p is 254 or 255.
    for val, bits in fields:
        mask = np.uint64((1 << bits) - 1)
        val = val & mask
        if pos + bits <= 64:
            lo |= val << np.uint64(pos)
        elif pos >= 64:
            hi |= val << np.uint64(pos - 64)
        else:
            lb = 64 - pos
            lo |= (val & np.uint64((1 << lb) - 1)) << np.uint64(pos)
            hi |= val >> np.uint64(lb)
        pos += bits
    assert pos == 128
    out = np.empty((n, 2), '<u8')
    out[:, 0] = lo
    out[:, 1] = hi
    return out.tobytes()


def decode_mode6(data, w, h):
    raw = np.frombuffer(data, '<u8').reshape(-1, 2)
    lo, hi = raw[:, 0], raw[:, 1]
    n = raw.shape[0]

    def get(pos, bits):
        if pos + bits <= 64:
            return (lo >> np.uint64(pos)) & np.uint64((1 << bits) - 1)
        if pos >= 64:
            return (hi >> np.uint64(pos - 64)) & np.uint64((1 << bits) - 1)
        lb = 64 - pos
        return ((lo >> np.uint64(pos)) | (hi << np.uint64(lb))) & np.uint64((1 << bits) - 1)

    is6 = (lo & np.uint64(0x7F)) == np.uint64(0x40)
    pos = 7
    c = []
    for _ in range(8):
        c.append(get(pos, 7).astype(np.int32))
        pos += 7
    p0 = get(pos, 1).astype(np.int32); p1 = get(pos + 1, 1).astype(np.int32); pos += 2
    idx = []
    for k in range(16):
        b = 3 if k == 0 else 4
        idx.append(get(pos, b).astype(np.int32)); pos += b
    idx = np.stack(idx, 1)
    e0 = np.stack([(c[0] << 1) | p0, (c[2] << 1) | p0, (c[4] << 1) | p0], 1)
    e1 = np.stack([(c[1] << 1) | p1, (c[3] << 1) | p1, (c[5] << 1) | p1], 1)
    wgt = W4[idx]  # [n,16]
    px = ((64 - wgt)[..., None] * e0[:, None] + wgt[..., None] * e1[:, None] + 32) >> 6
    px[~is6] = 128
    img = px.reshape(h // 4, w // 4, 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(h, w, 3)
    return img.astype(np.uint8), is6.mean()


def write_dds(png_path, dds_path):
    from PIL import Image
    img = np.asarray(Image.open(png_path).convert("RGB"))
    h, w = img.shape[:2]
    if w % 4 or h % 4:
        raise SystemExit(f"{png_path}: {w}x{h} isn't a multiple of 4")
    hdr = struct.pack("<4s31I5I", b"DDS ", 124, 0xA1007, h, w, w * h, 0, 1, *([0] * 11),
                      32, 4, int.from_bytes(b"DX10", "little"), 0, 0, 0, 0, 0,
                      0x1000, 0, 0, 0, 0, 98, 3, 0, 1, 0)
    with open(dds_path, "wb") as f:
        f.write(hdr)
        f.write(encode(img))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: png_to_bc7_dds.py in.png out.dds")
    write_dds(sys.argv[1], sys.argv[2])

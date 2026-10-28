#!/usr/bin/env python3
"""sp11-liveness.py — reliable per-frame V4L2 stream-liveness instrument.

Measures REAL frame delivery on the qcom_camss RDI video node (IMX681 raw
path, MULTIPLANAR capture API): every DQBUF is logged with host monotonic
time, v4l2 buffer sequence, the kernel's per-buffer capture timestamp, and
bytesused; the frame payload goes straight to a DISK-BACKED file — never
/tmp (tmpfs exhaustion incident of 2026-10-28: /tmp is 7.3 GB RAM).

Why this instead of file-size counting (history 2026-10-28 13:00 entry:
v4l2-ctl file-size counting lied — stale-buffer fake fills and /tmp write
failures produced bogus frame counts):
  - the per-frame DQBUF log is ground truth of what the kernel handed us;
  - a stall is detected by a select() timeout on the fd, reporting the
    LAST LIVE frame index and the wall-clock instant of detection;
  - a dead pipe shows up as EIO/EPIPE from DQBUF;
  - stale/frozen repeats betray themselves by a non-advancing sequence.

Outputs (<dir>/liveness-<runid>.*):
  .csv   per-frame log: idx, mono_s, seq, bytesused, v4l2_ts_s
  .json  summary (outcome, frames, fps, stall info, gap info)
  .raw   raw frame payload (decode later with raw-naar-png.py)

Usage (as root; media links/formats are set by the caller
install/sp11-liveness.sh):
  sp11-liveness.py [--frames N] [--seconds S] [--dir DIR] [--video DEV]
                   [--dq-timeout T]
python3 stdlib only.

Kernel-UAPI ground truth (probed with gcc tmp/struct-sizes.c against
/usr/include/linux/videodev2.h of this running kernel):
  v4l2_buffer=88 B: index=0 type=4 bytesused=8 flags field=16
    timestamp=24 (sec 24, usec 32) sequence=56 memory=60 union m=64
    length=72 reserved2=76
  v4l2_plane=64 B: bytesused=0 length=4 m.mem_offset=8 data_offset=16
    (res[11] 44 B)  |  VIDEO_MAX_PLANES=8
  v4l2_format=208 B: type=0; pix_mp.width=8 height=12 pixelformat=16
    field=20 plane_fmt[0].sizeimage=28 bytesperline=32 num_planes=188
  v4l2_requestbuffers=20 B | V4L2_CAP node is MPLANE (type 9)
  pixelformats: SRGGB10='RG10'=0x30314752, SRGGB10P='pRAA'=0x41415270
"""

import argparse
import ctypes
import errno
import fcntl
import json
import mmap
import os
import select
import struct
import sys
import time

# ---- uapi constants (kernel videodev2.h) --------------------------------
V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE = 9
V4L2_MEMORY_MMAP = 1
V4L2_FIELD_NONE = 1

VIDIOC_QUERYCAP_NR = 0
VIDIOC_G_FMT_NR = 4
VIDIOC_S_FMT_NR = 5
VIDIOC_REQBUFS_NR = 8
VIDIOC_QUERYBUF_NR = 9
VIDIOC_QBUF_NR = 15
VIDIOC_DQBUF_NR = 17
VIDIOC_STREAMON_NR = 18
VIDIOC_STREAMOFF_NR = 19

# pixelformat constants from the running kernel's headers (%08x probe):
#   V4L2_PIX_FMT_SRGGB10  = 'RG10' = 0x30314752  (unpacked 10-bit)
#   V4L2_PIX_FMT_SRGGB10P = 'pRAA' = 0x41415270  (packed 10-bit, 4 px/5 B)
PIX_FMT_SRGGB10P = 0x41415270

MAX_PLANES = 8


# ---- ctypes struct definitions (offsets per probe above) ----------------
class V4L2Plane(ctypes.Structure):
    _fields_ = [
        ("bytesused", ctypes.c_uint32),      #  0
        ("length", ctypes.c_uint32),         #  4
        ("mem_offset", ctypes.c_uint64),     #  8 (union m, 8-byte aligned)
        ("data_offset", ctypes.c_uint32),    # 16
        ("reserved", ctypes.c_uint32 * 11),  # 20..63
    ]


class V4L2Buffer(ctypes.Structure):
    _fields_ = [
        ("index", ctypes.c_uint32),   #  0
        ("type", ctypes.c_uint32),    #  4
        ("bytesused", ctypes.c_uint32),   #  8 (ignored for MPLANE)
        ("flags", ctypes.c_uint32),   # 12
        ("field", ctypes.c_uint32),   # 16
        ("ts_sec", ctypes.c_int64),   # 24 (struct timeval, 64-bit)
        ("ts_usec", ctypes.c_int64),  # 32
        ("timecode", ctypes.c_uint32 * 4),  # 40 (struct v4l2_timecode)
        ("sequence", ctypes.c_uint32),    # 56
        ("memory", ctypes.c_uint32),      # 60
        ("planes", ctypes.c_void_p),      # 64 (union m -> plane array)
        ("length", ctypes.c_uint32),      # 72 (number of planes, MPLANE)
        ("reserved2", ctypes.c_uint32),   # 76
        ("tail_pad", ctypes.c_uint32),    # 80 (+4 pad -> size 88)
    ]


class V4L2RequestBuffers(ctypes.Structure):
    _fields_ = [
        ("count", ctypes.c_uint32),
        ("type", ctypes.c_uint32),
        ("memory", ctypes.c_uint32),
        ("capability", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


# ---- ioctl number encoding (mirror of linux/_IOC macros) ----------------
_IOC_WRITE = 1
_IOC_READ = 2
_IOC_SIZESHIFT = 16
_IOC_DIRSHIFT = 30
_IOC_TYPEBYTE = 0x56  # 'V'


def _ioc(direction, nr, size):
    return ((direction << _IOC_DIRSHIFT) | (size << _IOC_SIZESHIFT)
            | (_IOC_TYPEBYTE << 8) | nr)


def _ior(nr, size):
    return _ioc(_IOC_READ, nr, size)


def _iowr(nr, size):
    return _ioc(_IOC_READ | _IOC_WRITE, nr, size)


def _iow(nr, size):
    return _ioc(_IOC_WRITE, nr, size)


IOCTL = {
    "QUERYCAP": _ior(VIDIOC_QUERYCAP_NR, 104),
    "G_FMT": _iowr(VIDIOC_G_FMT_NR, 208),
    "S_FMT": _iowr(VIDIOC_S_FMT_NR, 208),
    "REQBUFS": _iowr(VIDIOC_REQBUFS_NR, 20),
    "QUERYBUF": _iowr(VIDIOC_QUERYBUF_NR, 88),
    "QBUF": _iowr(VIDIOC_QBUF_NR, 88),
    "DQBUF": _iowr(VIDIOC_DQBUF_NR, 88),
    "STREAMON": _iow(VIDIOC_STREAMON_NR, 4),
    "STREAMOFF": _iow(VIDIOC_STREAMOFF_NR, 4),
}

FMT_SIZE = 208
FMT_PIX_MP_WIDTH = 8
FMT_PIX_MP_HEIGHT = 12
FMT_PIX_MP_PIXELFORMAT = 16
FMT_PIX_MP_FIELD = 20
FMT_PLANE0_SIZEIMAGE = 28  # plane_fmt[0]: sizeimage first, then bytesperline
FMT_PLANE0_BYTESPERLINE = 32
FMT_PIX_MP_NUM_PLANES = 188


_STAGE = ["init"]


def xioctl(fd, name, arg):
    """ioctl with EINTR retry; raises OSError otherwise (stage-tagged)."""
    while True:
        try:
            fcntl.ioctl(fd, IOCTL[name], arg, True)
            return
        except OSError as exc:
            exc.stage = f"{_STAGE[0]}/{name}"  # type: ignore[attr-defined]
            if exc.errno == errno.EINTR:
                continue
            raise


def main() -> int:
    class FmtRefused(Exception):
        """S_FMT came back with an unexpected format (summary still written)."""
    ap = argparse.ArgumentParser(
        description="per-frame V4L2 MPLANE liveness instrument")
    ap.add_argument("--frames", type=int, default=800)
    ap.add_argument("--seconds", type=float, default=0.0,
                    help="if >0, stop after this many seconds")
    ap.add_argument("--dir", default="/var/tmp/sp11-cam")
    ap.add_argument("--video", default="/dev/video0")
    ap.add_argument("--dq-timeout", type=float, default=5.0)
    args = ap.parse_args()
    if args.frames < 1:
        ap.error("--frames must be >= 1")
    if args.dq_timeout <= 0:
        ap.error("--dq-timeout must be > 0")

    os.makedirs(args.dir, exist_ok=True)
    runid = (time.strftime("%Y%m%d-%H%M%S")
             + f"-{time.monotonic_ns() % 1_000_000:06d}")
    base = os.path.join(args.dir, f"liveness-{runid}")
    csv_path = f"{base}.csv"
    json_path = f"{base}.json"
    raw_path = f"{base}.raw"

    summary = {
        "runid": runid,
        "video": args.video,
        "wanted_frames": args.frames,
        "seconds_budget": args.seconds,
        "dq_timeout": args.dq_timeout,
        "raw_path": raw_path,
        "csv_path": csv_path,
        "json_path": json_path,
        "outcome": "unknown",
        "frames_delivered": 0,
        "run_seconds": 0.0,
        "frames_per_second": 0.0,
        "stall_at_frame_idx": -1,
        "stall_at_mono_s": -1.0,
        "last_live_sequence": -1,
        "first_gap_prev_seq": -1,
        "first_gap_frame_idx": -1,
        "frozen_repeat_suspect": False,
        "format": None,
        "error": None,
    }

    buf_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
    written_total = 0
    csvf = open(csv_path, "w")  # closed in finally
    csvf.write("idx,mono_s,seq,bytesused,v4l2_ts_s\n")
    fd = -1
    streaming = False
    maps = []
    t0 = time.monotonic_ns()
    last_mono = t0
    frames = []
    sizeimage = 0
    out = None
    try:
        fd = os.open(args.video, os.O_RDWR | os.O_NONBLOCK)
        cap = (ctypes.c_ubyte * 104)()
        xioctl(fd, "QUERYCAP", cap)
        driver = bytes(cap[0:16]).split(b"\0")[0].decode()

        # --- set format (MPLANE) --------------------------------------
        fmt = (ctypes.c_ubyte * FMT_SIZE)()
        struct.pack_into("<I", fmt, 0, buf_type)
        struct.pack_into("<4I", fmt, FMT_PIX_MP_WIDTH,
                         3840, 2640, PIX_FMT_SRGGB10P, V4L2_FIELD_NONE)
        struct.pack_into("<I", fmt, FMT_PIX_MP_NUM_PLANES, 1)
        xioctl(fd, "S_FMT", fmt)
        w, h, pix, field = struct.unpack_from("<4I", fmt,
                                              FMT_PIX_MP_WIDTH)
        bpl = struct.unpack_from("<I", fmt, FMT_PLANE0_BYTESPERLINE)[0]
        sizeimage = struct.unpack_from("<I", fmt, FMT_PLANE0_SIZEIMAGE)[0]
        # NOTE: kernel does NOT reliably write back pix_mp.num_planes at
        # offset 188 (observed garbage 0x01010001 there); the driver is
        # single-plane, the REQBUFS/QUERYBUF/QBUF/DQBUF plane count is
        # hardcoded 1 (verified against strace of working v4l2-ctl runs).
        nplanes = 1
        fmt_line = (f"format({driver}): {w}x{h} pix=0x{pix:08x} "
                    f"bpl={bpl} sizeimage={sizeimage} planes={nplanes}")
        print(fmt_line)
        summary["format"] = {
            "width": w, "height": h, "pixelformat": pix, "field": field,
            "bytesperline": bpl, "sizeimage": sizeimage,
            "num_planes": nplanes,
        }
        if pix != PIX_FMT_SRGGB10P:
            summary["outcome"] = "fmt-refused"
            summary["error"] = fmt_line
            print("FATAL: unexpected format:", fmt_line, file=sys.stderr)
            raise FmtRefused(fmt_line)
        if bpl not in (4800, 4816):
            # accept both known line layouts (CSID crop version-dependent)
            print(f"NOTE: unexpected bytesperline {bpl} (want 4800/4816) — "
                  "continuing", file=sys.stderr)

        # --- request + mmap buffers ------------------------------------
        _STAGE[0] = "reqbufs"
        rb = V4L2RequestBuffers()
        rb.count = 4
        rb.type = buf_type
        rb.memory = V4L2_MEMORY_MMAP
        xioctl(fd, "REQBUFS", rb)
        if rb.count < 2:
            raise RuntimeError(f"REQBUFS gave only {rb.count} buffers")

        plane_arrs = [V4L2Plane * 1 for _ in range(rb.count)]
        _STAGE[0] = "querybuf"
        for i in range(rb.count):
            b = V4L2Buffer()
            b.index = i
            b.type = buf_type
            b.memory = V4L2_MEMORY_MMAP
            b.length = nplanes
            pa = plane_arrs[i]()
            b.planes = ctypes.cast(pa, ctypes.c_void_p)
            xioctl(fd, "QUERYBUF", b)
            map_offset = struct.unpack_from(
                "<Q", pa, 8)[0] & 0xFFFFFFFF  # m.mem_offset
            maps.append(mmap.mmap(fd, pa[0].length, offset=map_offset))

        def qbuf(i):
            _STAGE[0] = "qbuf"
            b = V4L2Buffer()
            b.index = i
            b.type = buf_type
            b.memory = V4L2_MEMORY_MMAP
            b.length = nplanes
            pa = plane_arrs[i]()
            for p in pa:
                p.bytesused = 0
                p.data_offset = 0
            b.planes = ctypes.cast(pa, ctypes.c_void_p)
            xioctl(fd, "QBUF", b)

        for i in range(rb.count):
            qbuf(i)

        # --- stream ----------------------------------------------------
        _STAGE[0] = "streamon"
        typ = ctypes.c_int(buf_type)
        xioctl(fd, "STREAMON", typ)
        streaming = True

        def buf_for(i):
            _STAGE[0] = "dqbuf"
            b = V4L2Buffer()
            b.index = i
            b.type = buf_type
            b.memory = V4L2_MEMORY_MMAP
            b.length = nplanes
            pa = plane_arrs[i]()
            # bind THE SAME array instance the kernel will write into;
            # quorum round1 F1 (critical): returning a second fresh array
            # read zeros -> bytesused 0, empty .raw, dead freeze detection
            b.planes = ctypes.cast(pa, ctypes.c_void_p)
            return b, pa

        prev_seq = -1
        deadline = t0 + int(args.seconds * 1e9) if args.seconds > 0 else None
        out = open(raw_path, "wb")
        eagain_run = 0
        idx = 0
        try:
            while idx < args.frames:
                if deadline is not None and time.monotonic_ns() >= deadline:
                    summary["outcome"] = "seconds-budget-end"
                    break
                ready, _, _ = select.select([fd], [], [], args.dq_timeout)
                now_mono = time.monotonic_ns()
                if not ready:
                    summary["outcome"] = "stall-no-buffer"
                    summary["stall_at_frame_idx"] = idx - 1
                    summary["stall_at_mono_s"] = (now_mono - t0) / 1e9
                    print(f"STALL: no new buffer within {args.dq_timeout}s "
                          f"after frame idx {idx - 1} (seq {prev_seq}, "
                          f"t={(now_mono - t0) / 1e9:.3f}s)")
                    break
                b, pa = buf_for(idx % rb.count)
                try:
                    xioctl(fd, "DQBUF", b)
                except OSError as exc:
                    if exc.errno == errno.EAGAIN:
                        # readiness race (O_NONBLOCK fd); retry via select
                        eagain_run += 1
                        if eagain_run < 10:
                            continue
                    summary["outcome"] = "dqbuf-error"
                    summary["error"] = (
                        f"DQBUF failed at frame {idx}:"
                        f" {errno.errorcode.get(exc.errno, exc.errno)}"
                        f" ({exc.errno})")
                    print("DQBUF error:", summary["error"])
                    break
                eagain_run = 0
                mono = time.monotonic_ns()
                seq = b.sequence
                used = pa[0].bytesused
                v4l2_ts = b.ts_sec + b.ts_usec / 1e6
                if prev_seq >= 0 and seq != (prev_seq + 1) & 0xFFFFFFFF:
                    if summary["first_gap_prev_seq"] < 0:
                        summary["first_gap_prev_seq"] = prev_seq
                        summary["first_gap_frame_idx"] = idx
                    print(f"SEQ GAP: idx {idx - 1} seq {prev_seq} -> seq "
                          f"{seq} at t={(mono - t0) / 1e9:.3f}s")
                out.write(memoryview(maps[b.index])[:used])
                written_total += used
                if len(frames) > 2 and seq == frames[-1][2] and used > 0:
                    summary["frozen_repeat_suspect"] = True
                csvf.write(f"{idx},{(mono - t0) / 1e9:.6f},{seq},{used},"
                           f"{v4l2_ts:.6f}\n")
                csvf.flush()  # quorum round1 F2: per-row flush vs SIGKILL
                frames.append((idx, mono, seq, used, v4l2_ts))
                prev_seq = seq
                last_mono = mono
                idx += 1
                qbuf(b.index)
            else:
                summary["outcome"] = "clean-complete"
        finally:
            # quorum round1 F3/F4: never lose the raw tail on error paths
            if out is not None and not out.closed:
                out.flush()
                out.close()

        if streaming:
            typ = ctypes.c_int(buf_type)
            xioctl(fd, "STREAMOFF", typ)
            streaming = False
    except FmtRefused:
        pass  # outcome/error already recorded; summary written below
    except (OSError, RuntimeError) as exc:
        stage = getattr(exc, "stage", "?")
        summary["error"] = f"{stage}: {exc}"
        summary["outcome"] = "fatal"
        print("FATAL:", summary["error"], file=sys.stderr)
    except BaseException as exc:  # quorum r2: unexpected excs still record
        summary["error"] = f"{type(exc).__name__}: {exc}"
        summary["outcome"] = "fatal"
        print("FATAL (unexpected):", summary["error"], file=sys.stderr)
    finally:
        for mm in maps:
            mm.close()
        maps.clear()
        if fd >= 0:
            try:
                if streaming:
                    typ = ctypes.c_int(
                        V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
                    xioctl(fd, "STREAMOFF", typ)
            except OSError as exc:
                print("NOTE: STREAMOFF in cleanup failed:", exc,
                      file=sys.stderr)
            os.close(fd)
        csvf.close()

    wall = (last_mono - t0) / 1e9 if frames else 0.0
    summary["frames_delivered"] = len(frames)
    summary["run_seconds"] = wall
    summary["frames_per_second"] = (len(frames) / wall) if wall > 0 else 0.0
    summary["raw_bytes_written"] = written_total
    if frames:
        summary["last_live_sequence"] = frames[-1][2]

    print(f"csv: {csv_path} ({len(frames)} frames)")
    print(f"raw: {raw_path} ({written_total} bytes actually written)")
    print("summary:", json.dumps(summary))
    with open(json_path, "w") as jf:
        json.dump(summary, jf, indent=2)
    # rc 0 = success outcomes (clean run OR deliberate seconds budget end);
    # rc 2 = stall, dead pipe, fatal, refusal
    return 0 if summary["outcome"] in ("clean-complete",
                                       "seconds-budget-end") else 2


if __name__ == "__main__":
    sys.exit(main())
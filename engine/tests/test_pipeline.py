#!/usr/bin/env python3
# Copyright 2026 Auracaster contributors
# SPDX-License-Identifier: Apache-2.0
"""Audio pipeline tests for engine/auracaster_helper.py (no dongle needed).

Run:  python engine/tests/test_pipeline.py      (CI: job "engine")

1. Jitter buffer: PCM written in Core-Audio-sized chunks (512 frames) with a
   clock that drifts against the "radio" clock; FramePicker must deliver a
   continuous signal (no underruns in steady state, only single-sample slips).
2. LC3 round trip (needs the real lc3py): 1 kHz left / 1.5 kHz right sine,
   float32 interleaved like the app's FIFO → ring → encoder → split per BIS →
   decoder per BIS. Checks frequency, SNR and channel separation.
3. Engine main loop against a fake controller that completes one SDU per BIS
   per ISO interval (controller-clocked pacing), fed through a real FIFO by a
   writer thread at the Mac's (drifting) clock, like the app does.
"""

from __future__ import annotations

import array
import asyncio
import math
import os
import pathlib
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import auracaster_helper as h  # noqa: E402  pylint: disable=wrong-import-position

RATE = 48000
FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    print(('  ok   ' if condition else '  FAIL ') + message)
    if not condition:
        FAILURES.append(message)


def sine_stereo(start: int, count: int, f_left=1000.0, f_right=1500.0, amp=0.5) -> bytes:
    data = array.array('f')
    for n in range(start, start + count):
        t = n / RATE
        data.append(amp * math.sin(2 * math.pi * f_left * t))
        data.append(amp * math.sin(2 * math.pi * f_right * t))
    return data.tobytes()


def goertzel_power(samples, freq: float, rate: int) -> float:
    k = 2 * math.cos(2 * math.pi * freq / rate)
    s1 = s2 = 0.0
    for x in samples:
        s0 = x + k * s1 - s2
        s2, s1 = s1, s0
    return s1 * s1 + s2 * s2 - k * s1 * s2


def snr_db(samples, freq: float, rate: int) -> float:
    """Least-squares sine fit at `freq`; residual = noise + distortion."""
    n = len(samples)
    sin_sum = cos_sum = 0.0
    for i, x in enumerate(samples):
        sin_sum += x * math.sin(2 * math.pi * freq * i / rate)
        cos_sum += x * math.cos(2 * math.pi * freq * i / rate)
    a, b = 2 * sin_sum / n, 2 * cos_sum / n
    residual = 0.0
    signal = 0.0
    for i, x in enumerate(samples):
        fit = a * math.sin(2 * math.pi * freq * i / rate) + b * math.cos(2 * math.pi * freq * i / rate)
        residual += (x - fit) ** 2
        signal += fit**2
    return 10 * math.log10(max(signal, 1e-12) / max(residual, 1e-12))


# -----------------------------------------------------------------------------
def test_jitter_buffer() -> None:
    print('jitter buffer / drift')
    bpf = 8
    frame = 480
    for drift_ppm in (-300, 0, 300):
        ring = h.PcmRing(bpf, RATE // 4)
        picker = h.FramePicker(ring, frame, RATE * 30 // 1000)
        written = 0
        out = array.array('f')
        mac_time = 0.0
        radio_frames = 3000  # 30 s
        for i in range(radio_frames):
            radio_time = (i + 1) * frame / RATE
            # Core Audio delivers 512-frame chunks on its own (drifting) clock
            while mac_time <= radio_time:
                ring.write(sine_stereo(written, 512))
                written += 512
                mac_time += 512 / (RATE * (1 + drift_ppm / 1e6))
            out.frombytes(picker.next())
        left = out[0::2]
        steady = left[RATE:]  # after start-up buffering
        # a 1 kHz sine at amp 0.5 moves <= 0.066 per sample; a slip moves ~2x that
        jumps = sum(1 for i in range(len(steady) - 1) if abs(steady[i + 1] - steady[i]) > 0.08)
        slips = picker.slips_dropped + picker.slips_inserted
        expected = abs(drift_ppm) * 1e-6 * written
        check(picker.underruns == 0, f'{drift_ppm:+d} ppm: no underruns (got {picker.underruns})')
        check(ring.dropped_frames == 0, f'{drift_ppm:+d} ppm: no overrun drops (got {ring.dropped_frames})')
        check(jumps <= slips + 1, f'{drift_ppm:+d} ppm: no gaps besides sample slips ({jumps} jumps)')
        check(
            slips <= expected * 1.5 + 30,
            f'{drift_ppm:+d} ppm: slips {slips} for {expected:.0f} samples of drift',
        )
        print(
            f'         slips -{picker.slips_dropped}/+{picker.slips_inserted}, '
            f'fill {ring.frames * 1000 / RATE:.1f} ms'
        )


# -----------------------------------------------------------------------------
def test_lc3_roundtrip() -> None:
    print('LC3 round trip (ring → encode → per-BIS decode)')
    lc3 = h.lc3
    if lc3 is None or not hasattr(lc3, 'Decoder'):
        print('  skip (real lc3py not installed)')
        return
    for frame_us, bitrate, codec_rate in ((10000, 96000, 48000), (7500, 80000, 48000), (10000, 48000, 24000)):
        encoder = lc3.Encoder(
            frame_duration_us=frame_us, sample_rate_hz=codec_rate, num_channels=2,
            input_sample_rate_hz=RATE,
        )
        frame_samples = encoder.get_frame_samples()
        frame_size = encoder.get_frame_bytes(bitrate)
        decoders = [lc3.Decoder(frame_us, codec_rate) for _ in range(2)]
        ring = h.PcmRing(8, RATE)
        picker = h.FramePicker(ring, frame_samples, frame_samples)
        written = 0
        decoded: list[list[float]] = [[], []]
        for _ in range(int(1.0 * 1e6 / frame_us)):
            while ring.frames < 2 * frame_samples:
                ring.write(sine_stereo(written, 512))
                written += 512
            pcm = picker.next()
            data = encoder.encode(pcm, num_bytes=2 * frame_size, bit_depth=None)
            for index in range(2):
                sdu = data[index * frame_size : (index + 1) * frame_size]
                decoded[index].extend(decoders[index].decode(sdu, bit_depth=None))
        label = f'{frame_us / 1000:g} ms {codec_rate // 1000} kHz {frame_size} B'
        skip = codec_rate // 10  # codec delay / start-up
        left, right = decoded[0][skip:], decoded[1][skip:]
        check(len(left) > codec_rate // 2, f'{label}: decoded {len(left)} samples')
        snr_left = snr_db(left[: codec_rate // 4], 1000, codec_rate)
        snr_right = snr_db(right[: codec_rate // 4], 1500, codec_rate)
        check(snr_left > 25, f'{label}: BIS 1 = 1 kHz, SNR {snr_left:.1f} dB')
        check(snr_right > 25, f'{label}: BIS 2 = 1.5 kHz, SNR {snr_right:.1f} dB')
        separation = 10 * math.log10(
            goertzel_power(left[:4800], 1000, codec_rate)
            / max(goertzel_power(left[:4800], 1500, codec_rate), 1e-12)
        )
        check(separation > 30, f'{label}: channel separation {separation:.0f} dB')


# -----------------------------------------------------------------------------
class FakeStream:
    """Stands in for bumble IsoPacketStream: controller consumes 1 SDU / interval."""

    def __init__(self, interval_s: float, depth: int, log: list) -> None:
        self.interval = interval_s
        self.depth = depth
        self.queue = 0
        self.log = log
        self.next_event = None
        self.late = 0
        self.sent = 0

    async def _drain(self) -> None:
        now = time.monotonic()
        if self.next_event is None:
            self.next_event = now + self.interval
        while self.next_event <= now:
            if self.queue:
                self.queue -= 1
                self.sent += 1
            else:
                self.late += 1  # ISO event without data = audible gap
            self.next_event += self.interval

    async def write(self, sdu: bytes) -> None:
        while True:
            await self._drain()
            if self.queue < self.depth:
                break
            await asyncio.sleep(max(0.0005, self.next_event - time.monotonic()))
        self.queue += 1
        self.log.append(len(sdu))


def test_engine_loop() -> None:
    print('engine loop (FIFO writer thread → ring → encoder → controller-paced streams)')
    if h.lc3 is None:
        print('  skip (lc3 not installed)')
        return
    tmp = tempfile.mkdtemp()
    fifo = os.path.join(tmp, 'pcm')
    os.mkfifo(fifo)

    async def run() -> None:
        engine = h.Engine('virtual', 'Auracaster', 'F0:F1:F2:F3:F4:F5')
        streams: list[FakeStream] = []
        log: list = []
        preset = h.Preset(10000, 96000, 40000, 4, 65)

        class FakeHost:
            iso_packet_queue = None

        class FakeDevice:
            supports_le_periodic_advertising = True
            public_address = 'F0:F1:F2:F3:F4:F5'
            host = FakeHost()

            def supports_le_features(self, _features) -> bool:
                return True

        engine.device = FakeDevice()  # type: ignore

        async def fake_setup(device, codec_rate, channels, frame_size):  # noqa: ARG001
            return ['bis1', 'bis2']

        async def fake_teardown():
            pass

        engine._setup_radio = fake_setup  # type: ignore  # pylint: disable=protected-access
        engine._teardown_radio = fake_teardown  # type: ignore  # pylint: disable=protected-access
        original = h.bumble.device.IsoPacketStream
        h.bumble.device.IsoPacketStream = lambda link, depth: streams.append(  # type: ignore
            FakeStream(preset.frame_duration_us / 1e6, depth, log)
        ) or streams[-1]
        stop = threading.Event()

        def writer() -> None:
            fd = None
            while fd is None and not stop.is_set():
                try:
                    fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                except OSError:
                    time.sleep(0.01)
            written = 0
            t0 = time.monotonic()
            mac_rate = RATE * (1 + 250e-6)  # Mac clock 250 ppm fast
            while not stop.is_set():
                due = int((time.monotonic() - t0) * mac_rate)
                while written + 512 <= due:
                    try:
                        os.write(fd, sine_stereo(written, 512))
                    except BlockingIOError:
                        pass
                    written += 512
                time.sleep(0.002)
            os.close(fd)

        thread = threading.Thread(target=writer, daemon=True)
        try:
            await engine.start(
                h.BroadcastConfig.from_json({'name': 'Test'}),
                h.AudioConfig(input=f'fifo:{fifo}', format='float32le,48000,2'),
                preset,
            )
            thread.start()
            await asyncio.sleep(4.0)
            stats = engine.last_stats
        finally:
            stop.set()
            await engine.stop()
            h.bumble.device.IsoPacketStream = original  # type: ignore
        late = [s.late for s in streams]
        sent = [s.sent for s in streams]
        print(f'         stats {stats}')
        check(engine.frames_sent > 350, f'frames sent in 4 s: {engine.frames_sent}')
        check(all(x <= 2 for x in late), f'ISO events without data after start-up: {late}')
        check(sent[0] == sent[1], f'both BIS fed equally: {sent}')
        check(stats.get('underruns', 99) <= 1, f"underruns: {stats.get('underruns')}")
        check(stats.get('encode_ms_max', 99) < 8, f"encode time max {stats.get('encode_ms_max')} ms")

    asyncio.run(run())


if __name__ == '__main__':
    test_jitter_buffer()
    test_lc3_roundtrip()
    test_engine_loop()
    print('FAILED:' if FAILURES else 'all pipeline tests passed', *FAILURES, sep='\n  ')
    sys.exit(1 if FAILURES else 0)

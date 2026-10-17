#!/usr/bin/env python3
# Copyright 2026 Auracaster contributors
# Based on bumble/apps/auracast.py, Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Auracaster engine helper.

Headless Bumble process controlled by the Auracaster macOS app.

Control channel: JSON Lines over stdin (commands) / stdout (events).
Logs go to stderr only, so stdout stays a clean protocol stream.

Audio: raw interleaved PCM read from an audio input. Supported inputs:
    fifo:/path/to/pipe   named pipe written by the app (current transport)
    file:/path/to.wav    WAV file (looped), handy for testing
    silence              generated digital silence (no audio needed)

Audio clocking (protocol 2 / v0.1.1): the controller clocks the broadcast.
PCM from the input lands in a jitter buffer (PcmRing, ~30 ms target); the
encoder takes one frame whenever the controller has completed an SDU (bumble
IsoPacketStream, 3-4 SDUs queued per BIS). Underrun -> silence frame,
overrun -> oldest PCM dropped, clock drift -> single-sample slips. LC3
encoding runs on a worker thread. A failed start/teardown triggers a
controller reset (close + reopen the transport = HCI_Reset; firmware >= 0.1.1
also reboots when the port closes).

Commands (one JSON object per line):
    {"cmd": "start", "id": 1, "broadcast": {...}, "audio": {...}, "preset": {...}}
        audio:  {"input": "fifo:/tmp/x.pcm", "format": "float32le,48000,2",
                 "record_path": "/path/debug.wav"}   (optional WAV of the encoder input)
        preset: {"frame_duration_us": 10000, "bitrate": 96000,
                 "presentation_delay_us": 40000, "rtn": 4,
                 "max_transport_latency_ms": 65, "sample_rate_hz": 48000,
                 "prefill": 0, "jitter_ms": 0}        (0 = automatic)
        A start while live restarts the broadcast with the new settings.
    {"cmd": "stop", "id": 2}
    {"cmd": "status", "id": 3}
    {"cmd": "scan", "id": 4, "duration": 5.0}
    {"cmd": "connect", "id": 5}            open the dongle now (status only)
    {"cmd": "controller_info", "id": 6}    diagnostics ("Dongle prüfen")
    {"cmd": "shutdown", "id": 7}

Events (one JSON object per line):
    {"event": "ready", "version": "...", "protocol": 2, "transport": "...", "lc3": true}
    {"event": "ack", "id": 1}
    {"event": "error", "id": 1, "message": "..."}
    {"event": "fatal", "message": "...", "traceback": "..."}   (helper exits afterwards)
    {"event": "status", "state": "idle|starting|live|stopping|error", ...}
    {"event": "level", "peak": [l, r], "rms": [l, r]}
    {"event": "stats", "sdus_per_s": 200.0, "iso_completed_per_s": 200.0,
     "iso_pending": 6, "underruns": 0, "overrun_frames": 0, "slips_dropped": 0,
     "slips_inserted": 0, "buffer_ms": 30.2, "encode_ms_avg": 0.3, ...}   (1 Hz)
    {"event": "controller_info", "connected": true, "hci_version": "...",
     "le_features": [...], "iso_broadcaster": true, "serial_ports": [...], ...}
    {"event": "log", "level": "warning", "message": "..."}
    {"event": "broadcast_found", "name": "...", "broadcast_id": 123, ...}
    {"event": "scan_complete", "count": 3}

Controller transport (--transport, default "auto"):
    auto                 look for the Auracaster dongle (firmware/, Zephyr HCI H4 over
                         USB CDC ACM, product string "Auracaster Dongle", 2fe3:0004)
                         and open it as serial:/dev/cu.usbmodem...,resync;
                         falls back to usb:0 when no dongle is found
    serial:/dev/cu.usbmodemXXXX[,resync]   the dongle (or any H4 UART controller)
    usb:0 / usb:VID:PID  a USB HCI (H2) controller. NOTE: Zephyr's hci_usb sample
                         has no ISO data path, it cannot be used for Auracast.

Example (manual test without the app):
    mkfifo /tmp/auracaster.pcm
    python engine/auracaster_helper.py --transport auto
    > {"cmd":"start","id":1,"audio":{"input":"silence"}}
"""

from __future__ import annotations

import argparse
import array
import asyncio
import concurrent.futures
import contextlib
import dataclasses
import errno
import functools
import json
import logging
import math
import os
import pathlib
import secrets
import sys
import threading
import time
import traceback
from collections.abc import AsyncGenerator
from typing import Any

HELPER_VERSION = '0.1.3'
PROTOCOL_VERSION = 2

# -----------------------------------------------------------------------------
# Protocol output (defined before the Bumble imports so that even an incomplete
# engine installation can report a readable "fatal" event to the app)
# -----------------------------------------------------------------------------
_stdout_lock = threading.Lock()


def emit(event: str, **fields: Any) -> None:
    """Write one event line to stdout (thread-safe, flushed)."""
    payload = {'event': event, **fields}
    line = json.dumps(payload, separators=(',', ':'), default=str)
    with _stdout_lock:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()


def emit_fatal(message: str, error: BaseException | None = None) -> None:
    """Last words before exiting: message + traceback tail for the app's alert."""
    tb = ''
    if error is not None:
        tb = ''.join(traceback.format_exception(type(error), error, error.__traceback__))
        sys.stderr.write(tb)
        sys.stderr.flush()
    emit('fatal', message=message, traceback=tb[-4000:])


# Allow running straight from the repository checkout (engine/ is next to bumble/).
_REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
if (_REPO_ROOT / 'bumble' / '__init__.py').exists() and str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

try:
    import lc3  # type: ignore  # pylint: disable=E0401
except ImportError:  # pragma: no cover - reported at runtime as an event
    lc3 = None  # type: ignore

try:
    import bumble
    import bumble.device
    import bumble.transport
    from bumble import core, data_types, gatt, hci
    from bumble.audio import io as audio_io
    from bumble.company_ids import COMPANY_IDENTIFIERS
    from bumble.profiles import bap, le_audio, pbp
except Exception as _import_error:  # pragma: no cover - broken/old engine install
    if __name__ == '__main__' and '--help' not in sys.argv and '-h' not in sys.argv:
        emit_fatal(
            'Die Engine-Installation ist unvollständig oder veraltet '
            f'({type(_import_error).__name__}: {_import_error}). '
            'Bitte in Auracaster unter Einstellungen → „Engine neu einrichten“ wählen.',
            _import_error,
        )
        sys.exit(3)
    raise

DEFAULT_DEVICE_NAME = 'Auracaster'
DEFAULT_DEVICE_ADDRESS = 'F0:F1:F2:F3:F4:F5'
DEFAULT_DATA_DIR = pathlib.Path.home() / 'Library' / 'Application Support' / 'Auracaster'

logger = logging.getLogger('auracaster.helper')


# -----------------------------------------------------------------------------
# Controller transport
# -----------------------------------------------------------------------------
# USB identity of the Auracaster dongle firmware (firmware/prj.conf)
DONGLE_PRODUCT = 'Auracaster Dongle'
DONGLE_VID_PID = (0x2FE3, 0x0004)


def list_serial_ports() -> list[dict[str, Any]]:
    """All serial ports with their USB identity (for diagnostics and auto-detection)."""
    try:
        from serial.tools import list_ports  # type: ignore  # pylint: disable=E0401
    except ImportError:  # pragma: no cover
        return []
    ports = []
    for port in list_ports.comports():
        ports.append(
            {
                'device': port.device,
                'product': port.product,
                'manufacturer': port.manufacturer,
                'vid': f'{port.vid:04x}' if port.vid is not None else None,
                'pid': f'{port.pid:04x}' if port.pid is not None else None,
                'serial': port.serial_number,
            }
        )
    return ports


def find_dongle_serial_port() -> str | None:
    """Return the serial device of a connected Auracaster dongle, if any.

    Preference: product string "Auracaster Dongle" > 2fe3:0004 > any Zephyr
    (VID 2fe3) CDC ACM port > any /dev/cu.usbmodem* port.
    """
    candidates: list[tuple[int, str]] = []
    for port in list_serial_ports():
        product = port['product'] or ''
        device = port['device']
        # macOS: use the call-out device, /dev/tty.* blocks on carrier detect
        if device.startswith('/dev/tty.usbmodem'):
            device = '/dev/cu.' + device[len('/dev/tty.') :]
        if product.startswith('Auracaster Repeater'):
            continue  # the standalone repeater has no HCI
        if product.startswith(DONGLE_PRODUCT):
            rank = 0
        elif (port['vid'], port['pid']) == ('%04x' % DONGLE_VID_PID[0], '%04x' % DONGLE_VID_PID[1]):
            rank = 1
        elif port['vid'] == '%04x' % DONGLE_VID_PID[0]:
            rank = 2
        elif 'usbmodem' in device:
            rank = 3
        else:
            continue
        candidates.append((rank, device))
    return sorted(candidates)[0][1] if candidates else None


# Auracaster firmware identity (firmware/common/auracaster_fw.h, >= 0.1.2)
AURA_OP_READ_INFO = 0xFF50
AURA_ROLES = {1: 'dongle', 2: 'repeater'}
AURA_VARIANTS = {1: 's140v6', 2: 's140v7', 3: 'nosd'}


def parse_auracaster_info(data: bytes | None) -> dict[str, Any] | None:
    """Return parameters of HCI vendor command 0xFF50 (status byte first)."""
    if data is None or len(data) < 11 or data[0] != 0 or data[1:5] != b'AURA':
        return None
    role = AURA_ROLES.get(data[6])
    if role is None:
        return None
    info: dict[str, Any] = {
        'firmware_role': role,
        'firmware_variant': AURA_VARIANTS.get(data[7]),
        'firmware_version': f'{data[8]}.{data[9]}.{data[10]}',
        'firmware_flags': data[11] if len(data) > 11 else 0,
    }
    if len(data) >= 16:
        info['firmware_load_address'] = '0x%x' % int.from_bytes(data[12:16], 'little')
    return info


async def read_auracaster_info(host: Any) -> dict[str, Any]:
    """Ask the dongle who it is. Firmware <= 0.1.1 answers "Unknown HCI Command"."""
    try:
        response = await host.send_command(
            hci.HCI_Command(b'', op_code=AURA_OP_READ_INFO), response_timeout=2.0
        )
    except Exception as error:  # pylint: disable=broad-except
        logger.info('no Auracaster firmware identity: %s', error)
        return {'firmware_legacy': True}
    parameters = getattr(response, 'return_parameters', None)
    data = getattr(parameters, 'data', parameters)
    info = parse_auracaster_info(bytes(data) if isinstance(data, (bytes, bytearray)) else None)
    if info is None:
        return {'firmware_legacy': True}
    logger.info(
        'Auracaster firmware %s (%s, %s)',
        info['firmware_version'],
        info['firmware_role'],
        info['firmware_variant'],
    )
    return info


def resolve_transport(spec: str) -> str:
    """Map "auto" to the dongle's serial port (with HCI resync), else usb:0."""
    if spec != 'auto':
        return spec
    device = find_dongle_serial_port()
    if device is None:
        logger.warning(
            'no Auracaster dongle found (serial ports: %s), falling back to usb:0',
            json.dumps(list_serial_ports()) or 'none',
        )
        return 'usb:0'
    logger.info('Auracaster dongle: %s', device)
    return f'serial:{device},resync'


OPEN_RETRY_SECONDS = 6.0


def classify_open_error(error: BaseException) -> str | None:
    """'busy' (EBUSY), 'gone' (ENOENT/ENXIO: port vanished while the dongle
    reboots) or None (do not retry)."""
    text = str(error)
    code = getattr(error, 'errno', None)
    if code == errno.EBUSY or 'Resource busy' in text or 'Errno 16' in text:
        return 'busy'
    if code in (errno.ENOENT, errno.ENXIO) or 'No such file' in text or 'Errno 2]' in text or 'Errno 6]' in text:
        return 'gone'
    return None


def serial_port_path(transport_name: str) -> str | None:
    """'/dev/cu.usbmodem2101' for 'serial:/dev/cu.usbmodem2101,resync'."""
    if not transport_name.startswith('serial:'):
        return None
    return transport_name[len('serial:'):].split(',', 1)[0] or None


async def wait_for_serial_port(transport_name: str, deadline: float, poll: float = 0.1) -> bool:
    """Waits until the serial port exists again (plus a short settle time)."""
    path = serial_port_path(transport_name)
    if path is None:
        await asyncio.sleep(0.5)
        return False
    while time.monotonic() < deadline:
        if os.path.exists(path):
            await asyncio.sleep(0.3)  # let the CDC-ACM device finish enumerating
            return True
        await asyncio.sleep(poll)
    return False


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
@dataclasses.dataclass
class Preset:
    frame_duration_us: int = 10000  # 7500 or 10000
    bitrate: int = 80000  # per channel, bits/s
    presentation_delay_us: int = 40000
    rtn: int = 4
    max_transport_latency_ms: int = 65
    # LC3 codec sample rate; 0 = same as the PCM input. Lower than the input
    # (e.g. 24 kHz from 48 kHz capture) is resampled inside liblc3.
    sample_rate_hz: int = 0
    # SDUs kept queued in the controller per BIS (flow-control pacing), 0 = auto
    prefill: int = 0
    # Jitter buffer target between capture and encoder in ms, 0 = auto
    jitter_ms: int = 0
    # BIS packing in the BIG: 'sequential' (default) or 'interleaved'
    packing: str = 'sequential'

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> Preset:
        preset = cls(**{k: v for k, v in (data or {}).items() if k in cls.__dataclass_fields__})
        if preset.frame_duration_us not in (7500, 10000):
            raise ValueError('frame_duration_us must be 7500 or 10000')
        if preset.sample_rate_hz not in (0, 16000, 24000, 32000, 48000):
            raise ValueError('sample_rate_hz must be 16000, 24000, 32000 or 48000')
        if preset.packing not in ('sequential', 'interleaved'):
            raise ValueError('packing must be sequential or interleaved')
        if not 0 <= preset.jitter_ms <= 250:
            raise ValueError('jitter_ms must be 0..250')
        return preset

    @property
    def prefill_sdus(self) -> int:
        # ~30 ms of queued SDUs: survives Python/USB hiccups, adds little latency
        return self.prefill or (3 if self.frame_duration_us == 10000 else 4)

    @property
    def jitter_target_ms(self) -> int:
        return self.jitter_ms or 30

    @property
    def bap_frame_duration(self) -> bap.FrameDuration:
        return (
            bap.FrameDuration.DURATION_7500_US
            if self.frame_duration_us == 7500
            else bap.FrameDuration.DURATION_10000_US
        )


@dataclasses.dataclass
class BroadcastConfig:
    name: str = 'Auracaster'
    broadcast_id: int = 0  # 0 = random
    code: str | None = None  # Broadcast Code (encryption), None = open
    language: str | None = 'deu'  # ISO 639-3, as used by LE Audio metadata
    program_info: str | None = None
    public: bool = True

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> BroadcastConfig:
        config = cls(**{k: v for k, v in (data or {}).items() if k in cls.__dataclass_fields__})
        if not config.broadcast_id:
            config.broadcast_id = 1 + secrets.randbelow(0xFFFFFF)
        return config


@dataclasses.dataclass
class AudioConfig:
    input: str = 'silence'
    format: str = 'int16le,48000,2'
    # Debug: write the PCM exactly as it enters the LC3 encoder to this WAV file
    record_path: str | None = None

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> AudioConfig:
        return cls(**{k: v for k, v in (data or {}).items() if k in cls.__dataclass_fields__})


def broadcast_code_bytes(broadcast_code: str) -> bytes:
    """Same rules as apps/auracast.py: 0x-prefixed hex or UTF-8 string, 16 bytes."""
    if broadcast_code.startswith('0x'):
        value = bytes.fromhex(broadcast_code[2:])
        if len(value) != 16:
            raise ValueError('broadcast code must be 16 bytes')
        return bytes(reversed(value))
    value = broadcast_code.encode('utf-8')
    if len(value) > 16:
        raise ValueError('broadcast code must be <= 16 bytes')
    return value + bytes(16 - len(value))


# -----------------------------------------------------------------------------
# Audio inputs + jitter buffer
#
# Clocking (v0.1.1): the CONTROLLER clocks the broadcast. The producer only
# encodes the next frame when the controller has completed an SDU (HCI Number
# Of Completed Packets → bumble IsoPacketStream with a small queue), so the
# Mac's audio clock never paces the radio. Between the two clocks sits a PCM
# ring buffer (jitter buffer): underrun → silence frame, overrun → oldest data
# dropped, and slow drift is absorbed by slipping single samples.
# -----------------------------------------------------------------------------
class PcmRing:
    """Thread-safe byte FIFO for interleaved PCM frames (writer: reader thread)."""

    def __init__(self, bytes_per_frame: int, capacity_frames: int) -> None:
        self.bytes_per_frame = bytes_per_frame
        self.capacity = capacity_frames * bytes_per_frame
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self.dropped_frames = 0  # overrun (writer faster than the radio)
        self.written_frames = 0
        self.eof = False

    def write(self, data: bytes) -> None:
        with self._lock:
            self._buffer += data
            self.written_frames += len(data) // self.bytes_per_frame
            excess = len(self._buffer) - self.capacity
            if excess > 0:
                excess += (-excess) % self.bytes_per_frame  # whole frames only
                del self._buffer[:excess]
                self.dropped_frames += excess // self.bytes_per_frame

    @property
    def frames(self) -> int:
        with self._lock:
            return len(self._buffer) // self.bytes_per_frame

    def read(self, frames: int) -> bytes | None:
        size = frames * self.bytes_per_frame
        with self._lock:
            if len(self._buffer) < size:
                return None
            data = bytes(self._buffer[:size])
            del self._buffer[:size]
            return data

    def clear(self) -> None:
        with self._lock:
            self._buffer.clear()


class PcmSource:
    """Feeds a PcmRing from an audio input spec."""

    def __init__(self, config: AudioConfig) -> None:
        self.config = config
        self.pcm_format = audio_io.PcmFormat.from_str(config.format)
        self.ring: PcmRing | None = None
        self._thread: threading.Thread | None = None
        self._task: asyncio.Task | None = None
        self._stop = threading.Event()
        self._fd: int | None = None
        self._other: audio_io.AudioInput | None = None

    @property
    def bytes_per_frame(self) -> int:
        return self.pcm_format.channels * self.pcm_format.bytes_per_sample

    async def open(self, capacity_frames: int) -> audio_io.PcmFormat:
        spec = self.config.input
        if spec == 'stdin':
            raise ValueError('stdin is reserved for the JSON control channel; use fifo:')
        if spec.startswith('fifo:') or spec == 'silence':
            pcm_format = self.pcm_format
        else:
            # file:, device:, ... handled by Bumble (paced by the ring fill, see _feed)
            self._other = await audio_io.create_audio_input(spec, self.config.format)
            pcm_format = await self._other.open()
            self.pcm_format = pcm_format
        self.ring = PcmRing(self.bytes_per_frame, capacity_frames)
        if spec.startswith('fifo:'):
            path = spec[5:]
            if not os.path.exists(path):
                os.mkfifo(path)
            # O_RDWR never blocks on a FIFO and keeps it open when the app's writer
            # goes away (no EOF spin); we only ever read from it.
            self._fd = os.open(path, os.O_RDWR)
            self._thread = threading.Thread(target=self._read_fifo, name='pcm-reader', daemon=True)
            self._thread.start()
        elif self._other is not None:
            self._task = asyncio.create_task(self._feed())
        logger.info(
            'audio input %s: %s Hz, %d ch, %s',
            spec,
            pcm_format.sample_rate,
            pcm_format.channels,
            pcm_format.sample_type.name,
        )
        return pcm_format

    def _read_fifo(self) -> None:
        assert self.ring is not None and self._fd is not None
        import select  # pylint: disable=import-outside-toplevel

        while not self._stop.is_set():
            ready, _, _ = select.select([self._fd], [], [], 0.2)
            if not ready:
                continue
            try:
                data = os.read(self._fd, 65536)
            except OSError:
                break
            if data:
                self.ring.write(data)

    async def _feed(self) -> None:
        """Non-realtime inputs (files): keep the ring around half full."""
        assert self.ring is not None and self._other is not None
        chunk = max(1, self.pcm_format.sample_rate // 100)
        async for data in self._other.frames(chunk):
            while self.ring.frames > self.ring.capacity // self.ring.bytes_per_frame // 2:
                await asyncio.sleep(0.005)
            self.ring.write(data)
        self.ring.eof = True

    async def close(self) -> None:
        self._stop.set()
        if self._task:
            self._task.cancel()
            with contextlib.suppress(BaseException):
                await self._task
        if self._thread:
            self._thread.join(timeout=1)
        if self._fd is not None:
            with contextlib.suppress(OSError):
                os.close(self._fd)
            self._fd = None
        if self._other is not None:
            with contextlib.suppress(Exception):
                await self._other.aclose()


class WavRecorder:
    """Debug: PCM before the encoder → 16-bit WAV (written on the encoder thread)."""

    def __init__(self, path: str, pcm_format: audio_io.PcmFormat) -> None:
        import wave  # pylint: disable=import-outside-toplevel

        pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._float = pcm_format.sample_type == audio_io.PcmFormat.SampleType.FLOAT32
        self._wav = wave.open(path, 'wb')  # pylint: disable=consider-using-with
        self._wav.setnchannels(pcm_format.channels)
        self._wav.setsampwidth(2)
        self._wav.setframerate(pcm_format.sample_rate)
        self.path = path

    def write(self, pcm: bytes) -> None:
        if self._float:
            samples = array.array('f', pcm)
            pcm = array.array(
                'h', (int(max(-1.0, min(1.0, x)) * 32767) for x in samples)
            ).tobytes()
        self._wav.writeframes(pcm)

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self._wav.close()


class FramePicker:
    """Takes one encoder frame from the ring, absorbing clock drift.

    * Real clock drift (crystal ppm): fill above target+window → one sample
      dropped, below target-window → one sample repeated, at most one slip
      every `slip_spacing` frames (25/s at 10 ms – far above real drift, but
      a backlog can no longer be "slipped away" for 90 s like in v0.1.1).
    * Backlog after a stall (radio or host): fill above `flush_above`
      (2 × target + window) → jump straight back to the target once, with a
      short fade-in, instead of hundreds of slips per second.
    * Empty ring → silence frame (underrun) until the target fill is back.
    """

    FADE_SAMPLES = 64

    def __init__(
        self,
        ring: PcmRing,
        frame_samples: int,
        target_frames: int,
        channels: int = 2,
        float_samples: bool = True,
        sample_rate: int = 48000,
    ) -> None:
        self.ring = ring
        self.sample_rate = sample_rate
        self.frame_samples = frame_samples
        self.target = max(frame_samples, target_frames)
        # Core Audio writes in ~512-frame chunks: the instantaneous fill jumps by
        # that much, so drift is judged on a smoothed fill with a wide window.
        self.window = max(frame_samples, 512)
        self.flush_above = 2 * self.target + self.window
        self.slip_spacing = 4
        self.channels = channels
        self.float_samples = float_samples
        self.average: float | None = None
        self.silence = bytes(frame_samples * ring.bytes_per_frame)
        self.buffering = True
        self.underruns = 0
        self.slips_dropped = 0
        self.slips_inserted = 0
        self.flushes = 0
        self.flushed_frames = 0
        self._since_slip = 0
        self._fade_in = False

    def _fade(self, data: bytes) -> bytes:
        samples = array.array('f' if self.float_samples else 'h', data)
        frames = min(self.FADE_SAMPLES, len(samples) // self.channels)
        for frame in range(frames):
            gain = (frame + 1) / (frames + 1)
            for channel in range(self.channels):
                index = frame * self.channels + channel
                value = samples[index] * gain
                samples[index] = value if self.float_samples else int(value)
        return samples.tobytes()

    def next(self) -> bytes:
        data = self._next()
        if self._fade_in and data is not self.silence:
            self._fade_in = False
            return self._fade(data)
        return data

    def _next(self) -> bytes:
        fill = self.ring.frames
        n = self.frame_samples
        if self.buffering:
            if fill < self.target:
                return self.silence
            self.buffering = False
            self.average = float(fill)
            if fill > self.target + self.window:
                self.ring.read(fill - self.target)  # start at the target, not at a backlog
                fill = self.target
        if fill < n:
            self.underruns += 1
            self.buffering = True
            self._fade_in = True
            return self.silence
        assert self.average is not None
        if fill > self.flush_above:
            drop = fill - self.target
            self.ring.read(drop)
            self.flushes += 1
            self.flushed_frames += drop
            self.average = float(self.target)
            self._fade_in = True
            logger.warning(
                'jitter buffer backlog %.0f ms -> flushed back to %.0f ms',
                fill * 1000 / self.sample_rate,
                self.target * 1000 / self.sample_rate,
            )
            fill = self.ring.frames
            if fill < n:
                return self.silence
        self.average += 0.02 * (fill - self.average)  # ~0.5 s time constant
        self._since_slip += 1
        bpf = self.ring.bytes_per_frame
        if self._since_slip >= self.slip_spacing:
            if self.average > self.target + self.window and fill >= n + 1:
                data = self.ring.read(n + 1)
                if data is not None:
                    self.slips_dropped += 1
                    self.average -= 1
                    self._since_slip = 0
                    return data[:-bpf]
            if self.average < self.target - self.window // 2:
                data = self.ring.read(n - 1)
                if data is not None:
                    self.slips_inserted += 1
                    self.average += 1
                    self._since_slip = 0
                    return data + data[-bpf:]
        return self.ring.read(n) or self.silence


def measure_levels(pcm: bytes, pcm_format: audio_io.PcmFormat) -> tuple[list[float], list[float]]:
    """Per-channel peak and RMS in dBFS (cheap, pure Python)."""
    channels = pcm_format.channels
    if pcm_format.sample_type == audio_io.PcmFormat.SampleType.INT16:
        samples = array.array('h', pcm)
        scale = 1 / 32768.0
    else:
        samples = array.array('f', pcm)
        scale = 1.0
    peaks, rmss = [], []
    for channel in range(channels):
        chan = samples[channel::channels]
        if not chan:
            peaks.append(-120.0)
            rmss.append(-120.0)
            continue
        peak = max(abs(s) for s in chan) * scale
        rms = math.sqrt(sum(float(s) * s for s in chan) / len(chan)) * scale
        peaks.append(round(20 * math.log10(max(peak, 1e-6)), 1))
        rmss.append(round(20 * math.log10(max(rms, 1e-6)), 1))
    return peaks, rmss


# -----------------------------------------------------------------------------
# Engine
# -----------------------------------------------------------------------------
def _spec_version(value: int) -> str:
    try:
        return hci.SpecificationVersion(value).name
    except Exception:  # pylint: disable=broad-except
        return str(value)


class PipelineStats:
    def __init__(self) -> None:
        self.frames = 0
        self.encode_sum = 0.0
        self.encode_max = 0.0
        self.loop_max = 0.0
        self.radio_wait_max = 0.0

    def add(self, encode_ms: float, loop_ms: float) -> None:
        self.frames += 1
        self.encode_sum += encode_ms
        self.encode_max = max(self.encode_max, encode_ms)
        self.loop_max = max(self.loop_max, loop_ms)


class Engine:
    def __init__(
        self,
        transport: str,
        device_name: str,
        device_address: str,
        data_dir: pathlib.Path = DEFAULT_DATA_DIR,
    ) -> None:
        self.transport_name = transport
        self.device_name = device_name
        self.device_address = device_address
        self.data_dir = data_dir
        self.device: bumble.device.Device | None = None
        self.exit_stack = contextlib.AsyncExitStack()
        self.device_lock = asyncio.Lock()
        self.state = 'idle'
        self.broadcast: BroadcastConfig | None = None
        self.preset: Preset | None = None
        self.audio: AudioConfig | None = None
        self.transmit_task: asyncio.Task | None = None
        self.advertising_set: Any = None
        self.big: Any = None
        self.base_metadata: bytes = b''
        self.num_bis = 0
        self.frames_sent = 0
        self.started_at: float | None = None
        self.last_error: str | None = None
        self.transport_spec = transport
        self.needs_reset = False
        self.resets = 0
        self.last_stats: dict[str, Any] = {}
        self.firmware: dict[str, Any] = {}
        self.big_info: dict[str, Any] = {}

    # -- device ----------------------------------------------------------------
    async def ensure_device(self) -> bumble.device.Device:
        async with self.device_lock:
            if self.device is not None:
                return self.device
            if self.transport_spec == 'auto':
                # dongle may have been plugged in (or re-enumerated) since launch
                self.transport_name = resolve_transport('auto')
            logger.info('opening transport %s', self.transport_name)
            transport = None
            last_error: Exception | None = None
            # A previous helper may still be closing the port ([Errno 16] Resource
            # busy), and the dongle reboots when the port is closed, so the port
            # vanishes for a moment ([Errno 2] No such file) – v0.1.3: wait for it.
            deadline = time.monotonic() + OPEN_RETRY_SECONDS
            attempt = 0
            while True:
                attempt += 1
                try:
                    transport = await bumble.transport.open_transport(self.transport_name)
                    break
                except Exception as error:  # pylint: disable=broad-except
                    last_error = error
                    kind = classify_open_error(error)
                    if kind is None or time.monotonic() >= deadline:
                        break
                    if kind == 'gone':
                        logger.info('transport gone (dongle restarting?), waiting for the port, retry %d', attempt)
                        await wait_for_serial_port(self.transport_name, deadline)
                        if self.transport_spec == 'auto':
                            self.transport_name = resolve_transport('auto')
                    else:
                        logger.info('transport busy, retry %d', attempt)
                        await asyncio.sleep(0.5)
            if transport is None:
                error = last_error or RuntimeError('unknown')
                raise RuntimeError(
                    f'Dongle nicht erreichbar ({self.transport_name}): {error}. '
                    'Ist der Dongle eingesteckt und läuft die Auracaster-Firmware?'
                ) from error
            hci_source, hci_sink = await self.exit_stack.enter_async_context(transport)
            config = bumble.device.DeviceConfiguration(
                name=self.device_name,
                address=hci.Address(self.device_address),
            )
            device = bumble.device.Device.from_config_with_hci(config, hci_source, hci_sink)
            await device.power_on()
            self.firmware = await read_auracaster_info(device.host)
            self.device = device
            emit('status', **self.status())
            return device

    def controller_info(self) -> dict[str, Any]:
        if self.device is None:
            return {'connected': False}
        device = self.device
        return {
            'connected': True,
            'address': str(device.public_address),
            'periodic_advertising': bool(device.supports_le_periodic_advertising),
            'iso_broadcaster': bool(
                device.supports_le_features(hci.LeFeatureMask.ISOCHRONOUS_BROADCASTER)
            ),
            'past_sender': bool(
                device.supports_le_features(
                    hci.LeFeatureMask.PERIODIC_ADVERTISING_SYNC_TRANSFER_SENDER
                )
            ),
            **self.firmware,
        }

    async def controller_details(self) -> dict[str, Any]:
        """Everything "Dongle prüfen" shows (like bumble-controller-info, condensed)."""
        details: dict[str, Any] = {
            'transport': self.transport_name,
            'serial_ports': list_serial_ports(),
            'helper_version': HELPER_VERSION,
            'lc3': lc3 is not None,
        }
        try:
            device = await self.ensure_device()
        except Exception as error:  # pylint: disable=broad-except
            details['connected'] = False
            details['error'] = str(error)
            return details
        host = device.host
        version = host.local_version
        details.update(self.controller_info())
        if version is not None:
            details['hci_version'] = _spec_version(version.hci_version)
            details['lmp_version'] = _spec_version(version.lmp_version)
            details['hci_subversion'] = version.hci_subversion
            details['lmp_subversion'] = version.lmp_subversion
            details['company'] = COMPANY_IDENTIFIERS.get(
                version.company_identifier, f'0x{version.company_identifier:04x}'
            )
            details['company_id'] = version.company_identifier
        details['le_features'] = [feature.name for feature in host.supported_le_features]
        details['advertising_sets'] = host.number_of_supported_advertising_sets
        details['max_advertising_data'] = host.maximum_advertising_data_length
        details['le_acl_packets'] = getattr(host, 'le_acl_packet_queue', None) and (
            host.le_acl_packet_queue.max_in_flight
        )
        details['iso_packets'] = getattr(host, 'iso_packet_queue', None) and (
            host.iso_packet_queue.max_in_flight
        )
        return details

    def status(self) -> dict[str, Any]:
        info: dict[str, Any] = {
            'state': self.state,
            'transport': self.transport_name,
            'controller': self.controller_info(),
            'frames_sent': self.frames_sent,
            'uptime_s': round(time.monotonic() - self.started_at, 1) if self.started_at else 0,
        }
        if self.broadcast:
            info['broadcast'] = dataclasses.asdict(self.broadcast) | {'code': bool(self.broadcast.code)}
        if self.preset:
            info['preset'] = dataclasses.asdict(self.preset)
            info['estimated_latency_ms'] = round(
                (self.preset.frame_duration_us + self.preset.presentation_delay_us) / 1000
            )
        if self.last_error:
            info['error'] = self.last_error
        return info

    def set_state(self, state: str) -> None:
        self.state = state
        emit('status', **self.status())

    # -- transmit --------------------------------------------------------------
    async def start(self, broadcast: BroadcastConfig, audio: AudioConfig, preset: Preset) -> None:
        if lc3 is None:
            raise RuntimeError("lc3 module missing: pip install 'bumble[auracast]' (lc3py)")
        if self.transmit_task and not self.transmit_task.done():
            # Preset/source change while live: restart cleanly instead of failing.
            await self.stop()
        self.broadcast, self.audio, self.preset = broadcast, audio, preset
        self.last_error = None
        self.frames_sent = 0
        self.set_state('starting')
        try:
            if self.needs_reset:
                await self.reset_controller('previous teardown was not clean')
            device = await self.ensure_device()
        except Exception as error:
            self.last_error = str(error)
            self.set_state('error')
            raise
        if not device.supports_le_periodic_advertising:
            self.last_error = 'controller does not support periodic advertising'
            self.set_state('error')
            raise RuntimeError(self.last_error)
        ready = asyncio.get_running_loop().create_future()
        self.transmit_task = asyncio.create_task(self._transmit(ready))
        await ready  # raises if setup failed

    async def stop(self) -> None:
        if self.transmit_task is None:
            self.set_state('idle')
            return
        self.set_state('stopping')
        self.transmit_task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await self.transmit_task
        self.transmit_task = None
        self.started_at = None
        self.set_state('idle')

    # -- controller recovery -----------------------------------------------------
    async def reset_controller(self, reason: str) -> None:
        """Close the transport and open it again (HCI resync = HCI_Reset).

        Firmware >= 0.1.1 also reboots the dongle when the host closes the
        serial port, which clears even a wedged link layer.
        """
        logger.warning('resetting controller: %s', reason)
        emit('log', level='warning', message=f'Controller-Reset: {reason}')
        async with self.device_lock:
            self.device = None
            self.advertising_set = None
            self.big = None
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.exit_stack.aclose(), 5)
            self.exit_stack = contextlib.AsyncExitStack()
        self.needs_reset = False
        self.resets += 1
        # Give the dongle time to reboot and re-enumerate, then find it again.
        deadline = time.monotonic() + 8
        await asyncio.sleep(1.5)
        while True:
            if self.transport_spec == 'auto':
                spec = resolve_transport('auto')
                if spec != 'usb:0' or time.monotonic() > deadline:
                    self.transport_name = spec
                    break
                await asyncio.sleep(0.5)
            else:
                break
        for attempt in range(3):
            try:
                await self.ensure_device()
                return
            except Exception as error:  # pylint: disable=broad-except
                if attempt == 2:
                    raise RuntimeError(
                        f'Der Dongle reagiert nicht mehr ({error}). '
                        'Bitte den Dongle kurz ab- und wieder anstecken.'
                    ) from error
                await asyncio.sleep(1.5)

    async def _teardown_radio(self) -> None:
        """BIG terminate → PA stop → EA stop → remove set, each with a timeout.

        Any failure marks the controller for a reset before the next start:
        a half-removed advertising set otherwise exhausts the controller's
        advertising data buffers (MEMORY_CAPACITY_EXCEEDED on the next start).
        """
        clean = True

        async def step(name: str, coro: Any) -> None:
            nonlocal clean
            try:
                await asyncio.wait_for(coro, 3)
            except Exception as error:  # pylint: disable=broad-except
                clean = False
                logger.warning('teardown: %s failed: %r', name, error)

        if self.big is not None:
            await step('terminate BIG', self.big.terminate())
            self.big = None
        if self.advertising_set is not None:
            advertising_set = self.advertising_set
            self.advertising_set = None
            await step('stop periodic advertising', advertising_set.stop_periodic())
            await step('stop advertising', advertising_set.stop())
            await step('remove advertising set', advertising_set.remove())
        if not clean:
            self.needs_reset = True

    async def _setup_radio(
        self,
        device: bumble.device.Device,
        codec_rate: int,
        channels: int,
        frame_size: int,
    ) -> list[Any]:
        assert self.broadcast and self.preset
        broadcast, preset = self.broadcast, self.preset
        # -- announcements (mirrors run_transmit in apps/auracast.py) ------
        metadata = le_audio.Metadata()
        if broadcast.language:
            metadata.entries.append(
                le_audio.Metadata.Entry(
                    tag=le_audio.Metadata.Tag.LANGUAGE,
                    data=broadcast.language.encode('utf-8'),
                )
            )
        if broadcast.program_info:
            metadata.entries.append(
                le_audio.Metadata.Entry(
                    tag=le_audio.Metadata.Tag.PROGRAM_INFO,
                    data=broadcast.program_info.encode('utf-8'),
                )
            )

        public_announcement = None
        if broadcast.public:
            features = pbp.PublicBroadcastAnnouncement.Features(0)
            if broadcast.code:
                features |= pbp.PublicBroadcastAnnouncement.Features.ENCRYPTED
            if codec_rate == 48000:
                features |= pbp.PublicBroadcastAnnouncement.Features.HIGH_QUALITY_CONFIGURATION
            else:
                features |= pbp.PublicBroadcastAnnouncement.Features.STANDARD_QUALITY_CONFIGURATION
            public_announcement = pbp.PublicBroadcastAnnouncement(
                features=features, metadata=metadata
            )

        broadcast_audio_announcement = bap.BroadcastAudioAnnouncement(broadcast.broadcast_id)

        bis_list = [
            bap.BasicAudioAnnouncement.BIS(
                index=1,
                codec_specific_configuration=bap.CodecSpecificConfiguration(
                    audio_channel_allocation=bap.AudioLocation.FRONT_LEFT
                ),
            )
        ]
        if channels == 2:
            bis_list.append(
                bap.BasicAudioAnnouncement.BIS(
                    index=2,
                    codec_specific_configuration=bap.CodecSpecificConfiguration(
                        audio_channel_allocation=bap.AudioLocation.FRONT_RIGHT
                    ),
                )
            )

        basic_audio_announcement = bap.BasicAudioAnnouncement(
            presentation_delay=preset.presentation_delay_us,
            subgroups=[
                bap.BasicAudioAnnouncement.Subgroup(
                    codec_id=hci.CodingFormat(codec_id=hci.CodecID.LC3),
                    codec_specific_configuration=bap.CodecSpecificConfiguration(
                        sampling_frequency=bap.SamplingFrequency.from_hz(
                            codec_rate
                        ),
                        frame_duration=preset.bap_frame_duration,
                        octets_per_codec_frame=frame_size,
                    ),
                    metadata=metadata,
                    bis=bis_list,
                )
            ],
        )

        advertising_data = bytes(
            core.AdvertisingData(
                [
                    data_types.CompleteLocalName(self.device_name),
                    data_types.Appearance(
                        core.Appearance.Category.AUDIO_SOURCE,
                        core.Appearance.AudioSourceSubcategory.BROADCASTING_DEVICE,
                    ),
                    data_types.BroadcastName(broadcast.name),
                ]
            )
        )
        if public_announcement:
            advertising_data += bytes(public_announcement.get_advertising_data())
        advertising_data += broadcast_audio_announcement.get_advertising_data()

        self.advertising_set = await device.create_advertising_set(
            advertising_parameters=bumble.device.AdvertisingParameters(
                advertising_event_properties=bumble.device.AdvertisingEventProperties(
                    is_connectable=False
                ),
                # 100-200 ms EA / 300-600 ms PA (v0.1.1: 62.5 / 125 ms): leaves more
                # airtime for the BIG on the single nRF52840 radio
                primary_advertising_interval_min=160,
                primary_advertising_interval_max=320,
                advertising_sid=0,
                # maximum TX power (firmware: CONFIG_BT_CTLR_TX_PWR_PLUS_8)
                advertising_tx_power=8,
            ),
            advertising_data=advertising_data,
            periodic_advertising_parameters=bumble.device.PeriodicAdvertisingParameters(
                periodic_advertising_interval_min=240,
                periodic_advertising_interval_max=480,
            ),
            periodic_advertising_data=basic_audio_announcement.get_advertising_data(),
            auto_restart=True,
            auto_start=True,
        )
        await self.advertising_set.start_periodic()

        self.big = await device.create_big(
            self.advertising_set,
            parameters=bumble.device.BigParameters(
                num_bis=channels,
                sdu_interval=preset.frame_duration_us,
                max_sdu=frame_size,
                max_transport_latency=preset.max_transport_latency_ms,
                rtn=preset.rtn,
                phy=hci.PhyBit.LE_2M,
                packing=(
                    bumble.device.BigParameters.Packing.INTERLEAVED
                    if preset.packing == 'interleaved'
                    else bumble.device.BigParameters.Packing.SEQUENTIAL
                ),
                broadcast_code=(
                    broadcast_code_bytes(broadcast.code) if broadcast.code else None
                ),
            ),
        )
        big = self.big
        self.big_info = {
            'big_nse': getattr(big, 'nse', None),
            'big_bn': getattr(big, 'bn', None),
            'big_pto': getattr(big, 'pto', None),
            'big_irc': getattr(big, 'irc', None),
            'big_iso_interval_ms': getattr(big, 'iso_interval', None),
            'big_transport_latency_us': getattr(big, 'transport_latency_big', None),
            'big_packing': preset.packing,
        }
        logger.info('BIG parameters chosen by the controller: %s', self.big_info)
        emit(
            'log',
            level='info',
            message='BIG: NSE {big_nse}, BN {big_bn}, PTO {big_pto}, IRC {big_irc}, '
            'ISO-Intervall {big_iso_interval_ms} ms, Packing {big_packing}'.format(**self.big_info),
        )
        bis_links = list(self.big.bis_links)
        for bis_link in bis_links:
            await bis_link.setup_data_path(direction=bis_link.Direction.HOST_TO_CONTROLLER)
        return bis_links

    async def _transmit(self, ready: asyncio.Future) -> None:
        assert self.broadcast and self.audio and self.preset
        preset = self.preset
        source = PcmSource(self.audio)
        recorder: WavRecorder | None = None
        executor = concurrent.futures.ThreadPoolExecutor(1, thread_name_prefix='lc3')
        loop = asyncio.get_running_loop()
        try:
            pcm_format = await source.open(capacity_frames=48000 // 4)  # resized below
            channels = pcm_format.channels
            if channels not in (1, 2):
                raise ValueError('only mono or stereo PCM is supported')
            if pcm_format.sample_type == audio_io.PcmFormat.SampleType.INT16:
                pcm_bit_depth: int | None = 16
            elif pcm_format.sample_type == audio_io.PcmFormat.SampleType.FLOAT32:
                pcm_bit_depth = None
            else:
                raise ValueError('only int16le and float32le are supported')
            pcm_rate = pcm_format.sample_rate
            if pcm_rate not in (16000, 24000, 32000, 48000):
                raise ValueError(
                    f'PCM-Abtastrate {pcm_rate} Hz wird nicht unterstützt (16/24/32/48 kHz)'
                )
            codec_rate = preset.sample_rate_hz or pcm_rate
            if codec_rate > pcm_rate:
                codec_rate = pcm_rate

            encoder = lc3.Encoder(
                frame_duration_us=preset.frame_duration_us,
                sample_rate_hz=codec_rate,
                num_channels=channels,
                input_sample_rate_hz=pcm_rate,
            )
            frame_samples = encoder.get_frame_samples()  # at the PCM rate
            frame_size = encoder.get_frame_bytes(preset.bitrate)
            ring = source.ring
            assert ring is not None
            # ring: 250 ms max (overrun → drop oldest), jitter target ~30 ms
            ring.capacity = (pcm_rate // 4) * ring.bytes_per_frame
            target = pcm_rate * preset.jitter_target_ms // 1000
            picker = FramePicker(
                ring,
                frame_samples,
                target,
                channels=channels,
                float_samples=pcm_format.sample_type != audio_io.PcmFormat.SampleType.INT16,
                sample_rate=pcm_rate,
            )
            logger.info(
                'pipeline: PCM %d Hz %d ch %s -> LC3 %d Hz %.1f ms, %d bytes/BIS, '
                'prefill %d SDUs, jitter target %d ms',
                pcm_rate, channels, pcm_format.sample_type.name, codec_rate,
                preset.frame_duration_us / 1000, frame_size, preset.prefill_sdus,
                preset.jitter_target_ms,
            )
            if self.audio.record_path:
                recorder = WavRecorder(self.audio.record_path, pcm_format)
                logger.info('recording encoder input to %s', recorder.path)
                emit('log', level='info', message=f'WAV-Mitschnitt: {recorder.path}')

            # -- radio (one automatic controller reset + retry on failure) ------
            bis_links: list[Any] = []
            for attempt in (1, 2):
                device = await self.ensure_device()
                try:
                    bis_links = await self._setup_radio(device, codec_rate, channels, frame_size)
                    break
                except Exception as error:  # pylint: disable=broad-except
                    logger.warning('radio setup failed (attempt %d): %r', attempt, error)
                    await self._teardown_radio()
                    if attempt == 2:
                        raise
                    await self.reset_controller(f'Broadcast-Start fehlgeschlagen: {error}')

            device = self.device
            assert device is not None
            streams = [
                bumble.device.IsoPacketStream(link, preset.prefill_sdus) for link in bis_links
            ]
            iso_queue = device.host.iso_packet_queue
            self.base_metadata = b''
            self.num_bis = channels
            self.started_at = time.monotonic()
            self.set_state('live')
            if not ready.done():
                ready.set_result(None)

            # -- main loop: paced by controller completions ----------------------
            def encode(pcm: bytes) -> tuple[bytes, float]:
                t0 = time.perf_counter()
                if recorder is not None:
                    recorder.write(pcm)
                data = encoder.encode(pcm, num_bytes=channels * frame_size, bit_depth=pcm_bit_depth)
                return data, (time.perf_counter() - t0) * 1000

            stats = PipelineStats()
            stall_ms = 4 * preset.frame_duration_us / 1000
            stalls = 0
            last_stall_log = 0.0
            level_every = max(1, int(50000 / preset.frame_duration_us))  # ~20 Hz
            last_report = time.monotonic()
            completed0 = iso_queue.completed if iso_queue else 0
            while True:
                pcm = picker.next()
                t_loop = time.perf_counter()
                lc3_frame, encode_ms = await loop.run_in_executor(executor, encode, pcm)
                t_radio = time.perf_counter()
                for index, stream in enumerate(streams):
                    await stream.write(lc3_frame[index * frame_size : (index + 1) * frame_size])
                radio_wait_ms = (time.perf_counter() - t_radio) * 1000
                loop_ms = (time.perf_counter() - t_loop) * 1000
                self.frames_sent += 1
                stats.add(encode_ms, loop_ms)
                stats.radio_wait_max = max(stats.radio_wait_max, radio_wait_ms)
                if loop_ms > stall_ms:
                    # who held us up: waiting for controller completions (radio) or
                    # the host side (event loop, encoder thread, GC)?
                    stalls += 1
                    cause = 'Controller' if radio_wait_ms > loop_ms / 2 else 'Host'
                    if time.monotonic() - last_stall_log > 2:
                        last_stall_log = time.monotonic()
                        message = (
                            f'Stall {loop_ms:.0f} ms ({cause}: Funk-Warten {radio_wait_ms:.0f} ms, '
                            f'Encoder {encode_ms:.1f} ms, im Controller {iso_queue.pending if iso_queue else "?"})'
                        )
                        logger.warning(message)
                        emit('log', level='warning', message=message)
                if self.frames_sent % level_every == 0 and pcm is not picker.silence:
                    peak, rms = measure_levels(pcm, pcm_format)
                    emit('level', peak=peak, rms=rms)
                if ring.eof and ring.frames < frame_samples:
                    logger.info('input ended')
                    break
                now = time.monotonic()
                if now - last_report >= 1.0:
                    completed = iso_queue.completed if iso_queue else 0
                    report = {
                        'sdus_per_s': round(stats.frames * len(streams) / (now - last_report), 1),
                        'frames_sent': self.frames_sent,
                        'iso_queued': iso_queue.queued if iso_queue else None,
                        'iso_completed': completed,
                        'iso_completed_per_s': round((completed - completed0) / (now - last_report), 1),
                        'iso_pending': iso_queue.pending if iso_queue else None,
                        'underruns': picker.underruns,
                        'overrun_frames': ring.dropped_frames,
                        'slips_dropped': picker.slips_dropped,
                        'slips_inserted': picker.slips_inserted,
                        'flushes': picker.flushes,
                        'flushed_frames': picker.flushed_frames,
                        'stalls': stalls,
                        'radio_wait_ms_max': round(stats.radio_wait_max, 1),
                        'buffer_ms': round(ring.frames * 1000 / pcm_rate, 1),
                        'encode_ms_avg': round(stats.encode_sum / max(1, stats.frames), 2),
                        'encode_ms_max': round(stats.encode_max, 2),
                        'loop_ms_max': round(stats.loop_max, 2),
                        'serial_bytes_per_s': round(
                            stats.frames * len(streams) * (frame_size + 9) / (now - last_report)
                        ),
                        'controller_resets': self.resets,
                        # SDUs the radio should take per second (all BIS)
                        'sdus_expected_per_s': round(
                            len(streams) * 1_000_000 / preset.frame_duration_us, 1
                        ),
                        **{k: v for k, v in self.big_info.items() if v is not None},
                    }
                    self.last_stats = report
                    emit('stats', **report)
                    if int(now) % 5 == 0:
                        logger.info('stats %s', json.dumps(report))
                    completed0 = completed
                    stats = PipelineStats()
                    last_report = now
        except asyncio.CancelledError:
            raise
        except Exception as error:  # pylint: disable=broad-except
            logger.exception('transmit failed')
            self.last_error = str(error)
            self.set_state('error')
            if not ready.done():
                ready.set_exception(error)
        finally:
            await self._teardown_radio()
            await source.close()
            if recorder is not None:
                recorder.close()
            executor.shutdown(wait=False)

    # -- scan ------------------------------------------------------------------
    async def scan(self, duration: float) -> int:
        device = await self.ensure_device()
        seen: dict[tuple[str, int], dict[str, Any]] = {}

        def on_advertisement(advertisement: bumble.device.Advertisement) -> None:
            service_data = advertisement.data.get_all(
                core.AdvertisingData.Type.SERVICE_DATA_16_BIT_UUID
            )
            announcement = next(
                (
                    data
                    for uuid, data in service_data or []
                    if uuid == gatt.GATT_BROADCAST_AUDIO_ANNOUNCEMENT_SERVICE
                ),
                None,
            )
            if announcement is None:
                return
            broadcast_id = bap.BroadcastAudioAnnouncement.from_bytes(announcement).broadcast_id
            key = (str(advertisement.address), broadcast_id)
            names = advertisement.data.get_all(core.AdvertisingData.Type.BROADCAST_NAME)
            entry = {
                'address': str(advertisement.address),
                'broadcast_id': broadcast_id,
                'name': names[0] if names else None,
                'rssi': advertisement.rssi,
                'encrypted': None,  # needs PA sync + BIGInfo (roadmap)
            }
            if key not in seen:
                emit('broadcast_found', **entry)
            seen[key] = entry

        device.on('advertisement', on_advertisement)
        try:
            await device.start_scanning(active=False, filter_duplicates=False)
            await asyncio.sleep(duration)
        finally:
            with contextlib.suppress(Exception):
                await device.stop_scanning()
            device.remove_listener('advertisement', on_advertisement)
        emit('scan_complete', count=len(seen))
        return len(seen)

    async def close(self) -> None:
        await self.stop()
        await self.exit_stack.aclose()
        self.device = None


# -----------------------------------------------------------------------------
# Command loop
# -----------------------------------------------------------------------------
def start_stdin_reader(loop: asyncio.AbstractEventLoop, queue: asyncio.Queue) -> None:
    """Read stdin lines on a thread (portable, works with pipes on macOS)."""

    def reader() -> None:
        for line in sys.stdin:
            loop.call_soon_threadsafe(queue.put_nowait, line)
        loop.call_soon_threadsafe(queue.put_nowait, None)  # EOF = parent gone

    threading.Thread(target=reader, name='stdin-reader', daemon=True).start()


async def handle_command(engine: Engine, message: dict[str, Any]) -> bool:
    """Returns False when the helper should exit."""
    cmd = message.get('cmd')
    request_id = message.get('id')
    try:
        if cmd == 'start':
            await engine.start(
                BroadcastConfig.from_json(message.get('broadcast')),
                AudioConfig.from_json(message.get('audio')),
                Preset.from_json(message.get('preset')),
            )
        elif cmd == 'stop':
            await engine.stop()
        elif cmd == 'status':
            emit('status', **engine.status())
        elif cmd == 'scan':
            # Scan runs in the background so stop/status stay responsive.
            asyncio.create_task(engine.scan(float(message.get('duration', 5.0))))
        elif cmd == 'shutdown':
            emit('ack', id=request_id)
            return False
        elif cmd == 'controller_info':
            emit('controller_info', id=request_id, **(await engine.controller_details()))
        elif cmd == 'connect':
            # Open the dongle right away so the app can show its status. Not an
            # error when it is missing (yet): the app shows "Kein Dongle".
            try:
                await engine.ensure_device()
            except Exception as error:  # pylint: disable=broad-except
                logger.info('connect: %s', error)
                emit('status', **engine.status())
        elif cmd == 'ping':
            pass
        else:
            raise ValueError(f'unknown command: {cmd!r}')
        emit('ack', id=request_id, cmd=cmd)
    except Exception as error:  # pylint: disable=broad-except
        logger.exception('command %s failed', cmd)
        emit('error', id=request_id, cmd=cmd, message=str(error))
    return True


async def main_async(args: argparse.Namespace) -> None:
    spec = args.transport
    args.transport = resolve_transport(spec)
    engine = Engine(args.transport, args.device_name, args.device_address)
    engine.transport_spec = spec

    def on_loop_exception(loop: asyncio.AbstractEventLoop, context: dict[str, Any]) -> None:
        # Background task errors must never kill the helper silently.
        error = context.get('exception')
        logger.error('unhandled: %s', context.get('message'), exc_info=error)
        emit('log', level='error', message=f"{context.get('message')}: {error!r}")

    asyncio.get_running_loop().set_exception_handler(on_loop_exception)
    queue: asyncio.Queue[str | None] = asyncio.Queue()
    start_stdin_reader(asyncio.get_running_loop(), queue)
    emit(
        'ready',
        version=HELPER_VERSION,
        protocol=PROTOCOL_VERSION,
        transport=args.transport,
        lc3=lc3 is not None,
    )
    try:
        while (line := await queue.get()) is not None:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError as error:
                emit('error', message=f'invalid JSON: {error}')
                continue
            if not await handle_command(engine, message):
                break
    finally:
        await engine.close()


def main() -> None:
    parser = argparse.ArgumentParser(description='Auracaster Bumble engine helper')
    parser.add_argument(
        '--transport',
        default='auto',
        help='Bumble transport: auto (Auracaster dongle, else usb:0), '
        'serial:/dev/cu.usbmodemXXXX,resync or usb:0',
    )
    parser.add_argument('--device-name', default=DEFAULT_DEVICE_NAME)
    parser.add_argument('--device-address', default=DEFAULT_DEVICE_ADDRESS)
    parser.add_argument('--log-level', default='INFO')
    parser.add_argument(
        '--self-test',
        action='store_true',
        help='check that Bumble, all its subpackages and LC3 import, then exit',
    )
    args = parser.parse_args()
    if args.self_test:
        sys.exit(self_test())
    logging.basicConfig(
        stream=sys.stderr,
        level=args.log_level.upper(),
        format='%(asctime)s %(levelname)s %(name)s: %(message)s',
    )
    logger.info(
        'Auracaster helper %s, Python %s, bumble from %s, lc3 %s',
        HELPER_VERSION,
        sys.version.split()[0],
        pathlib.Path(bumble.__file__).parent,
        'ok' if lc3 is not None else 'MISSING',
    )
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass
    except Exception as error:  # pylint: disable=broad-except
        emit_fatal(f'Engine abgestürzt: {type(error).__name__}: {error}', error)
        sys.exit(1)


def self_test() -> int:
    """Used by setup-engine.sh and CI: every Bumble subpackage + LC3 must import."""
    import importlib  # pylint: disable=import-outside-toplevel
    import pkgutil  # pylint: disable=import-outside-toplevel

    failures = []
    base = pathlib.Path(bumble.__file__).parent
    for info in pkgutil.walk_packages([str(base)], 'bumble.'):
        if not info.ispkg:
            continue
        try:
            importlib.import_module(info.name)
        except ImportError as error:
            if 'grpc' in str(error) or 'protobuf' in str(error):
                continue  # optional [android] extra
            failures.append(f'{info.name}: {error}')
    for name in ('bumble.device', 'bumble.crypto', 'bumble.profiles.bap', 'bumble.audio.io'):
        try:
            importlib.import_module(name)
        except ImportError as error:
            failures.append(f'{name}: {error}')
    if lc3 is None:
        failures.append('lc3: missing (pip install lc3py)')
    for line in failures:
        print(f'FAIL {line}')
    print('self-test', 'OK' if not failures else 'FAILED', f'(helper {HELPER_VERSION})')
    return 1 if failures else 0


if __name__ == '__main__':
    main()

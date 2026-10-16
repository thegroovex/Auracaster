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
A shared-memory ring buffer will replace the FIFO later (see
macos/Auracaster/Audio/PCMRingBuffer.swift for the planned layout).

Commands (one JSON object per line):
    {"cmd": "start", "id": 1, "broadcast": {...}, "audio": {...}, "preset": {...}}
    {"cmd": "stop", "id": 2}
    {"cmd": "status", "id": 3}
    {"cmd": "scan", "id": 4, "duration": 5.0}
    {"cmd": "shutdown", "id": 5}

Events (one JSON object per line):
    {"event": "ready", "version": "...", "transport": "serial:/dev/cu.usbmodem...,resync"}
    {"event": "ack", "id": 1}
    {"event": "error", "id": 1, "message": "..."}
    {"event": "status", "state": "idle|starting|live|stopping|error", ...}
    {"event": "level", "peak": [l, r], "rms": [l, r]}
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
import contextlib
import dataclasses
import json
import logging
import math
import os
import pathlib
import secrets
import sys
import threading
import time
from collections.abc import AsyncGenerator
from typing import Any

# Allow running straight from the repository checkout (engine/ is next to bumble/).
_REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
if (_REPO_ROOT / 'bumble' / '__init__.py').exists() and str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

try:
    import lc3  # type: ignore  # pylint: disable=E0401
except ImportError:  # pragma: no cover - reported at runtime as an event
    lc3 = None  # type: ignore

import bumble.device
import bumble.transport
from bumble import core, data_types, gatt, hci
from bumble.audio import io as audio_io
from bumble.profiles import bap, le_audio, pbp

HELPER_VERSION = '0.1.0'
PROTOCOL_VERSION = 1

DEFAULT_DEVICE_NAME = 'Auracaster'
DEFAULT_DEVICE_ADDRESS = 'F0:F1:F2:F3:F4:F5'

logger = logging.getLogger('auracaster.helper')


# -----------------------------------------------------------------------------
# Protocol output
# -----------------------------------------------------------------------------
_stdout_lock = threading.Lock()


# USB identity of the Auracaster dongle firmware (firmware/prj.conf)
DONGLE_PRODUCT = 'Auracaster Dongle'
DONGLE_VID_PID = (0x2FE3, 0x0004)


def find_dongle_serial_port() -> str | None:
    """Return the serial device of a connected Auracaster dongle, if any."""
    try:
        from serial.tools import list_ports  # type: ignore  # pylint: disable=E0401
    except ImportError:  # pragma: no cover
        return None
    candidates = []
    for port in list_ports.comports():
        product = port.product or ''
        if product.startswith(DONGLE_PRODUCT) or (port.vid, port.pid) == DONGLE_VID_PID:
            device = port.device
            # macOS: use the call-out device, /dev/tty.* blocks on carrier detect
            if device.startswith('/dev/tty.usbmodem'):
                device = '/dev/cu.' + device[len('/dev/tty.') :]
            candidates.append((not product.startswith(DONGLE_PRODUCT), device))
    return sorted(candidates)[0][1] if candidates else None


def resolve_transport(spec: str) -> str:
    """Map "auto" to the dongle's serial port (with HCI resync), else usb:0."""
    if spec != 'auto':
        return spec
    device = find_dongle_serial_port()
    if device is None:
        logger.warning('no Auracaster dongle found, falling back to usb:0')
        return 'usb:0'
    return f'serial:{device},resync'


def emit(event: str, **fields: Any) -> None:
    """Write one event line to stdout (thread-safe, flushed)."""
    payload = {'event': event, **fields}
    line = json.dumps(payload, separators=(',', ':'), default=str)
    with _stdout_lock:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()


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

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> Preset:
        preset = cls(**{k: v for k, v in (data or {}).items() if k in cls.__dataclass_fields__})
        if preset.frame_duration_us not in (7500, 10000):
            raise ValueError('frame_duration_us must be 7500 or 10000')
        return preset

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
# Audio inputs
# -----------------------------------------------------------------------------
class FifoAudioInput(audio_io.ThreadedAudioInput):
    """Raw PCM from a named pipe. Opened lazily in the worker thread (open() blocks
    until the writer side — the macOS app — connects)."""

    def __init__(self, path: str, pcm_format: audio_io.PcmFormat) -> None:
        super().__init__()
        self._path = path
        self._pcm_format = pcm_format
        self._stream: Any = None

    def _open(self) -> audio_io.PcmFormat:
        if not os.path.exists(self._path):
            os.mkfifo(self._path)
        self._stream = open(self._path, 'rb')  # pylint: disable=consider-using-with
        return self._pcm_format

    def _read(self, frame_size: int) -> bytes:
        size = frame_size * self._pcm_format.channels * self._pcm_format.bytes_per_sample
        data = self._stream.read(size)
        if not data:
            # Writer went away: deliver silence so the BIG keeps running.
            time.sleep(frame_size / self._pcm_format.sample_rate)
            return bytes(size)
        if len(data) < size:
            data += bytes(size - len(data))
        return data

    def _close(self) -> None:
        if self._stream:
            self._stream.close()


class SilenceAudioInput(audio_io.AudioInput):
    """Paced digital silence, for bring-up without any audio routing."""

    def __init__(self, pcm_format: audio_io.PcmFormat) -> None:
        self._pcm_format = pcm_format

    async def open(self) -> audio_io.PcmFormat:
        return self._pcm_format

    async def frames(self, frame_size: int) -> AsyncGenerator[bytes]:
        frame = bytes(frame_size * self._pcm_format.channels * self._pcm_format.bytes_per_sample)
        period = frame_size / self._pcm_format.sample_rate
        next_deadline = time.monotonic()
        while True:
            next_deadline += period
            await asyncio.sleep(max(0.0, next_deadline - time.monotonic()))
            yield frame

    async def aclose(self) -> None:
        pass


async def create_audio_input(config: AudioConfig) -> audio_io.AudioInput:
    if config.input == 'silence':
        return SilenceAudioInput(audio_io.PcmFormat.from_str(config.format))
    if config.input.startswith('fifo:'):
        return FifoAudioInput(config.input[5:], audio_io.PcmFormat.from_str(config.format))
    if config.input == 'stdin':
        raise ValueError('stdin is reserved for the JSON control channel; use fifo:')
    # file:, device:, etc. handled by Bumble.
    return await audio_io.create_audio_input(config.input, config.format)


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
class Engine:
    def __init__(self, transport: str, device_name: str, device_address: str) -> None:
        self.transport_name = transport
        self.device_name = device_name
        self.device_address = device_address
        self.device: bumble.device.Device | None = None
        self.exit_stack = contextlib.AsyncExitStack()
        self.state = 'idle'
        self.broadcast: BroadcastConfig | None = None
        self.preset: Preset | None = None
        self.audio: AudioConfig | None = None
        self.transmit_task: asyncio.Task | None = None
        self.advertising_set: Any = None
        self.big: Any = None
        self.frames_sent = 0
        self.started_at: float | None = None
        self.last_error: str | None = None

    # -- device ----------------------------------------------------------------
    async def ensure_device(self) -> bumble.device.Device:
        if self.device is not None:
            return self.device
        logger.info('opening transport %s', self.transport_name)
        hci_source, hci_sink = await self.exit_stack.enter_async_context(
            await bumble.transport.open_transport(self.transport_name)
        )
        config = bumble.device.DeviceConfiguration(
            name=self.device_name,
            address=hci.Address(self.device_address),
        )
        device = bumble.device.Device.from_config_with_hci(config, hci_source, hci_sink)
        await device.power_on()
        self.device = device
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
            )
            if hasattr(device, 'supports_le_features')
            else None,
        }

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
            raise RuntimeError('already broadcasting; send stop first')
        self.broadcast, self.audio, self.preset = broadcast, audio, preset
        self.last_error = None
        self.frames_sent = 0
        self.set_state('starting')
        device = await self.ensure_device()
        if not device.supports_le_periodic_advertising:
            self.set_state('error')
            raise RuntimeError('controller does not support periodic advertising')
        ready = asyncio.get_running_loop().create_future()
        self.transmit_task = asyncio.create_task(self._transmit(device, ready))
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

    async def _teardown_radio(self) -> None:
        if self.big is not None:
            with contextlib.suppress(Exception):
                await self.big.terminate()
            self.big = None
        if self.advertising_set is not None:
            with contextlib.suppress(Exception):
                await self.advertising_set.stop_periodic()
            with contextlib.suppress(Exception):
                await self.advertising_set.stop()
            self.advertising_set = None

    async def _transmit(self, device: bumble.device.Device, ready: asyncio.Future) -> None:
        assert self.broadcast and self.audio and self.preset
        broadcast, preset = self.broadcast, self.preset
        audio_input = await create_audio_input(self.audio)
        try:
            pcm_format = await audio_input.open()
            if pcm_format.channels not in (1, 2):
                raise ValueError('only mono or stereo PCM is supported')
            if pcm_format.sample_type == audio_io.PcmFormat.SampleType.INT16:
                pcm_bit_depth: int | None = 16
            elif pcm_format.sample_type == audio_io.PcmFormat.SampleType.FLOAT32:
                pcm_bit_depth = None
            else:
                raise ValueError('only int16le and float32le are supported')
            if pcm_format.sample_rate not in (16000, 24000, 48000):
                raise ValueError(f'sample rate {pcm_format.sample_rate} not supported')

            encoder = lc3.Encoder(
                frame_duration_us=preset.frame_duration_us,
                sample_rate_hz=pcm_format.sample_rate,
                num_channels=pcm_format.channels,
                input_sample_rate_hz=pcm_format.sample_rate,
            )
            frame_samples = encoder.get_frame_samples()
            frame_size = encoder.get_frame_bytes(preset.bitrate)
            logger.info('LC3: %d samples -> %d bytes per channel', frame_samples, frame_size)

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
                if pcm_format.sample_rate == 48000:
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
            if pcm_format.channels == 2:
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
                                pcm_format.sample_rate
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
                    primary_advertising_interval_min=100,
                    primary_advertising_interval_max=1000,
                    advertising_sid=0,
                ),
                advertising_data=advertising_data,
                periodic_advertising_parameters=bumble.device.PeriodicAdvertisingParameters(
                    periodic_advertising_interval_min=100,
                    periodic_advertising_interval_max=1000,
                ),
                periodic_advertising_data=basic_audio_announcement.get_advertising_data(),
                auto_restart=True,
                auto_start=True,
            )
            await self.advertising_set.start_periodic()

            self.big = await device.create_big(
                self.advertising_set,
                parameters=bumble.device.BigParameters(
                    num_bis=pcm_format.channels,
                    sdu_interval=preset.frame_duration_us,
                    max_sdu=frame_size,
                    max_transport_latency=preset.max_transport_latency_ms,
                    rtn=preset.rtn,
                    broadcast_code=(
                        broadcast_code_bytes(broadcast.code) if broadcast.code else None
                    ),
                ),
            )

            iso_queues = []
            for bis_link in self.big.bis_links:
                await bis_link.setup_data_path(direction=bis_link.Direction.HOST_TO_CONTROLLER)
                iso_queues.append(bumble.device.IsoPacketStream(bis_link, 64))

            self.started_at = time.monotonic()
            self.set_state('live')
            if not ready.done():
                ready.set_result(None)

            # -- main loop ---------------------------------------------------
            level_every = max(1, int(50000 / preset.frame_duration_us))  # ~20 Hz
            async for pcm_frame in audio_input.frames(frame_samples):
                lc3_frame = encoder.encode(
                    pcm_frame,
                    num_bytes=pcm_format.channels * frame_size,
                    bit_depth=pcm_bit_depth,
                )
                for index, start in enumerate(range(0, len(lc3_frame), frame_size)):
                    await iso_queues[index].write(lc3_frame[start : start + frame_size])
                self.frames_sent += 1
                if self.frames_sent % level_every == 0:
                    peak, rms = measure_levels(pcm_frame, pcm_format)
                    emit('level', peak=peak, rms=rms)
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
            with contextlib.suppress(Exception):
                await audio_input.aclose()

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
    args.transport = resolve_transport(args.transport)
    engine = Engine(args.transport, args.device_name, args.device_address)
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
    args = parser.parse_args()
    logging.basicConfig(
        stream=sys.stderr,
        level=args.log_level.upper(),
        format='%(asctime)s %(levelname)s %(name)s: %(message)s',
    )
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()

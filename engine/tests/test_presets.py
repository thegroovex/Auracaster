#!/usr/bin/env python3
# Copyright 2026 Auracaster contributors
# SPDX-License-Identifier: Apache-2.0
"""Preset parsing/clamping, BIG fallback and broadcast encryption (v0.1.4).

Run:  python engine/tests/test_presets.py      (CI: job "engine")

1. Preset.parse clamps every value into the ranges of "Erweitert · Latenz"
   and reports what it changed (German log text); the built-in presets of the
   app pass unchanged.
2. BIG parameters: PHY 1M/2M, packing, RTN/latency pass through; a Broadcast
   Code switches encryption on (16-octet Broadcast_Code, UTF-8 + 0x00 padding).
3. Controller rejections (HCI 0x11/0x12/0x30) are recognised and fall back to
   safe values; the user facing message names the requested values.
4. PBP features: "encrypted" bit set exactly when a code is set.
"""

from __future__ import annotations

import asyncio
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import auracaster_helper as h  # noqa: E402  pylint: disable=wrong-import-position
from bumble import hci  # noqa: E402  pylint: disable=wrong-import-position
from bumble.profiles import pbp  # noqa: E402  pylint: disable=wrong-import-position

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    print(('  ok   ' if condition else '  FAIL ') + message)
    if not condition:
        FAILURES.append(message)


# Built-in presets as the app sends them (BroadcastPreset.swift, v0.1.3/0.1.4)
APP_PRESETS = {
    'compatible': dict(frame_duration_us=10000, bitrate=48000, presentation_delay_us=40000, rtn=2,
                       max_transport_latency_ms=10, sample_rate_hz=24000, packing='sequential', jitter_ms=30, phy='2M'),
    'balanced': dict(frame_duration_us=10000, bitrate=80000, presentation_delay_us=25000, rtn=2,
                     max_transport_latency_ms=20, sample_rate_hz=48000, packing='sequential', jitter_ms=30, phy='2M'),
    'highQuality': dict(frame_duration_us=10000, bitrate=96000, presentation_delay_us=40000, rtn=2,
                        max_transport_latency_ms=20, sample_rate_hz=48000, packing='interleaved', jitter_ms=60, phy='2M'),
    'ultraLow': dict(frame_duration_us=7500, bitrate=80000, presentation_delay_us=20000, rtn=3,
                     max_transport_latency_ms=20, sample_rate_hz=48000, packing='sequential', jitter_ms=100, phy='2M'),
}


def test_builtin_presets_unchanged() -> None:
    print('built-in presets')
    for name, data in APP_PRESETS.items():
        preset, adjustments = h.Preset.parse(data)
        check(adjustments == [], f'{name}: no adjustments ({adjustments})')
        check(all(getattr(preset, key) == value for key, value in data.items()), f'{name}: values kept')
    # v0.1.3 app without phy/custom keys still parses (defaults)
    legacy, adjustments = h.Preset.parse({k: v for k, v in APP_PRESETS['balanced'].items() if k != 'phy'})
    check(legacy.phy == '2M' and not adjustments, 'missing phy -> 2M, no warning')
    check(h.Preset.parse(None)[0] == h.Preset(), 'empty preset = defaults')


def test_clamping() -> None:
    print('clamping')
    preset, adjustments = h.Preset.parse({
        'frame_duration_us': 8000, 'presentation_delay_us': 1000, 'rtn': 9,
        'max_transport_latency_ms': 500, 'jitter_ms': 3, 'sample_rate_hz': 44100,
        'packing': 'zigzag', 'phy': 'coded', 'bitrate': 1, 'prefill': 99,
    })
    check(preset.frame_duration_us == 7500, '8000 us frame -> 7500')
    check(preset.presentation_delay_us == 5000, 'PD 1 ms -> 5 ms')
    check(preset.rtn == 4, 'RTN 9 -> 4')
    check(preset.max_transport_latency_ms == 100, 'latency 500 -> 100 ms')
    check(preset.jitter_ms == 10, 'jitter 3 -> 10 ms')
    check(preset.sample_rate_hz == 48000, '44.1 kHz -> 48 kHz (nearest)')
    check(preset.packing == 'sequential', 'unknown packing -> sequential')
    check(preset.phy == '2M', 'unknown PHY -> 2M')
    check(preset.bitrate == 16000, 'bitrate clamped to 16 kbit/s')
    check(preset.prefill == 16, 'prefill clamped')
    check(len(adjustments) == 10, f'every change reported ({len(adjustments)})')
    check(any('rtn 9 → 4' in line for line in adjustments), 'German/arrow text for RTN')

    zero, adjustments = h.Preset.parse({'jitter_ms': 0})
    check(zero.jitter_ms == 0 and zero.jitter_target_ms == 30 and not adjustments, 'jitter 0 = automatic')
    one_m, _ = h.Preset.parse({'phy': '1m'})
    check(one_m.phy == '1M' and one_m.hci_phy == hci.PhyBit.LE_1M, 'phy "1m" -> LE 1M')
    check(h.Preset.parse({'phy': 'LE_2M'})[0].hci_phy == hci.PhyBit.LE_2M, 'phy "LE_2M" -> LE 2M')
    bad_type, adjustments = h.Preset.parse({'rtn': 'viel'})
    check(bad_type.rtn == h.Preset().rtn and len(adjustments) == 1, 'wrong type -> default + note')
    edges, adjustments = h.Preset.parse({'presentation_delay_us': 100000, 'rtn': 0,
                                         'max_transport_latency_ms': 5, 'jitter_ms': 150})
    check(not adjustments, 'range edges are valid (PD 100 ms, RTN 0, latency 5 ms, jitter 150 ms)')
    custom, _ = h.Preset.parse({'custom': True})
    check(custom.custom is True, 'custom flag kept')


def test_big_parameters() -> None:
    print('BIG parameters + encryption')
    preset, _ = h.Preset.parse({'rtn': 3, 'max_transport_latency_ms': 15, 'phy': '1M',
                                'packing': 'interleaved', 'frame_duration_us': 7500})
    params = h.make_big_parameters(preset, 2, 75, None)
    check(params.num_bis == 2 and params.sdu_interval == 7500 and params.max_sdu == 75, 'BIS/SDU')
    check(params.rtn == 3 and params.max_transport_latency == 15, 'RTN + latency passed through')
    check(params.phy == hci.PhyBit.LE_1M, 'PHY 1M')
    check(params.packing == h.bumble.device.BigParameters.Packing.INTERLEAVED, 'interleaved')
    check(params.broadcast_code is None, 'open broadcast: no code')

    encrypted = h.make_big_parameters(preset, 1, 75, 'Wohnzimmer')
    check(encrypted.broadcast_code == b'Wohnzimmer' + bytes(6), 'code = UTF-8 + 0x00 padding (16 octets)')
    check(h.broadcast_code_bytes('1234') == b'1234' + bytes(12), '4-byte password')
    check(h.broadcast_code_bytes('ÄÖÜß-1234567') == 'ÄÖÜß-1234567'.encode() , '16 UTF-8 bytes, no padding')
    check(len(h.broadcast_code_bytes('0x' + '01' * 16)) == 16, 'hex code still accepted')
    for bad in ('123', 'x' * 17, 'ÄÖÜßÄÖÜßÄ'):  # 3 bytes, 17 bytes, 18 UTF-8 bytes
        try:
            h.broadcast_code_bytes(bad)
            check(False, f'{bad!r} rejected')
        except ValueError as error:
            check('4–16 Byte' in str(error), f'{bad!r} rejected with German message')

    config = h.BroadcastConfig.from_json({'name': 'X', 'code': ''})
    check(config.code is None, 'empty code -> open broadcast')
    try:
        h.BroadcastConfig.from_json({'name': 'X', 'code': 'ab'})
        check(False, 'too short code rejected at start')
    except ValueError:
        check(True, 'too short code rejected at start')


def test_public_broadcast_flag() -> None:
    print('PBP encrypted flag')
    features = pbp.PublicBroadcastAnnouncement.Features
    check(bool(h.public_broadcast_features(True, 48000) & features.ENCRYPTED), 'encrypted -> flag set')
    check(not h.public_broadcast_features(False, 48000) & features.ENCRYPTED, 'open -> flag clear')
    check(bool(h.public_broadcast_features(True, 48000) & features.HIGH_QUALITY_CONFIGURATION), '48 kHz -> HQ')
    check(bool(h.public_broadcast_features(False, 24000) & features.STANDARD_QUALITY_CONFIGURATION), '24 kHz -> SQ')
    announcement = pbp.PublicBroadcastAnnouncement(
        features=h.public_broadcast_features(True, 48000), metadata=h.le_audio.Metadata()
    )
    data = bytes(announcement.get_advertising_data())
    # AD: len, 0x16 (service data), UUID 0x1856 LE, features, metadata length
    check(data[1] == 0x16 and data[2:4] == bytes([0x56, 0x18]), 'PBP service data 0x1856')
    check(bool(data[4] & 0x01), 'features byte bit 0 (encrypted) in the advertising data')


def test_fallback() -> None:
    print('controller rejection + fallback')
    check(h.is_big_parameter_rejection(hci.HCI_Error(0x12)), '0x12 invalid parameters = rejection')
    check(h.is_big_parameter_rejection(hci.HCI_Error(0x11)), '0x11 unsupported value = rejection')
    check(h.is_big_parameter_rejection(hci.HCI_Error(0x30)), '0x30 out of range = rejection')
    check(not h.is_big_parameter_rejection(hci.HCI_Error(0x07)), '0x07 memory = not a value problem (reset)')
    check(not h.is_big_parameter_rejection(asyncio.TimeoutError()), 'timeout = not a value problem (reset)')

    risky, _ = h.Preset.parse({'rtn': 4, 'max_transport_latency_ms': 5, 'phy': '1M', 'packing': 'interleaved',
                               'presentation_delay_us': 7000, 'frame_duration_us': 7500})
    safe = h.big_fallback_preset(risky)
    check(safe.rtn == 2 and safe.max_transport_latency_ms == 20, 'fallback RTN 2 / 20 ms')
    check(safe.phy == '2M' and safe.packing == 'sequential', 'fallback 2M / sequential')
    check(safe.presentation_delay_us == 7000 and safe.frame_duration_us == 7500, 'codec + PD unchanged')
    check(h.big_fallback_preset(safe) == safe, 'fallback is a fixed point (no endless loop)')
    long_latency, _ = h.Preset.parse({'rtn': 1, 'max_transport_latency_ms': 90})
    check(h.big_fallback_preset(long_latency).max_transport_latency_ms == 40, 'long latency capped at 40 ms')

    message = h.describe_big_error(hci.HCI_Error(0x12), risky)
    check('abgelehnt' in message and 'RTN 4' in message and '5 ms' in message, f'message names values: {message}')
    check('Zeitüberschreitung' in h.describe_big_error(asyncio.TimeoutError(), risky), 'timeout message')
    check('Soll' not in risky.describe_big_request() and 'PHY 1M' in risky.describe_big_request(), 'request text')


def test_explicit_big() -> None:
    print('explicit BIG (LE Create BIG Test) + HCI log')
    preset, adjustments = h.Preset.parse({'big_test': True, 'nse': 5, 'bn': 1, 'irc': 3, 'pto': 1,
                                          'frame_duration_us': 7500})
    check(not adjustments, f'valid explicit layout kept ({adjustments})')
    command = h.make_big_test_command(1, 0, preset, 2, 75, None)
    raw = bytes(command)
    check(raw[0] == 0x01 and raw[1:3] == bytes([0x69, 0x20]) and raw[3] == 36, 'H4 command, opcode 0x2069, 36 parameter bytes')
    check(command.iso_interval == 6 and command.nse == 5 and command.irc == 3 and command.pto == 1,
          'ISO interval 7.5 ms = 6 × 1.25 ms, NSE/IRC/PTO passed through')
    check(command.encryption == 0 and command.broadcast_code == bytes(16), 'open: no code')
    encrypted = h.make_big_test_command(1, 0, preset, 2, 75, 'Passwort')
    check(encrypted.encryption == 1 and encrypted.broadcast_code[:8] == b'Passwort', 'encrypted test BIG')
    fixed, adjustments = h.Preset.parse({'big_test': True, 'nse': 2, 'bn': 2, 'irc': 3, 'pto': 2})
    check(fixed.nse == 6 and fixed.pto == 0, f'NSE raised to BN × IRC, PTO needs NSE > BN × IRC ({adjustments})')
    odd, _ = h.Preset.parse({'big_test': True, 'nse': 7, 'bn': 2, 'irc': 2})
    check(odd.nse == 6, 'NSE rounded to a multiple of BN')
    check(odd.iso_interval_us == 20000, 'BN 2 at 10 ms -> 20 ms ISO interval')
    check(h.big_fallback_preset(preset).big_test is False, 'fallback uses LE Create BIG again')
    text = h.describe_hci_create_big(h.Preset.parse(APP_PRESETS['ultraLow'])[0], 2, 75, None)
    check('SDU-Intervall 7500 µs' in text and 'max. Transportlatenz 20 ms' in text and 'RTN 3' in text
          and 'PD 20 ms' in text and 'Framing unframed' in text, f'HCI parameters logged: {text}')
    note = h.big_rtn_note(h.Preset.parse(APP_PRESETS['ultraLow'])[0], 3)
    check(note is not None and 'IRC 3 statt 4' in note, 'controller lowered RTN is explained')
    check(h.big_rtn_note(h.Preset.parse(APP_PRESETS['balanced'])[0], 3) is None, 'IRC = RTN + 1: no note')


def test_set_jitter() -> None:
    print('live jitter target (Robust bei Aussetzern)')
    ring = h.PcmRing(8, 48000)
    picker = h.FramePicker(ring, 480, 48000 * 30 // 1000, sample_rate=48000)
    check(picker.target == 1440, '30 ms target')
    picker.set_target_ms(90)
    check(picker.target == 4320 and picker.flush_above == 2 * 4320 + picker.window, '90 ms target + flush limit')
    picker.set_target_ms(1)
    check(picker.target == 480, 'target never below one frame')
    engine = h.Engine('serial:/dev/null', 'X', h.DEFAULT_DEVICE_ADDRESS)
    engine.preset = h.Preset()
    engine.picker = picker
    engine.set_jitter(999)
    check(engine.preset.jitter_ms == 250 and picker.target == 12000, 'engine clamps to 250 ms')
    engine.set_jitter(2)
    check(engine.preset.jitter_ms == 10, 'engine clamps to 10 ms')


def main() -> int:
    test_builtin_presets_unchanged()
    test_clamping()
    test_big_parameters()
    test_public_broadcast_flag()
    test_fallback()
    test_explicit_big()
    test_set_jitter()
    print('FAILED:' if FAILURES else 'all preset tests passed', *FAILURES, sep='\n  ')
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())

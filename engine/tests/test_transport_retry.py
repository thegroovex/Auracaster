#!/usr/bin/env python3
# Copyright 2026 Auracaster contributors
# SPDX-License-Identifier: Apache-2.0
"""Transport open retry (v0.1.3): EBUSY and a port that vanishes while the dongle reboots.

Run:  python engine/tests/test_transport_retry.py      (CI: job "engine")
"""

from __future__ import annotations

import asyncio
import errno
import os
import pathlib
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import auracaster_helper as helper  # noqa: E402  pylint: disable=wrong-import-position


def test_classify() -> None:
    busy = OSError(errno.EBUSY, 'Resource busy')
    gone = OSError(errno.ENOENT, 'No such file or directory')
    # pyserial wraps the errno in SerialException with the text only
    wrapped = Exception("could not open port /dev/cu.usbmodem2101: [Errno 2] No such file or directory: '/dev/cu.usbmodem2101'")
    wrapped_busy = Exception('could not open port /dev/cu.usbmodem2101: [Errno 16] Resource busy')
    assert helper.classify_open_error(busy) == 'busy'
    assert helper.classify_open_error(wrapped_busy) == 'busy'
    assert helper.classify_open_error(gone) == 'gone'
    assert helper.classify_open_error(wrapped) == 'gone'
    assert helper.classify_open_error(OSError(errno.ENXIO, 'Device not configured')) == 'gone'
    assert helper.classify_open_error(ValueError('bad spec')) is None
    assert helper.classify_open_error(Exception('[Errno 22] Invalid argument')) is None


def test_port_path() -> None:
    assert helper.serial_port_path('serial:/dev/cu.usbmodem2101,resync') == '/dev/cu.usbmodem2101'
    assert helper.serial_port_path('serial:/dev/cu.usbmodem2101') == '/dev/cu.usbmodem2101'
    assert helper.serial_port_path('usb:0') is None


def test_wait_for_reappearing_port() -> None:
    async def scenario() -> None:
        with tempfile.TemporaryDirectory() as tmp:
            port = os.path.join(tmp, 'cu.usbmodem2101')

            async def reappear() -> None:
                await asyncio.sleep(0.4)
                open(port, 'w').close()

            started = time.monotonic()
            task = asyncio.create_task(reappear())
            ok = await helper.wait_for_serial_port(f'serial:{port},resync', started + 5, poll=0.05)
            await task
            assert ok, 'port reappeared'
            assert 0.4 <= time.monotonic() - started < 2.0
            # never reappears: gives up at the deadline
            missing = os.path.join(tmp, 'missing')
            started = time.monotonic()
            ok = await helper.wait_for_serial_port(f'serial:{missing}', started + 0.3, poll=0.05)
            assert not ok
            assert time.monotonic() - started < 1.0

    asyncio.run(scenario())


def main() -> None:
    test_classify()
    test_port_path()
    test_wait_for_reappearing_port()
    print('transport retry tests ok')


if __name__ == '__main__':
    main()

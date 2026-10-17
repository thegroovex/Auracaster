#!/usr/bin/env python3
# Copyright 2026 Auracaster contributors
# SPDX-License-Identifier: Apache-2.0
"""Firmware identity (HCI vendor command 0xFF50) parsing in the engine helper.

Run:  python engine/tests/test_firmware_info.py      (CI: job "engine")
"""

from __future__ import annotations

import asyncio
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import auracaster_helper as helper  # noqa: E402  pylint: disable=wrong-import-position


def test_parse() -> None:
    data = bytes([0, *b'AURA', 1, 1, 1, 0, 1, 2, 3]) + (0x26000).to_bytes(4, 'little')
    info = helper.parse_auracaster_info(data)
    assert info == {
        'firmware_role': 'dongle',
        'firmware_variant': 's140v6',
        'firmware_version': '0.1.2',
        'firmware_flags': 3,
        'firmware_load_address': '0x26000',
    }, info
    repeater = helper.parse_auracaster_info(bytes([0, *b'AURA', 1, 2, 3, 1, 0, 0, 2]))
    assert repeater is not None and repeater['firmware_role'] == 'repeater'
    assert repeater['firmware_variant'] == 'nosd' and repeater['firmware_version'] == '1.0.0'
    assert helper.parse_auracaster_info(bytes([1, *b'AURA', 1, 1, 1, 0, 1, 2, 3])) is None  # status
    assert helper.parse_auracaster_info(bytes([0, *b'XXXX', 1, 1, 1, 0, 1, 2, 3])) is None  # magic
    assert helper.parse_auracaster_info(b'\x00AURA') is None
    assert helper.parse_auracaster_info(None) is None


class FakeHost:
    def __init__(self, response: object) -> None:
        self.response = response
        self.sent: list[object] = []

    async def send_command(self, command: object, response_timeout: float | None = None) -> object:
        self.sent.append(command)
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


def test_read() -> None:
    class Params:
        data = bytes([0, *b'AURA', 1, 1, 2, 0, 1, 2, 3])

    class Complete:
        return_parameters = Params()

    host = FakeHost(Complete())
    info = asyncio.run(helper.read_auracaster_info(host))
    assert info['firmware_variant'] == 's140v7', info
    command = host.sent[0]
    assert getattr(command, 'op_code') == helper.AURA_OP_READ_INFO
    assert bytes(command)[:4] == bytes([0x01, 0x50, 0xFF, 0x00]), bytes(command)

    class Status:  # firmware <= 0.1.1: Command Status "Unknown HCI Command"
        status = 0x01

    assert asyncio.run(helper.read_auracaster_info(FakeHost(Status()))) == {'firmware_legacy': True}
    assert asyncio.run(helper.read_auracaster_info(FakeHost(TimeoutError()))) == {'firmware_legacy': True}


if __name__ == '__main__':
    test_parse()
    test_read()
    print('firmware info tests ok')

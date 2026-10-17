# SPDX-License-Identifier: Apache-2.0
#
# Auracaster dongle: Zephyr LE Audio broadcast controller (HCI H4 over USB CDC ACM)

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(auracaster_dongle)

target_sources(app PRIVATE src/main.c src/status_led.c common/auracaster_fw.c)
target_include_directories(app PRIVATE common)
# firmware identity reported to the Mac app (common/auracaster_fw.h)
target_compile_definitions(app PRIVATE AURA_FW_ROLE=1)

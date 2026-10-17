# SPDX-License-Identifier: Apache-2.0
#
# Auracaster Repeater: standalone Auracast relay (BIG sync -> BIG create,
# LC3 SDUs forwarded unchanged). Shares firmware/west.yml with the dongle.

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(auracaster_repeater)

target_sources(app PRIVATE src/main.c src/led.c src/host_link.c ../common/auracaster_fw.c)
target_include_directories(app PRIVATE ../common)
# firmware identity reported to the Mac app (common/auracaster_fw.h)
target_compile_definitions(app PRIVATE AURA_FW_ROLE=2)

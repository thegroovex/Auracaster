# SPDX-License-Identifier: Apache-2.0
#
# Auracaster Repeater: standalone Auracast relay (BIG sync -> BIG create,
# LC3 SDUs forwarded unchanged). Shares firmware/west.yml with the dongle.

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(auracaster_repeater)

target_sources(app PRIVATE src/main.c src/led.c)

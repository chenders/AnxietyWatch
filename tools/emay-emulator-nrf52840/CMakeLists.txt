# SPDX-License-Identifier: MIT
# Zephyr app: EMAY SleepO2 BLE emulator for the Raytac MDBT50Q-CX (nRF52840) dongle.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(emay_emulator LANGUAGES C)

target_sources(app PRIVATE src/main.c)

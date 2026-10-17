/*
 * Auracaster firmware identity + reboot into the UF2 bootloader.
 * See auracaster_fw.h.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/linker/linker-defs.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>

#include <soc.h>
#include <app_version.h>

#include "auracaster_fw.h"

#ifndef AURA_FW_ROLE
#error "AURA_FW_ROLE must be defined by the application's CMakeLists.txt"
#endif

#define AURA_TOUCH_BAUD 1200U

uint32_t aura_fw_load_address(void)
{
	/* Start of the application image = vector table (XIP). */
	return (uint32_t)(uintptr_t)_vector_start;
}

uint8_t aura_fw_variant(void)
{
	switch (aura_fw_load_address()) {
	case 0x26000:
		return AURA_FW_VARIANT_S140V6;
	case 0x27000:
		return AURA_FW_VARIANT_S140V7;
	case 0x1000:
		return AURA_FW_VARIANT_NOSD;
	default:
		return AURA_FW_VARIANT_UNKNOWN;
	}
}

const char *aura_fw_variant_name(void)
{
	switch (aura_fw_variant()) {
	case AURA_FW_VARIANT_S140V6:
		return "s140v6";
	case AURA_FW_VARIANT_S140V7:
		return "s140v7";
	case AURA_FW_VARIANT_NOSD:
		return "nosd";
	default:
		return "unknown";
	}
}

const char *aura_fw_role_name(void)
{
	return AURA_FW_ROLE == AURA_FW_ROLE_REPEATER ? "repeater" : "dongle";
}

const char *aura_fw_version_string(void)
{
	return APP_VERSION_STRING;
}

void aura_fw_info(uint8_t out[AURA_FW_INFO_LEN])
{
	memcpy(out, "AURA", 4);
	out[4] = AURA_FW_INFO_PROTOCOL;
	out[5] = AURA_FW_ROLE;
	out[6] = aura_fw_variant();
	out[7] = APP_VERSION_MAJOR;
	out[8] = APP_VERSION_MINOR;
	out[9] = APP_PATCHLEVEL;
	out[10] = AURA_FW_FLAG_TOUCH_1200 |
		  (AURA_FW_ROLE == AURA_FW_ROLE_DONGLE ? AURA_FW_FLAG_BOOTLOADER_CMD : 0);
	sys_put_le32(aura_fw_load_address(), &out[11]);
}

FUNC_NORETURN void aura_fw_enter_uf2_bootloader(void)
{
	(void)irq_lock();
	/* Read by the Adafruit nRF52 bootloader right after reset; it clears
	 * the register itself. sys_reboot() is not used because Zephyr may
	 * store its own reboot type in GPREGRET.
	 */
	NRF_POWER->GPREGRET = AURA_UF2_RESET_MAGIC;
	NVIC_SystemReset();
	CODE_UNREACHABLE;
}

uint32_t aura_fw_touch_poll(const struct device *cdc)
{
	uint32_t dtr = 0U;
	uint32_t baud = 0U;

	if (cdc == NULL || !device_is_ready(cdc)) {
		return 0U;
	}
	(void)uart_line_ctrl_get(cdc, UART_LINE_CTRL_DTR, &dtr);
	if (uart_line_ctrl_get(cdc, UART_LINE_CTRL_BAUD_RATE, &baud) == 0 &&
	    baud == AURA_TOUCH_BAUD && dtr == 0U) {
		/* let the USB stack ACK the control transfer */
		k_msleep(50);
		aura_fw_enter_uf2_bootloader();
	}
	return dtr;
}

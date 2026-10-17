/*
 * Auracaster firmware identity + "reboot into the UF2 bootloader" (v0.1.2).
 * Shared by the dongle (firmware/) and the repeater (firmware/repeater/).
 *
 * The Mac app uses this to update boards without touching the reset pin:
 *  - HCI vendor command AURA_OP_READ_INFO (dongle): role, variant, version
 *  - HCI vendor command AURA_OP_ENTER_BOOTLOADER (dongle)
 *  - "1200 baud touch" on the USB CDC ACM port (dongle + repeater): open the
 *    port, set 1200 baud, close it (DTR 1 -> 0)
 *  - "@AURA id ..." line on the console when the host opens the port (repeater)
 *
 * Entering the bootloader writes 0x57 (DFU_MAGIC_UF2_RESET) to
 * NRF_POWER->GPREGRET and soft-resets. The Adafruit nRF52 bootloader
 * (nice!nano / Pro Micro) then starts in UF2 mode (drive + CDC). A soft
 * reset never counts as "double reset" there (that needs RESETREAS.RESETPIN),
 * which is why firmware <= 0.1.1 cannot be sent to the bootloader remotely.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef AURACASTER_FW_H_
#define AURACASTER_FW_H_

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/device.h>
#include <zephyr/sys/util_macro.h>
#include <zephyr/toolchain.h>

#define AURA_FW_ROLE_DONGLE   1
#define AURA_FW_ROLE_REPEATER 2

#define AURA_FW_VARIANT_UNKNOWN 0
#define AURA_FW_VARIANT_S140V6  1 /* app at 0x26000 */
#define AURA_FW_VARIANT_S140V7  2 /* app at 0x27000 */
#define AURA_FW_VARIANT_NOSD    3 /* app at 0x1000  */

#define AURA_FW_FLAG_BOOTLOADER_CMD BIT(0) /* AURA_OP_ENTER_BOOTLOADER   */
#define AURA_FW_FLAG_TOUCH_1200     BIT(1) /* 1200 baud touch            */

/* HCI vendor commands (OGF 0x3F): opcode 0xFC00 | OCF */
#define AURA_OP_READ_INFO        0xFF50 /* OCF 0x350 */
#define AURA_OP_ENTER_BOOTLOADER 0xFF51 /* OCF 0x351 */

#define AURA_FW_INFO_PROTOCOL 1
/* Return parameters of AURA_OP_READ_INFO after the status byte */
#define AURA_FW_INFO_LEN 15

#define AURA_UF2_RESET_MAGIC 0x57 /* DFU_MAGIC_UF2_RESET (Adafruit bootloader) */

uint32_t aura_fw_load_address(void);
uint8_t aura_fw_variant(void);
const char *aura_fw_variant_name(void);
const char *aura_fw_role_name(void);
const char *aura_fw_version_string(void);

/* "AURA", protocol, role, variant, major, minor, patch, flags, load address (LE32) */
void aura_fw_info(uint8_t out[AURA_FW_INFO_LEN]);

/* GPREGRET = 0x57 + soft reset. Does not return. */
FUNC_NORETURN void aura_fw_enter_uf2_bootloader(void);

/*
 * 1200 baud touch: call periodically (e.g. every 100 ms) with the CDC ACM
 * device. Enters the bootloader when the host set 1200 baud and dropped DTR.
 * Returns the current DTR state.
 */
uint32_t aura_fw_touch_poll(const struct device *cdc);

#endif /* AURACASTER_FW_H_ */

/*
 * Auracaster Repeater
 *
 * Standalone Auracast relay for a second Pro Micro nRF52840:
 *
 *   scan (EA with Broadcast Audio Announcement 0x1852)
 *     -> PA sync (BASE in 0x1851 service data, BIGInfo in ACAD)
 *     -> BIG sync, all BIS (optionally encrypted)
 *     -> own EA + PA (copied BASE) + BIG with the same SDU interval, max SDU,
 *        framing and BIS count
 *     -> every received LC3 SDU is handed to the relay BIS unchanged.
 *
 * Plain bt_iso / bt_le_per_adv_sync are used instead of the BAP broadcast
 * sink/source: the BAP sink needs PACS, a scan delegator and a connectable
 * GATT server, the BAP source would rebuild the BASE from parsed codec
 * structs. The raw path copies the BASE byte for byte and keeps the hot path
 * to one memcpy per SDU.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <errno.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/net_buf.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/util.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/drivers/watchdog.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gap.h>
#include <zephyr/bluetooth/hci_types.h>
#include <zephyr/bluetooth/iso.h>
#include <zephyr/bluetooth/uuid.h>

#include "led.h"

LOG_MODULE_REGISTER(repeater, LOG_LEVEL_INF);

#define MAX_BIS           CONFIG_AURACAST_REPEATER_MAX_BIS
#define MAX_INFLIGHT      CONFIG_AURACAST_REPEATER_MAX_INFLIGHT
#define MAX_BURST         7 /* BN max: SDUs per source BIG event */
#define AD_BUF_LEN        CONFIG_BT_CTLR_ADV_DATA_LEN_MAX
#define SCAN_AD_LEN       255
#define NAME_MAX_LEN      32 /* Broadcast Name: 4..32 octets */
#define CANDIDATE_MAX     4
#define BLOCKLIST_MAX     4
#define BLOCK_TIME_MS     30000
#define PA_SYNC_WAIT_MS   5000
#define BIGINFO_WAIT_MS   5000
#define BIS_WAIT_MS       5000
#define TERM_WAIT_MS      2000

BUILD_ASSERT(CONFIG_BT_ISO_MAX_CHAN >= 2 * MAX_BIS, "need RX + TX channels");
BUILD_ASSERT(sizeof(CONFIG_AURACAST_REPEATER_BROADCAST_CODE) - 1 <= BT_ISO_BROADCAST_CODE_SIZE,
	     "Broadcast Code longer than 16 bytes");
BUILD_ASSERT(sizeof(CONFIG_AURACAST_REPEATER_NAME) - 1 <= NAME_MAX_LEN,
	     "relay name longer than 32 bytes");

/* ------------------------------------------------------------------------- */
/* Events from Bluetooth callbacks to the repeater thread                    */
/* ------------------------------------------------------------------------- */

#define EV_PA_SYNCED  BIT(0)
#define EV_PA_TERM    BIT(1)
#define EV_BIGINFO    BIT(2)
#define EV_PA_DATA    BIT(3)
#define EV_RX_LOST    BIT(4)
#define EV_TX_LOST    BIT(5)

static K_EVENT_DEFINE(ev);
static K_SEM_DEFINE(rx_conn_sem, 0, MAX_BIS);
static K_SEM_DEFINE(rx_disc_sem, 0, MAX_BIS);
static K_SEM_DEFINE(tx_conn_sem, 0, MAX_BIS);
static K_SEM_DEFINE(tx_disc_sem, 0, MAX_BIS);

/* ------------------------------------------------------------------------- */
/* Source candidates from the scanner                                        */
/* ------------------------------------------------------------------------- */

struct candidate {
	bool used;
	bool prefix_match;
	bt_addr_le_t addr;
	uint8_t sid;
	int8_t rssi;
	uint16_t pa_interval; /* 1.25 ms units */
	uint32_t broadcast_id;
	char name[NAME_MAX_LEN + 1];
	uint8_t ad[SCAN_AD_LEN];
	uint8_t ad_len;
};

struct blocked {
	bt_addr_le_t addr;
	int64_t until;
};

static struct k_spinlock cand_lock;
static struct candidate candidates[CANDIDATE_MAX];
static struct blocked blocklist[BLOCKLIST_MAX];
static struct candidate source; /* the chosen one (copy) */

/* ------------------------------------------------------------------------- */
/* Source side: PA sync + BIG sync                                           */
/* ------------------------------------------------------------------------- */

static struct bt_le_per_adv_sync *volatile pa_sync;
static struct bt_iso_big *rx_big;

static struct k_spinlock pa_lock;
static struct bt_iso_biginfo biginfo;
static uint8_t pa_data[AD_BUF_LEN];
static uint8_t pa_data_len;

/* Parameters the relay BIG was built from; a resync to a source with the
 * same values keeps the relay (and the receivers on it) running.
 */
struct stream_sig {
	uint8_t num_bis;
	uint32_t sdu_interval;
	uint16_t max_sdu;
	uint8_t framing;
	bool encryption;
};

static struct stream_sig rx_sig;
static struct stream_sig tx_sig;

/* ------------------------------------------------------------------------- */
/* Relay side: EA + PA + BIG                                                 */
/* ------------------------------------------------------------------------- */

static struct bt_le_ext_adv *relay_adv;
static struct bt_iso_big *tx_big;
static bool relay_active;
static int64_t grace_deadline;
static uint32_t relay_broadcast_id;
static uint8_t bcode[BT_ISO_BROADCAST_CODE_SIZE];

static uint8_t ea_raw[AD_BUF_LEN];
static size_t ea_raw_len;
static uint8_t pa_raw[AD_BUF_LEN];
static size_t pa_raw_len;

/* Hot path state */
static atomic_t forwarding;
static atomic_t inflight[MAX_BIS];
/* Source BIG with BN > 1 (ISO interval = n x SDU interval) delivers n SDUs
 * per BIS at once; they leave in n consecutive relay events.
 */
static atomic_t inflight_limit = ATOMIC_INIT(MAX_INFLIGHT);
static atomic_t last_rx_ms;

static atomic_t st_rx_ok;
static atomic_t st_rx_bad;
static atomic_t st_tx_ok;
static atomic_t st_tx_drop;
static atomic_t st_tx_err;

NET_BUF_POOL_FIXED_DEFINE(tx_pool, MAX_BIS * (MAX_BURST + MAX_INFLIGHT),
			  BT_ISO_SDU_BUF_SIZE(CONFIG_BT_ISO_TX_MTU),
			  CONFIG_BT_CONN_TX_USER_DATA_SIZE, NULL);

static struct bt_iso_chan rx_chan[MAX_BIS];
static struct bt_iso_chan tx_chan[MAX_BIS];
static struct bt_iso_chan *rx_chan_p[MAX_BIS];
static struct bt_iso_chan *tx_chan_p[MAX_BIS];
static struct bt_iso_chan_io_qos rx_io_qos;
static struct bt_iso_chan_io_qos tx_io_qos;
static struct bt_iso_chan_qos rx_qos = { .rx = &rx_io_qos };
static struct bt_iso_chan_qos tx_qos = { .tx = &tx_io_qos };

/* ------------------------------------------------------------------------- */
/* Watchdog                                                                  */
/* ------------------------------------------------------------------------- */

#if defined(CONFIG_AURACAST_REPEATER_HW_WATCHDOG) && DT_NODE_HAS_STATUS_OKAY(DT_ALIAS(watchdog0))
static const struct device *const wdt = DEVICE_DT_GET(DT_ALIAS(watchdog0));
static int wdt_channel = -1;

static void watchdog_init(void)
{
	struct wdt_timeout_cfg cfg = {
		.window = { .min = 0U, .max = 8000U },
		.callback = NULL,
		.flags = WDT_FLAG_RESET_SOC,
	};

	if (!device_is_ready(wdt)) {
		LOG_WRN("watchdog not ready");
		return;
	}

	wdt_channel = wdt_install_timeout(wdt, &cfg);
	if (wdt_channel < 0 || wdt_setup(wdt, WDT_OPT_PAUSE_HALTED_BY_DBG) != 0) {
		LOG_WRN("watchdog setup failed (%d)", wdt_channel);
		wdt_channel = -1;
	}
}

static void watchdog_feed(void)
{
	if (wdt_channel >= 0) {
		(void)wdt_feed(wdt, wdt_channel);
	}
}
#else
static void watchdog_init(void) {}
static void watchdog_feed(void) {}
#endif

/* Sleep in small slices so the watchdog is fed while waiting. */
static void sleep_fed(uint32_t ms)
{
	while (ms > 0U) {
		uint32_t step = MIN(ms, 500U);

		watchdog_feed();
		k_msleep(step);
		ms -= step;
	}
	watchdog_feed();
}

static int sem_take_fed(struct k_sem *sem, uint32_t ms)
{
	int64_t end = k_uptime_get() + ms;

	do {
		watchdog_feed();
		if (k_sem_take(sem, K_MSEC(200)) == 0) {
			return 0;
		}
	} while (k_uptime_get() < end);

	return -ETIMEDOUT;
}

static uint32_t event_wait_fed(uint32_t mask, uint32_t ms)
{
	int64_t end = k_uptime_get() + ms;
	uint32_t got;

	do {
		watchdog_feed();
		got = k_event_wait(&ev, mask, false, K_MSEC(200));
		if (got) {
			return got;
		}
	} while (k_uptime_get() < end);

	return 0U;
}

/* Controller assertion: log it (visible on the USB console) and reboot. */
void bt_ctlr_assert_handle(char *file, uint32_t line)
{
	LOG_ERR("controller assert %s:%u", file, line);
	LOG_PANIC();
	k_busy_wait(200000);
	sys_reboot(SYS_REBOOT_COLD);
}

/* ------------------------------------------------------------------------- */
/* Advertising data helpers                                                  */
/* ------------------------------------------------------------------------- */

/* Walk raw AD structures: cb(type, data, len) returns false to stop. */
static void ad_walk(const uint8_t *ad, size_t len,
		    bool (*cb)(uint8_t type, const uint8_t *data, uint8_t len, void *ud), void *ud)
{
	size_t i = 0U;

	while (i < len) {
		uint8_t field_len = ad[i];

		if (field_len == 0U) {
			break; /* early termination */
		}
		if (i + 1U + field_len > len) {
			break; /* malformed */
		}
		if (!cb(ad[i + 1U], &ad[i + 2U], field_len - 1U, ud)) {
			break;
		}
		i += 1U + field_len;
	}
}

struct ea_info {
	bool is_auracast;
	uint32_t broadcast_id;
	char name[NAME_MAX_LEN + 1];
	bool has_bcast_name;
};

static bool ea_info_cb(uint8_t type, const uint8_t *data, uint8_t len, void *ud)
{
	struct ea_info *info = ud;
	uint8_t n;

	switch (type) {
	case BT_DATA_SVC_DATA16:
		if (len >= 5U && sys_get_le16(data) == BT_UUID_BROADCAST_AUDIO_VAL) {
			info->is_auracast = true;
			info->broadcast_id = sys_get_le24(&data[2]);
		}
		break;
	case BT_DATA_BROADCAST_NAME:
		n = MIN(len, NAME_MAX_LEN);
		memcpy(info->name, data, n);
		info->name[n] = '\0';
		info->has_bcast_name = true;
		break;
	case BT_DATA_NAME_COMPLETE:
	case BT_DATA_NAME_SHORTENED:
		if (!info->has_bcast_name) {
			n = MIN(len, NAME_MAX_LEN);
			memcpy(info->name, data, n);
			info->name[n] = '\0';
		}
		break;
	default:
		break;
	}

	return true;
}

static bool str_ends_with(const char *s, const char *suffix)
{
	size_t ls = strlen(s);
	size_t lx = strlen(suffix);

	return lx > 0U && ls >= lx && memcmp(&s[ls - lx], suffix, lx) == 0;
}

static bool name_matches_prefix(const char *name)
{
	const char *prefix = CONFIG_AURACAST_REPEATER_SOURCE_NAME_PREFIX;

	return strncmp(name, prefix, strlen(prefix)) == 0;
}

/* Append one AD structure, return false when out of room. */
static bool ad_put(uint8_t *buf, size_t *len, size_t max, uint8_t type, const void *data,
		   size_t data_len)
{
	if (*len + 2U + data_len > max) {
		return false;
	}
	buf[(*len)++] = (uint8_t)(data_len + 1U);
	buf[(*len)++] = type;
	memcpy(&buf[*len], data, data_len);
	*len += data_len;
	return true;
}

struct ea_copy_ctx {
	uint8_t *buf;
	size_t *len;
};

/* Copy everything from the source EA except what identifies the source:
 * names and the Broadcast Audio Announcement (Broadcast ID). Appearance and
 * the Public Broadcast Announcement (features + metadata) stay unchanged.
 */
static bool ea_copy_cb(uint8_t type, const uint8_t *data, uint8_t len, void *ud)
{
	struct ea_copy_ctx *ctx = ud;

	switch (type) {
	case BT_DATA_NAME_COMPLETE:
	case BT_DATA_NAME_SHORTENED:
	case BT_DATA_BROADCAST_NAME:
		return true;
	case BT_DATA_SVC_DATA16:
		if (len >= 2U && sys_get_le16(data) == BT_UUID_BROADCAST_AUDIO_VAL) {
			return true;
		}
		break;
	default:
		break;
	}

	(void)ad_put(ctx->buf, ctx->len, AD_BUF_LEN, type, data, len);
	return true;
}

static void relay_name(char *out)
{
	const char *fixed = CONFIG_AURACAST_REPEATER_NAME;

	if (fixed[0] != '\0') {
		strncpy(out, fixed, NAME_MAX_LEN);
		out[NAME_MAX_LEN] = '\0';
		return;
	}

	const char *suffix = CONFIG_AURACAST_REPEATER_NAME_SUFFIX;
	size_t ls = strlen(suffix);
	size_t ln = strlen(source.name);

	if (ln + ls > NAME_MAX_LEN) {
		ln = NAME_MAX_LEN - ls;
	}
	memcpy(out, source.name, ln);
	memcpy(&out[ln], suffix, ls);
	out[ln + ls] = '\0';

	/* Broadcast Name needs at least 4 octets */
	while (strlen(out) < 4U) {
		strcat(out, " ");
	}
}

static void build_ea(void)
{
	struct ea_copy_ctx ctx = { .buf = ea_raw, .len = &ea_raw_len };
	char name[NAME_MAX_LEN + 1];
	uint8_t baa[5];

	ea_raw_len = 0U;

	sys_put_le16(BT_UUID_BROADCAST_AUDIO_VAL, baa);
	sys_put_le24(relay_broadcast_id, &baa[2]);
	(void)ad_put(ea_raw, &ea_raw_len, AD_BUF_LEN, BT_DATA_SVC_DATA16, baa, sizeof(baa));

	relay_name(name);
	(void)ad_put(ea_raw, &ea_raw_len, AD_BUF_LEN, BT_DATA_BROADCAST_NAME, name, strlen(name));

	ad_walk(source.ad, source.ad_len, ea_copy_cb, &ctx);

	(void)ad_put(ea_raw, &ea_raw_len, AD_BUF_LEN, BT_DATA_NAME_COMPLETE,
		     CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1U);

	LOG_INF("relay \"%s\", Broadcast ID 0x%06x", name, relay_broadcast_id);
}

/* Copy the source PA (BASE), optionally with a new Presentation Delay. */
static void build_pa(void)
{
	k_spinlock_key_t key = k_spin_lock(&pa_lock);

	memcpy(pa_raw, pa_data, pa_data_len);
	pa_raw_len = pa_data_len;
	k_spin_unlock(&pa_lock, key);

	for (size_t i = 0U; i + 1U < pa_raw_len;) {
		uint8_t field_len = pa_raw[i];

		if (field_len == 0U || i + 1U + field_len > pa_raw_len) {
			break;
		}
		uint8_t *d = &pa_raw[i + 2U];

		if (pa_raw[i + 1U] == BT_DATA_SVC_DATA16 && field_len >= 6U &&
		    sys_get_le16(d) == BT_UUID_BASIC_AUDIO_VAL) {
			uint32_t pd = sys_get_le24(&d[2]);

			if (CONFIG_AURACAST_REPEATER_PRESENTATION_DELAY_US > 0) {
				sys_put_le24(CONFIG_AURACAST_REPEATER_PRESENTATION_DELAY_US, &d[2]);
				LOG_INF("BASE presentation delay %u -> %u us", pd,
					CONFIG_AURACAST_REPEATER_PRESENTATION_DELAY_US);
			} else {
				LOG_INF("BASE presentation delay %u us (copied)", pd);
			}
		}
		i += 1U + field_len;
	}
}

/* bt_data views onto a raw AD buffer (the stack copies the data). */
struct ad_view_ctx {
	struct bt_data *out;
	size_t count;
	size_t max;
};

static bool ad_view_cb(uint8_t type, const uint8_t *data, uint8_t len, void *ud)
{
	struct ad_view_ctx *ctx = ud;

	if (ctx->count >= ctx->max) {
		return false;
	}
	ctx->out[ctx->count].type = type;
	ctx->out[ctx->count].data_len = len;
	ctx->out[ctx->count].data = data;
	ctx->count++;
	return true;
}

static size_t ad_view(const uint8_t *raw, size_t len, struct bt_data *out, size_t max)
{
	struct ad_view_ctx ctx = { .out = out, .count = 0U, .max = max };

	ad_walk(raw, len, ad_view_cb, &ctx);
	return ctx.count;
}

/* ------------------------------------------------------------------------- */
/* Scanner                                                                   */
/* ------------------------------------------------------------------------- */

static bool is_own_address(const bt_addr_le_t *addr)
{
	bt_addr_le_t ids[CONFIG_BT_ID_MAX];
	size_t count = ARRAY_SIZE(ids);

	bt_id_get(ids, &count);
	for (size_t i = 0U; i < count; i++) {
		if (bt_addr_le_eq(&ids[i], addr)) {
			return true;
		}
	}
	return false;
}

static bool is_blocked(const bt_addr_le_t *addr)
{
	int64_t now = k_uptime_get();

	for (size_t i = 0U; i < BLOCKLIST_MAX; i++) {
		if (blocklist[i].until > now && bt_addr_le_eq(&blocklist[i].addr, addr)) {
			return true;
		}
	}
	return false;
}

static void block_source(const bt_addr_le_t *addr)
{
	size_t oldest = 0U;

	for (size_t i = 1U; i < BLOCKLIST_MAX; i++) {
		if (blocklist[i].until < blocklist[oldest].until) {
			oldest = i;
		}
	}
	bt_addr_le_copy(&blocklist[oldest].addr, addr);
	blocklist[oldest].until = k_uptime_get() + BLOCK_TIME_MS;
}

static void scan_recv(const struct bt_le_scan_recv_info *info, struct net_buf_simple *buf)
{
	struct ea_info ea = { 0 };

	if (info->interval == 0U || (info->adv_props & BT_GAP_ADV_PROP_CONNECTABLE) ||
	    buf->len == 0U || buf->len > SCAN_AD_LEN) {
		return; /* Auracast: non-connectable EA with periodic advertising */
	}

	ad_walk(buf->data, buf->len, ea_info_cb, &ea);
	if (!ea.is_auracast) {
		return;
	}
	if (str_ends_with(ea.name, CONFIG_AURACAST_REPEATER_NAME_SUFFIX)) {
		return; /* another repeater (or ourselves): never chain relays */
	}
	if (relay_active && ea.broadcast_id == relay_broadcast_id) {
		return;
	}
	if (is_own_address(info->addr) || is_blocked(info->addr)) {
		return;
	}

	k_spinlock_key_t key = k_spin_lock(&cand_lock);
	struct candidate *c = NULL;
	struct candidate *weakest = NULL;

	for (size_t i = 0U; i < CANDIDATE_MAX; i++) {
		struct candidate *it = &candidates[i];

		if (it->used && bt_addr_le_eq(&it->addr, info->addr) && it->sid == info->sid) {
			c = it;
			break;
		}
		if (!it->used) {
			if (weakest == NULL || weakest->used) {
				weakest = it;
			}
		} else if (weakest == NULL || (weakest->used && it->rssi < weakest->rssi)) {
			weakest = it;
		}
	}

	if (c == NULL) {
		if (weakest->used && weakest->rssi >= info->rssi) {
			k_spin_unlock(&cand_lock, key);
			return;
		}
		c = weakest;
		memset(c, 0, sizeof(*c));
		c->used = true;
		bt_addr_le_copy(&c->addr, info->addr);
		c->sid = info->sid;
		c->rssi = info->rssi;
	} else {
		/* smooth RSSI */
		c->rssi = (int8_t)((3 * (int)c->rssi + (int)info->rssi) / 4);
	}

	c->pa_interval = info->interval;
	c->broadcast_id = ea.broadcast_id;
	memcpy(c->name, ea.name, sizeof(c->name));
	c->prefix_match = name_matches_prefix(ea.name);
	memcpy(c->ad, buf->data, buf->len);
	c->ad_len = (uint8_t)buf->len;

	k_spin_unlock(&cand_lock, key);
}

static struct bt_le_scan_cb scan_cb = {
	.recv = scan_recv,
};

static void candidates_clear(void)
{
	k_spinlock_key_t key = k_spin_lock(&cand_lock);

	memset(candidates, 0, sizeof(candidates));
	k_spin_unlock(&cand_lock, key);
}

/* Prefix matches first (strongest of them); otherwise the strongest of all
 * if the fallback is enabled.
 */
static bool candidates_pick(struct candidate *out)
{
	k_spinlock_key_t key = k_spin_lock(&cand_lock);
	struct candidate *best_match = NULL;
	struct candidate *best_any = NULL;

	for (size_t i = 0U; i < CANDIDATE_MAX; i++) {
		struct candidate *c = &candidates[i];

		if (!c->used) {
			continue;
		}
		if (c->prefix_match && (best_match == NULL || c->rssi > best_match->rssi)) {
			best_match = c;
		}
		if (best_any == NULL || c->rssi > best_any->rssi) {
			best_any = c;
		}
	}

	struct candidate *pick = best_match;

	if (pick == NULL && IS_ENABLED(CONFIG_AURACAST_REPEATER_FALLBACK_STRONGEST)) {
		pick = best_any;
	}
	if (pick != NULL) {
		*out = *pick;
	}
	k_spin_unlock(&cand_lock, key);

	return pick != NULL;
}

static int scan_start(void)
{
	/* Continuous passive scan, no duplicate filter (RSSI updates). */
	struct bt_le_scan_param param = {
		.type = BT_LE_SCAN_TYPE_PASSIVE,
		.options = BT_LE_SCAN_OPT_NONE,
		.interval = 0x0060,
		.window = 0x0060,
	};
	int err = bt_le_scan_start(&param, NULL);

	if (err == -EALREADY) {
		err = 0;
	}
	return err;
}

static void scan_stop(void)
{
	int err = bt_le_scan_stop();

	if (err && err != -EALREADY) {
		LOG_WRN("scan stop failed (%d)", err);
	}
}

/* ------------------------------------------------------------------------- */
/* Periodic advertising sync callbacks                                       */
/* ------------------------------------------------------------------------- */

static void pa_synced_cb(struct bt_le_per_adv_sync *sync,
			 struct bt_le_per_adv_sync_synced_info *info)
{
	LOG_INF("PA synced, interval %u x 1.25 ms, PHY %u", info->interval, info->phy);
	k_event_post(&ev, EV_PA_SYNCED);
}

static void pa_term_cb(struct bt_le_per_adv_sync *sync,
		       const struct bt_le_per_adv_sync_term_info *info)
{
	LOG_INF("PA sync terminated (reason 0x%02x)", info->reason);
	if (sync == pa_sync) {
		pa_sync = NULL;
	}
	k_event_post(&ev, EV_PA_TERM);
}

static void pa_recv_cb(struct bt_le_per_adv_sync *sync,
		       const struct bt_le_per_adv_sync_recv_info *info, struct net_buf_simple *buf)
{
	if (buf->len == 0U || buf->len > sizeof(pa_data)) {
		return;
	}

	k_spinlock_key_t key = k_spin_lock(&pa_lock);
	bool changed = (buf->len != pa_data_len) || memcmp(pa_data, buf->data, buf->len) != 0;

	if (changed) {
		memcpy(pa_data, buf->data, buf->len);
		pa_data_len = (uint8_t)buf->len;
	}
	k_spin_unlock(&pa_lock, key);

	if (changed || !(k_event_test(&ev, EV_PA_DATA))) {
		k_event_post(&ev, EV_PA_DATA);
	}
}

static void pa_biginfo_cb(struct bt_le_per_adv_sync *sync, const struct bt_iso_biginfo *info)
{
	if (k_event_test(&ev, EV_BIGINFO)) {
		return;
	}

	k_spinlock_key_t key = k_spin_lock(&pa_lock);

	biginfo = *info;
	k_spin_unlock(&pa_lock, key);

	k_event_post(&ev, EV_BIGINFO);
}

static struct bt_le_per_adv_sync_cb pa_cb = {
	.synced = pa_synced_cb,
	.term = pa_term_cb,
	.recv = pa_recv_cb,
	.biginfo = pa_biginfo_cb,
};

/* ------------------------------------------------------------------------- */
/* ISO: received source BIS -> relay BIS                                     */
/* ------------------------------------------------------------------------- */

static void rx_connected(struct bt_iso_chan *chan)
{
	const struct bt_iso_chan_path hci_path = {
		.pid = BT_ISO_DATA_PATH_HCI,
		.format = BT_HCI_CODING_FORMAT_TRANSPARENT,
	};
	int err = bt_iso_setup_data_path(chan, BT_HCI_DATAPATH_DIR_CTLR_TO_HOST, &hci_path);

	if (err) {
		LOG_ERR("RX data path failed (%d)", err);
	}
	k_sem_give(&rx_conn_sem);
}

static void rx_disconnected(struct bt_iso_chan *chan, uint8_t reason)
{
	LOG_INF("source BIS %u disconnected (0x%02x)", (unsigned int)(chan - rx_chan) + 1U,
		reason);
	k_sem_give(&rx_disc_sem);
	k_event_post(&ev, EV_RX_LOST);
}

static void rx_recv(struct bt_iso_chan *chan, const struct bt_iso_recv_info *info,
		    struct net_buf *buf)
{
	size_t idx = (size_t)(chan - rx_chan);

	if (idx >= MAX_BIS) {
		return;
	}

	if (!(info->flags & BT_ISO_FLAGS_VALID) || buf->len == 0U) {
		/* Lost/corrupt SDU: send nothing, the receivers conceal it (PLC). */
		atomic_inc(&st_rx_bad);
		return;
	}

	atomic_inc(&st_rx_ok);
	atomic_set(&last_rx_ms, (atomic_val_t)k_uptime_get_32());

	if (!atomic_get(&forwarding)) {
		return;
	}

	/* Bounded queue: the two BIGs run on different clocks. */
	if (atomic_get(&inflight[idx]) >= atomic_get(&inflight_limit)) {
		atomic_inc(&st_tx_drop);
		return;
	}

	struct net_buf *tx = net_buf_alloc(&tx_pool, K_NO_WAIT);

	if (tx == NULL) {
		atomic_inc(&st_tx_drop);
		return;
	}

	net_buf_reserve(tx, BT_ISO_CHAN_SEND_RESERVE);
	net_buf_add_mem(tx, buf->data, MIN(buf->len, (size_t)CONFIG_BT_ISO_TX_MTU));

	atomic_inc(&inflight[idx]);
	int err = bt_iso_chan_send(&tx_chan[idx], tx, info->seq_num);

	if (err < 0) {
		atomic_dec(&inflight[idx]);
		net_buf_unref(tx);
		atomic_inc(&st_tx_err);
	}
}

static void tx_connected(struct bt_iso_chan *chan)
{
	const struct bt_iso_chan_path hci_path = {
		.pid = BT_ISO_DATA_PATH_HCI,
		.format = BT_HCI_CODING_FORMAT_TRANSPARENT,
	};
	int err = bt_iso_setup_data_path(chan, BT_HCI_DATAPATH_DIR_HOST_TO_CTLR, &hci_path);

	if (err) {
		LOG_ERR("TX data path failed (%d)", err);
	}
	k_sem_give(&tx_conn_sem);
}

static void tx_disconnected(struct bt_iso_chan *chan, uint8_t reason)
{
	size_t idx = (size_t)(chan - tx_chan);

	LOG_INF("relay BIS %u disconnected (0x%02x)", (unsigned int)idx + 1U, reason);
	if (idx < MAX_BIS) {
		atomic_set(&inflight[idx], 0);
	}
	k_sem_give(&tx_disc_sem);
	k_event_post(&ev, EV_TX_LOST);
}

static void tx_sent(struct bt_iso_chan *chan)
{
	size_t idx = (size_t)(chan - tx_chan);

	if (idx < MAX_BIS && atomic_get(&inflight[idx]) > 0) {
		atomic_dec(&inflight[idx]);
	}
	atomic_inc(&st_tx_ok);
}

static struct bt_iso_chan_ops rx_ops = {
	.connected = rx_connected,
	.disconnected = rx_disconnected,
	.recv = rx_recv,
};

static struct bt_iso_chan_ops tx_ops = {
	.connected = tx_connected,
	.disconnected = tx_disconnected,
	.sent = tx_sent,
};

/* ------------------------------------------------------------------------- */
/* Source: sync / unsync                                                     */
/* ------------------------------------------------------------------------- */

static void source_teardown(void)
{
	atomic_set(&forwarding, 0);

	if (rx_big != NULL) {
		k_sem_reset(&rx_disc_sem);
		if (bt_iso_big_terminate(rx_big) == 0) {
			for (uint8_t i = 0U; i < rx_sig.num_bis; i++) {
				if (sem_take_fed(&rx_disc_sem, TERM_WAIT_MS)) {
					break;
				}
			}
		}
		rx_big = NULL;
	}

	struct bt_le_per_adv_sync *s = pa_sync;

	if (s != NULL) {
		pa_sync = NULL;
		(void)bt_le_per_adv_sync_delete(s);
	}
}

/* Returns 0 when BIG sync to all wanted BIS is established. */
static int source_sync(void)
{
	struct bt_le_per_adv_sync_param sp = { 0 };
	struct bt_le_per_adv_sync *s;
	uint32_t timeout_10ms;
	uint32_t got;
	int err;

	k_event_clear(&ev, EV_PA_SYNCED | EV_PA_TERM | EV_BIGINFO | EV_PA_DATA | EV_RX_LOST);

	/* Sync timeout: 6 PA intervals, at least 2 s */
	timeout_10ms = ((uint32_t)source.pa_interval * 1250U * 6U) / 10000U;
	timeout_10ms = CLAMP(timeout_10ms, 200U, 0x4000U);

	bt_addr_le_copy(&sp.addr, &source.addr);
	sp.sid = source.sid;
	sp.options = BT_LE_PER_ADV_SYNC_OPT_NONE;
	sp.skip = 0U;
	sp.timeout = (uint16_t)timeout_10ms;

	err = bt_le_per_adv_sync_create(&sp, &s);
	if (err) {
		LOG_WRN("PA sync create failed (%d)", err);
		return err;
	}
	pa_sync = s;

	got = event_wait_fed(EV_PA_SYNCED | EV_PA_TERM,
			     PA_SYNC_WAIT_MS + (uint32_t)source.pa_interval * 5U);
	if (!(got & EV_PA_SYNCED)) {
		LOG_WRN("PA sync to \"%s\" failed", source.name);
		source_teardown();
		return -ETIMEDOUT;
	}

	/* Both BIGInfo (ACAD) and the BASE (PA data) are needed. */
	int64_t end = k_uptime_get() + BIGINFO_WAIT_MS + (int64_t)source.pa_interval * 3;

	while (k_uptime_get() < end) {
		uint32_t have = k_event_test(&ev, EV_BIGINFO | EV_PA_DATA | EV_PA_TERM);

		if (have & EV_PA_TERM) {
			break;
		}
		if ((have & (EV_BIGINFO | EV_PA_DATA)) == (EV_BIGINFO | EV_PA_DATA)) {
			break;
		}
		(void)event_wait_fed(EV_BIGINFO | EV_PA_DATA | EV_PA_TERM, 200U);
	}

	if ((k_event_test(&ev, EV_BIGINFO | EV_PA_DATA) & (EV_BIGINFO | EV_PA_DATA)) !=
	    (EV_BIGINFO | EV_PA_DATA)) {
		LOG_WRN("no BIGInfo/BASE from \"%s\"", source.name);
		source_teardown();
		return -ENODATA;
	}

	struct bt_iso_biginfo bi;
	k_spinlock_key_t key = k_spin_lock(&pa_lock);

	bi = biginfo;
	k_spin_unlock(&pa_lock, key);

	LOG_INF("BIGInfo: %u BIS, ISO int %u x 1.25 ms, NSE %u, BN %u, PTO %u, IRC %u, "
		"max PDU %u, SDU int %u us, max SDU %u, PHY %u, %s, %s",
		bi.num_bis, bi.iso_interval, bi.sub_evt_count, bi.burst_number, bi.offset,
		bi.rep_count, bi.max_pdu, bi.sdu_interval, bi.max_sdu, bi.phy,
		bi.framing ? "framed" : "unframed", bi.encryption ? "encrypted" : "open");

	if (bi.encryption && sizeof(CONFIG_AURACAST_REPEATER_BROADCAST_CODE) <= 1U) {
		LOG_WRN("\"%s\" is encrypted and no Broadcast Code is configured - skipping",
			source.name);
		block_source(&source.addr);
		source_teardown();
		return -EACCES;
	}

	rx_sig.num_bis = MIN(bi.num_bis, (uint8_t)MAX_BIS);
	rx_sig.sdu_interval = bi.sdu_interval;
	rx_sig.max_sdu = bi.max_sdu;
	rx_sig.framing = bi.framing;
	rx_sig.encryption = bi.encryption;

	uint32_t burst = 1U;

	if (bi.sdu_interval > 0U) {
		burst = ((uint32_t)bi.iso_interval * 1250U + bi.sdu_interval / 2U) /
			bi.sdu_interval;
	}
	burst = CLAMP(burst, 1U, (uint32_t)MAX_BURST);
	atomic_set(&inflight_limit, (atomic_val_t)(burst + MAX_INFLIGHT - 1U));
	if (burst > 1U) {
		LOG_WRN("source sends %u SDUs per BIG event (ISO interval %u us) - "
			"long source events leave little airtime for the relay",
			burst, bi.iso_interval * 1250U);
	}

	if (bi.num_bis > MAX_BIS) {
		LOG_WRN("source has %u BIS, relaying the first %u only", bi.num_bis, MAX_BIS);
	}
	if (bi.max_sdu > CONFIG_BT_ISO_TX_MTU) {
		LOG_ERR("max SDU %u > TX MTU", bi.max_sdu);
		source_teardown();
		return -EMSGSIZE;
	}

	struct bt_iso_big_sync_param bp = {
		.bis_channels = rx_chan_p,
		.num_bis = rx_sig.num_bis,
		.bis_bitfield = BIT_MASK(rx_sig.num_bis), /* BIS index 1..n */
		.mse = BT_ISO_SYNC_MSE_ANY,
		.sync_timeout = 200, /* 2 s */
		.encryption = bi.encryption,
	};

	memcpy(bp.bcode, bcode, sizeof(bp.bcode));

	k_sem_reset(&rx_conn_sem);
	err = bt_iso_big_sync(pa_sync, &bp, &rx_big);
	if (err) {
		LOG_WRN("BIG sync failed (%d)", err);
		rx_big = NULL;
		source_teardown();
		return err;
	}

	for (uint8_t i = 0U; i < rx_sig.num_bis; i++) {
		if (sem_take_fed(&rx_conn_sem, BIS_WAIT_MS)) {
			LOG_WRN("BIG sync timeout (wrong Broadcast Code?)");
			if (bi.encryption) {
				block_source(&source.addr);
			}
			source_teardown();
			return -ETIMEDOUT;
		}
	}

	atomic_set(&last_rx_ms, (atomic_val_t)k_uptime_get_32());
	LOG_INF("synchronised to \"%s\" (%u BIS)", source.name, rx_sig.num_bis);
	return 0;
}

/* ------------------------------------------------------------------------- */
/* Relay: start / update / stop                                              */
/* ------------------------------------------------------------------------- */

static int relay_set_data(void)
{
	struct bt_data ea[12];
	struct bt_data pa[8];
	size_t ea_n;
	size_t pa_n;
	int err;

	build_ea();
	build_pa();

	ea_n = ad_view(ea_raw, ea_raw_len, ea, ARRAY_SIZE(ea));
	pa_n = ad_view(pa_raw, pa_raw_len, pa, ARRAY_SIZE(pa));

	err = bt_le_ext_adv_set_data(relay_adv, ea, ea_n, NULL, 0);
	if (err) {
		LOG_ERR("EA data failed (%d)", err);
		return err;
	}

	err = bt_le_per_adv_set_data(relay_adv, pa, pa_n);
	if (err) {
		LOG_ERR("PA data failed (%d)", err);
	}
	return err;
}

static void relay_stop(void)
{
	if (!relay_active && relay_adv == NULL) {
		return;
	}

	atomic_set(&forwarding, 0);

	if (tx_big != NULL) {
		k_sem_reset(&tx_disc_sem);
		if (bt_iso_big_terminate(tx_big) == 0) {
			for (uint8_t i = 0U; i < tx_sig.num_bis; i++) {
				if (sem_take_fed(&tx_disc_sem, TERM_WAIT_MS)) {
					break;
				}
			}
		}
		tx_big = NULL;
	}

	if (relay_adv != NULL) {
		(void)bt_le_per_adv_stop(relay_adv);
		(void)bt_le_ext_adv_stop(relay_adv);
		(void)bt_le_ext_adv_delete(relay_adv);
		relay_adv = NULL;
	}

	for (size_t i = 0U; i < MAX_BIS; i++) {
		atomic_set(&inflight[i], 0);
	}

	relay_active = false;
	k_event_clear(&ev, EV_TX_LOST);
	LOG_INF("relay stopped");
}

static int relay_start(void)
{
	/* Non-connectable, non-scannable EA from the static identity address
	 * (stable across resyncs, receivers can remember it).
	 */
	const struct bt_le_adv_param adv_param = BT_LE_ADV_PARAM_INIT(
		BT_LE_ADV_OPT_EXT_ADV | BT_LE_ADV_OPT_USE_IDENTITY,
		BT_GAP_MS_TO_ADV_INTERVAL(100), BT_GAP_MS_TO_ADV_INTERVAL(150), NULL);
	const struct bt_le_per_adv_param per_param = BT_LE_PER_ADV_PARAM_INIT(
		BT_GAP_MS_TO_PER_ADV_INTERVAL(200), BT_GAP_MS_TO_PER_ADV_INTERVAL(300),
		BT_LE_PER_ADV_OPT_NONE);
	int err;

	tx_sig = rx_sig;

	err = bt_le_ext_adv_create(&adv_param, NULL, &relay_adv);
	if (err) {
		LOG_ERR("adv create failed (%d)", err);
		relay_adv = NULL;
		return err;
	}

	err = bt_le_per_adv_set_param(relay_adv, &per_param);
	if (err) {
		LOG_ERR("PA param failed (%d)", err);
		goto fail;
	}

	err = relay_set_data();
	if (err) {
		goto fail;
	}

	err = bt_le_per_adv_start(relay_adv);
	if (err) {
		LOG_ERR("PA start failed (%d)", err);
		goto fail;
	}

	err = bt_le_ext_adv_start(relay_adv, BT_LE_EXT_ADV_START_DEFAULT);
	if (err) {
		LOG_ERR("EA start failed (%d)", err);
		goto fail;
	}

	tx_io_qos.sdu = tx_sig.max_sdu;
	tx_io_qos.phy = BT_GAP_LE_PHY_2M;
	tx_io_qos.rtn = CONFIG_AURACAST_REPEATER_RTN;

	struct bt_iso_big_create_param bp = {
		.bis_channels = tx_chan_p,
		.num_bis = tx_sig.num_bis,
		.interval = tx_sig.sdu_interval,
		.latency = CONFIG_AURACAST_REPEATER_MAX_LATENCY_MS,
		.packing = BT_ISO_PACKING_SEQUENTIAL,
		.framing = tx_sig.framing,
		.encryption = tx_sig.encryption,
	};

	memcpy(bp.bcode, bcode, sizeof(bp.bcode));

	k_sem_reset(&tx_conn_sem);
	err = bt_iso_big_create(relay_adv, &bp, &tx_big);
	if (err) {
		LOG_ERR("BIG create failed (%d)", err);
		tx_big = NULL;
		goto fail;
	}

	for (uint8_t i = 0U; i < tx_sig.num_bis; i++) {
		if (sem_take_fed(&tx_conn_sem, BIS_WAIT_MS)) {
			LOG_ERR("BIG create timeout");
			err = -ETIMEDOUT;
			goto fail;
		}
	}

	relay_active = true;
	k_event_clear(&ev, EV_TX_LOST);
	LOG_INF("relay on air: %u BIS, SDU %u us, max SDU %u, RTN %u, +8 dBm", tx_sig.num_bis,
		tx_sig.sdu_interval, tx_sig.max_sdu, CONFIG_AURACAST_REPEATER_RTN);
	return 0;

fail:
	relay_active = true; /* let relay_stop clean up whatever was created */
	relay_stop();
	return err;
}

static bool sig_equal(const struct stream_sig *a, const struct stream_sig *b)
{
	return a->num_bis == b->num_bis && a->sdu_interval == b->sdu_interval &&
	       a->max_sdu == b->max_sdu && a->framing == b->framing &&
	       a->encryption == b->encryption;
}

/* ------------------------------------------------------------------------- */
/* Statistics                                                                */
/* ------------------------------------------------------------------------- */

static void stats_log(void)
{
	LOG_INF("rx ok %ld lost %ld | tx ok %ld drop %ld err %ld | queue %ld/%ld",
		(long)atomic_get(&st_rx_ok), (long)atomic_get(&st_rx_bad),
		(long)atomic_get(&st_tx_ok), (long)atomic_get(&st_tx_drop),
		(long)atomic_get(&st_tx_err), (long)atomic_get(&inflight[0]),
		(long)(MAX_BIS > 1 ? atomic_get(&inflight[MAX_BIS - 1]) : 0));
}

/* ------------------------------------------------------------------------- */
/* Main loop                                                                 */
/* ------------------------------------------------------------------------- */

static void init_ids(void)
{
	const char *code = CONFIG_AURACAST_REPEATER_BROADCAST_CODE;

	memset(bcode, 0, sizeof(bcode));
	memcpy(bcode, code, MIN(strlen(code), sizeof(bcode)));

	relay_broadcast_id = CONFIG_AURACAST_REPEATER_BROADCAST_ID;
	if (relay_broadcast_id == 0U) {
		uint8_t id[16] = { 0 };
		ssize_t n = hwinfo_get_device_id(id, sizeof(id));
		uint32_t h = 2166136261U; /* FNV-1a */

		for (ssize_t i = 0; i < n; i++) {
			h = (h ^ id[i]) * 16777619U;
		}
		relay_broadcast_id = (h ^ (h >> 24)) & 0xFFFFFFU;
		if (relay_broadcast_id == 0U) {
			relay_broadcast_id = 0x5A5A5AU;
		}
	}

	for (size_t i = 0U; i < MAX_BIS; i++) {
		rx_chan[i].ops = &rx_ops;
		rx_chan[i].qos = &rx_qos;
		rx_chan_p[i] = &rx_chan[i];
		tx_chan[i].ops = &tx_ops;
		tx_chan[i].qos = &tx_qos;
		tx_chan_p[i] = &tx_chan[i];
	}
}

int main(void)
{
	int64_t next_stats = 0;
	int err;

	LOG_INF("Auracaster Repeater starting (source prefix \"%s\")",
		CONFIG_AURACAST_REPEATER_SOURCE_NAME_PREFIX);

	led_set(LED_SEARCHING);
	init_ids();

	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("Bluetooth init failed (%d)", err);
		led_set(LED_ERROR);
		k_sleep(K_SECONDS(5));
		sys_reboot(SYS_REBOOT_COLD);
	}

	watchdog_init();
	bt_le_scan_cb_register(&scan_cb);
	bt_le_per_adv_sync_cb_register(&pa_cb);

	while (true) {
		/* ---- search ---- */
		led_set(LED_SEARCHING);
		candidates_clear();
		err = scan_start();
		if (err) {
			LOG_ERR("scan start failed (%d)", err);
			sleep_fed(1000U);
			continue;
		}

		sleep_fed(CONFIG_AURACAST_REPEATER_SCAN_WINDOW_MS);

		if (relay_active && k_uptime_get() > grace_deadline) {
			LOG_INF("source gone for too long");
			relay_stop();
		}

		if (!candidates_pick(&source)) {
			continue; /* keep scanning */
		}

		LOG_INF("source \"%s\" (Broadcast ID 0x%06x, RSSI %d)", source.name,
			source.broadcast_id, source.rssi);

		/* ---- sync to the source (scanner must run until PA synced) ---- */
		err = source_sync();
		scan_stop();
		if (err) {
			continue;
		}
		led_set(LED_SYNCED);

		/* ---- relay up (or reuse) ---- */
		if (relay_active && !sig_equal(&rx_sig, &tx_sig)) {
			LOG_INF("stream parameters changed, restarting relay");
			relay_stop();
		}

		if (relay_active) {
			err = relay_set_data(); /* new name/BASE, same BIG */
		} else {
			err = relay_start();
		}
		if (err) {
			source_teardown();
			sleep_fed(1000U);
			continue;
		}

		k_event_clear(&ev, EV_PA_DATA);
		atomic_set(&forwarding, 1);
		led_set(LED_RELAYING);

		/* ---- relaying ---- */
		while (true) {
			uint32_t got = event_wait_fed(EV_RX_LOST | EV_TX_LOST | EV_PA_DATA, 500U);

			if (got & EV_PA_DATA) {
				k_event_clear(&ev, EV_PA_DATA);
				LOG_INF("source BASE changed, updating relay PA");
				build_pa();
				struct bt_data pa[8];
				size_t pa_n = ad_view(pa_raw, pa_raw_len, pa, ARRAY_SIZE(pa));

				(void)bt_le_per_adv_set_data(relay_adv, pa, pa_n);
			}
			if (got & (EV_RX_LOST | EV_TX_LOST)) {
				break;
			}
			if ((uint32_t)(k_uptime_get_32() - (uint32_t)atomic_get(&last_rx_ms)) >
			    CONFIG_AURACAST_REPEATER_LOSS_TIMEOUT_MS) {
				LOG_WRN("no audio for %u ms - resync",
					CONFIG_AURACAST_REPEATER_LOSS_TIMEOUT_MS);
				break;
			}
			if (CONFIG_AURACAST_REPEATER_STATS_INTERVAL_S > 0 &&
			    k_uptime_get() >= next_stats) {
				next_stats = k_uptime_get() +
					     CONFIG_AURACAST_REPEATER_STATS_INTERVAL_S * 1000;
				stats_log();
			}
		}

		/* ---- lost: resync, keep the relay for the grace period ---- */
		atomic_set(&forwarding, 0);
		stats_log();
		source_teardown();
		if (k_event_test(&ev, EV_TX_LOST)) {
			relay_stop();
		}
		grace_deadline = k_uptime_get() + CONFIG_AURACAST_REPEATER_GRACE_MS;
		k_event_clear(&ev, EV_RX_LOST);
	}

	return 0;
}

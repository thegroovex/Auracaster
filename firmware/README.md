# Auracaster Dongle – Controller-Firmware

Zephyr-Firmware, die einen nice!nano-kompatiblen **„Pro Micro nRF52840“** (z. B. Ulegqin,
Amazon B0HFJQLBFK; nRF52840, USB‑C, integrierte Antenne) in einen
**Bluetooth-LE-Audio-Broadcast-Controller** für Bumble verwandelt. Der Mac (Bumble,
`engine/auracaster_helper.py`) ist der Host, der Dongle macht nur den Link Layer:
Extended + Periodic Advertising und einen BIG mit bis zu 2 BIS (Stereo L/R, LC3 48 kHz/10 ms).

| | |
|---|---|
| Basis | Zephyr **v4.4.2**, Sample `samples/bluetooth/hci_uart` (Quelle in `src/main.c`) |
| Board | Zephyr-Board `promicro_nrf52840` (Upstream-Name für Pro Micro / SuperMini / nice!nano‑Klone; ein Board `nice_nano` gibt es in Zephyr nicht) |
| Transport | **HCI H4 über USB CDC ACM** (virtuelle serielle Schnittstelle) |
| USB | `2fe3:0004`, Hersteller „Auracaster“, Produkt **„Auracaster Dongle“** |
| Link Layer | Zephyr Open-Source-Controller (`BT_LL_SW_SPLIT`), ADV_EXT, ADV_PERIODIC, ADV_ISO (1 BIG / 2 BIS, auch verschlüsselt mit Broadcast Code) |
| ISO-TX | 16 Puffer à 251 Byte, SDU bis 251 Byte (LC3 48_2 = 100, 48_4 = 120, 48_6 = 155 Byte) |
| Sendeleistung | **+8 dBm** (`CONFIG_BT_CTLR_TX_PWR_PLUS_8`) |
| LED (P0.15) | kurzes Blinken 1×/s = an, wartet auf Host · Dauerlicht = Host hat den Port geöffnet (DTR) |

## Warum H4/CDC und nicht `hci_usb`?

Bumble-Kompatibilität für **ISO-Daten** entscheidet:

* Zephyrs USB-Bluetooth-Klasse (`hci_usb`, `subsys/usb/device_next/class/bt_hci.c`)
  kennt nur Kommandos (Control-EP), Events (Interrupt-EP) und ACL (Bulk). Alles, was auf
  dem Bulk-OUT-Endpunkt ankommt, wird als **ACL** interpretiert, ISO-Pakete vom Controller
  verwirft sie mit „Unsupported type“ (Quelle: Zephyr v4.4.2). Bumble schickt ISO bei
  fehlenden Isochronous-Endpunkten zwar über Bulk-OUT, der Controller würde sie aber als
  ACL fehlinterpretieren → kein Auracast möglich.
* `hci_uart` spricht **H4** inkl. Pakettyp `0x05` (ISO) in beide Richtungen. Über USB CDC
  ACM ist das eine normale serielle Schnittstelle, die Bumble als `serial:` öffnet –
  auf macOS ohne Treiber, ohne libusb, ohne Claim-Konflikte. Die Baudrate ist bei CDC egal.

## Welche UF2-Datei? (Bootloader-Offset)

Der Klon bringt laut Hersteller den nice!nano-/Adafruit-nRF52-UF2-Bootloader mit
(Doppel-Reset → Laufwerk). Wohin die Anwendung gehört, hängt davon ab, ob der Bootloader
mit **SoftDevice S140** ausgeliefert wurde. Das steht in **`INFO_UF2.TXT`** auf dem
Bootloader-Laufwerk, Zeile `SoftDevice:` (nicht die Versionszeile!):

| `INFO_UF2.TXT` → `SoftDevice:` | Datei | App-Start |
|---|---|---|
| `S140 version 6.1.1` (Original nice!nano v2, die meisten Klone) | `auracaster-dongle-s140v6-0x26000.uf2` | `0x26000` |
| `S140 version 7.x.x` | `auracaster-dongle-s140v7-0x27000.uf2` | `0x27000` |
| `not found` (MBR-only-/„nosd“-Bootloader) | `auracaster-dongle-nosd-0x1000.uf2` | `0x1000` |

Typischer Inhalt beim nice!nano-Bootloader:

```
UF2 Bootloader 0.6.0 lib/nrfx (v2.0.0) lib/tinyusb (0.10.1-41-gdf0cda2d) lib/uf2 (remotes/origin/configupdate-9-gadbb8c7)
Model: nice!nano
Board-ID: nRF52840-nicenano
SoftDevice: S140 version 6.1.1
Date: Jun 19 2021
```

Hinweise:

* Die Firmware braucht die SoftDevice nicht (Zephyr hat einen eigenen Link Layer). Mit
  SoftDevice springt der MBR über die SoftDevice in die App bei `0x26000`; ohne SoftDevice
  direkt nach `0x1000`.
* Die `nosd`-Datei auf einem Board **mit** SoftDevice überschreibt die SoftDevice (der
  Adafruit-Bootloader behandelt sie als Teil der App). Das funktioniert, ist aber
  unnötig – nimm dort die `s140v6`-Datei. Der UF2-Bootloader selbst (ab `0xF4000`) und
  der MBR werden von keiner der Dateien angetastet, das Board bleibt also immer per
  Doppel-Reset erreichbar.
* Alle Dateien haben die UF2-Family-ID `0xADA52840` (nRF52840), die der Bootloader erwartet.

## Flashen ohne Programmer

1. Artefakt **`auracaster-dongle-uf2`** aus dem letzten grünen Lauf von
   *Actions → Auracaster dongle firmware* laden und entpacken.
2. Dongle per USB‑C an den Mac.
3. **Doppel-Reset:** `RST` zweimal innerhalb von ~0,5 s kurz auf `GND` tippen (Pinzette/
   Draht). Es erscheint ein Laufwerk (meist **`NICENANO`**, je nach
   Klon auch anders benannt).
4. `INFO_UF2.TXT` öffnen → passende Datei aus der Tabelle oben wählen.
5. Die `.uf2` auf das Laufwerk kopieren (Finder oder
   `cp auracaster-dongle-s140v6-0x26000.uf2 /Volumes/NICENANO/`).
   Das Laufwerk wirft sich danach selbst aus, macOS meldet evtl. „nicht ordnungsgemäß
   ausgeworfen“ bzw. einen Kopierfehler am Ende – das ist normal.
6. Der Dongle startet neu, die LED blinkt kurz 1×/s. Im Terminal:

   ```sh
   ls /dev/cu.usbmodem*
   system_profiler SPUSBDataType | grep -A6 "Auracaster Dongle"
   ```

Zurück zum Bootloader geht jederzeit wieder per Doppel-Reset (z. B. für Updates).

## Test auf dem Mac

Umgebung einmalig im Repo-Root einrichten:

```sh
python3 -m venv .venv
.venv/bin/pip install -r engine/requirements.txt
```

Controller-Info (H4 über die serielle Schnittstelle; `,resync` setzt den H4-Parser
des Dongles zurück, falls eine frühere Sitzung mitten im Paket abgebrochen ist):

```sh
PORT=$(ls /dev/cu.usbmodem* | head -1)
.venv/bin/bumble-controller-info "serial:$PORT,resync"
```

Erwartet: Zephyr-Controller (Company ID 0x05F1 „The Linux Foundation“/Zephyr), LE
Features u. a. *LE Extended Advertising*, *LE Periodic Advertising*, *Isochronous
Broadcaster*; ISO-Puffer 251 Byte × 16.

> `bumble-controller-info usb:2fe3:000b` gilt nur für das Zephyr-Sample `hci_usb`
> (USB-HCI). Diese Firmware ist bewusst **kein** USB-HCI-Gerät (siehe oben), `usb:`
> findet sie nicht.

Auracast-Test mit dem Engine-Helper (Stille als Quelle, kein Audio nötig):

```sh
.venv/bin/python engine/auracaster_helper.py --transport auto
{"cmd":"start","id":1,"audio":{"input":"silence"}}
```

`--transport auto` (Standard) sucht den Dongle anhand des Produktnamens bzw. `2fe3:0004`
und öffnet ihn als `serial:/dev/cu.usbmodem…,resync`; explizit geht auch
`--transport serial:/dev/cu.usbmodemXXXX,resync`. Mit einer WAV-Datei:
`{"cmd":"start","id":1,"audio":{"input":"file:/pfad/test.wav"}}`. Danach sollte der
Broadcast „Auracaster“ auf einem Auracast-fähigen Handy/Hörgerät bzw. per
`{"cmd":"scan","id":2,"duration":5}` von einem zweiten Dongle sichtbar sein; die LED
leuchtet dauerhaft, solange der Helper verbunden ist.

## Selbst bauen

Die CI (`.github/workflows/firmware.yml`) macht genau das; lokal (Linux/macOS):

```sh
pip install west
mkdir -p ~/zws && cp -r firmware ~/zws/auracaster-fw && cd ~/zws
west init -l auracaster-fw && west update --narrow -o=--depth=1
pip install -r zephyr/scripts/requirements-base.txt
# Zephyr SDK $(cat zephyr/SDK_VERSION) mit Toolchain arm-zephyr-eabi installieren, dann:
west build -p -b promicro_nrf52840/nrf52840/uf2 -d build/s140v6 auracaster-fw          # 0x26000
west build -p -b promicro_nrf52840/nrf52840/uf2 -d build/s140v7 auracaster-fw -- -DEXTRA_DTC_OVERLAY_FILE=sdv7.overlay  # 0x27000
west build -p -b promicro_nrf52840/nrf52840     -d build/nosd   auracaster-fw          # 0x1000
python3 auracaster-fw/scripts/uf2info.py build/s140v6/zephyr/zephyr.uf2
```

Das Manifest `west.yml` lädt nur Zephyr plus `hal_nordic`, `cmsis_6`, `mbedtls` und
`tf-psa-crypto` (Letztere für die BIG-Verschlüsselung / Broadcast Code).

## Dateien

| Datei | Zweck |
|---|---|
| `west.yml` | Manifest, pinnt Zephyr v4.4.2 |
| `prj.conf` | Controller-/ISO-/USB-Konfiguration |
| `boards/promicro_nrf52840_nrf52840.conf` | nosd-Variante: UF2-Ausgabe bei Link-Adresse `0x1000` |
| `sdv7.overlay` | Flash-Layout für S140 v7 (`0x27000`) |
| `src/main.c` | H4-UART-Brücke aus Zephyrs `hci_uart` (unverändert, Apache‑2.0) |
| `src/status_led.c` | Status-LED auf P0.15 |
| `scripts/uf2info.py` | prüft Startadresse/Family-ID einer UF2 |

## Bekannte Grenzen / Risiken

* **Bootloader des Klons ungeprüft:** erst `INFO_UF2.TXT` lesen. Erscheint beim
  Doppel-Reset kein Laufwerk, hat der Klon keinen UF2-Bootloader – dann geht es nur mit
  SWD-Programmer (oder einem zweiten Board als Programmer).
* Zephyrs Broadcast-ISO im Open-Source-Link-Layer ist als *experimental* markiert; mit
  Bumble getestet wird er erst mit echter Hardware.
* Die VCC-Abschaltung über P0.13 wird nicht angesteuert (für den Dongle irrelevant, da
  nichts an VCC hängt).
* VID/PID `2fe3:0004` ist die generische Zephyr-CDC-ACM-Kennung; der Helper erkennt den
  Dongle primär am Produktnamen „Auracaster Dongle“.

## Änderungen in 0.1.1

- `CONFIG_BT_CTLR_ADV_DATA_BUF_MAX=4`: genug Advertising-Datenpuffer, wenn ein neuer Broadcast startet, bevor der alte vollständig abgebaut ist (v0.1.0: `MEMORY_CAPACITY_EXCEEDED` beim Preset-Wechsel, danach hing der Controller).
- `CONFIG_BT_CTLR_ISOAL_SN_STRICT=n`: ein verspätetes ISO-Paket geht ins nächste BIS-Intervall, statt alle folgenden Pakete „in die Vergangenheit“ zu nummerieren (Dauer-Aussetzer nach einem einzigen USB-/Host-Hänger).
- Controller-Assert/Fatal-Error → **Warmstart** statt Endlosschleife (über USB-CDC kann bei gesperrten Interrupts kein HCI-Fehlerevent raus; der Dongle wirkte „bis zum Abstecken eingefroren“).
- **Neustart beim Schließen des seriellen Ports** (DTR 1 → 0, 200 ms entprellt): jeder Helper-Start bekommt einen frischen Controller; der Helper nutzt das zur Selbstheilung (Port schließen → Dongle startet neu → erneut öffnen + `HCI_Reset`).
- ISO-TX: 16 Puffer à 251 Byte (genug für 2 BIS × 120-Byte-SDUs mit 3–4 Paketen Vorlauf); H4 über USB-CDC braucht dafür nur ≈ 26 KB/s.

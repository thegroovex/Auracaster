# Auracaster Repeater

Eine Firmware für einen **zweiten** Pro Micro nRF52840 (nice!nano-v2-Klon), die den
Auracast-Broadcast des Auracaster-Senders auffängt und ihn als eigenen Broadcast
noch einmal aussendet – mit +8 dBm, ohne Mac, nur an USB-Strom (Netzteil oder Powerbank).

> **Status: experimentell.** Die Firmware baut in der CI, wurde aber noch nicht auf echter
> Hardware getestet. Bitte die Abschnitte [Grenzen](#grenzen) und
> [Gleichzeitig empfangen und senden](#gleichzeitig-empfangen-und-senden) lesen, bevor du
> dich auf den Repeater verlässt.

---

## Wozu?

Der Auracaster-Dongle am Mac reicht je nach Wänden etwa 10–20 m. Steht ein Zuhörer
weiter weg (anderes Zimmer, Garten, große Halle), bricht der Ton ab. Der Repeater
steht dazwischen, empfängt den Broadcast noch sauber und sendet ihn mit voller Leistung
weiter.

```
 Mac + Dongle  ))))  Repeater  ))))  Kopfhörer / Hörgerät weit weg
 "Auracaster"        "Auracaster +"
```

Die LC3-Audiodaten werden **unverändert** weitergereicht (kein Dekodieren, kein
erneutes Kodieren): keine Qualitätseinbuße, sehr wenig Rechenzeit, sehr wenig
Zusatzverzögerung.

### Die einfachste Alternative zuerst

Oft reicht es, **den Sender-Dongle an einer aktiven USB-Verlängerung (5–10 m) zentral
und erhöht** zu platzieren – z. B. oben auf einem Regal mitten im Raum. Das kostet
keinen zweiten Broadcast, keine Zusatzlatenz und funktioniert sicher. Den Repeater
brauchst du erst, wenn das nicht genügt.

---

## Aufstellen

- **In der Mitte** zwischen Sender und dem Rand der Reichweite – dort, wo der Ton am
  Empfänger gerade noch stabil ist, eher etwas näher am Sender.
- **Sichtlinie** zum Sender, wenn möglich (Türen offen, keine Betonwand, kein Metall-
  schrank, kein Aquarium dazwischen – Wasser und Metall schlucken 2,4 GHz).
- **Erhöht** aufstellen (Regal, Türrahmen, 1,5–2 m), nicht auf dem Boden und nicht
  hinter dem Fernseher.
- Strom: jedes USB-Netzteil oder eine Powerbank. Manche Powerbanks schalten bei sehr
  kleinem Strom ab – dann eine mit „Low-Current-Modus" nehmen.

---

## Flashen

Du brauchst kein Programmiergerät; das Board hat einen UF2-Bootloader.

1. **Firmware laden:** In GitHub unter *Actions → Auracaster dongle firmware* den
   neuesten grünen Lauf öffnen und unten das Artefakt **auracaster-dongle-uf2**
   herunterladen und entpacken. Darin liegen die Dongle- **und** die Repeater-Dateien.
2. **Bootloader starten:** Board per USB anstecken und **zweimal schnell** Reset (RST)
   gegen GND tippen (bzw. den Reset-Knopf zweimal drücken). Es erscheint ein
   USB-Laufwerk, z. B. `NICENANO`.
3. **Richtige Datei wählen:** Auf dem Laufwerk `INFO_UF2.TXT` öffnen:

   | Zeile in INFO_UF2.TXT              | Datei                                     |
   |------------------------------------|-------------------------------------------|
   | `SoftDevice: S140 version 6.x.x`   | `auracaster-repeater-s140v6-0x26000.uf2`  |
   | `SoftDevice: S140 version 7.x.x`   | `auracaster-repeater-s140v7-0x27000.uf2`  |
   | `SoftDevice: not found`            | `auracaster-repeater-nosd-0x1000.uf2`     |

4. Die Datei auf das Laufwerk **ziehen**. Das Laufwerk verschwindet von selbst, der
   Repeater startet. (Eine Fehlermeldung von macOS/Windows beim Auswerfen ist normal.)

Zurück zur Dongle-Firmware geht es genauso, nur mit `auracaster-dongle-….uf2`.

---

## LED (P0.15)

| LED                               | Bedeutung                                                    |
|-----------------------------------|--------------------------------------------------------------|
| blinkt langsam (½ s an, ½ s aus)  | sucht den Auracaster-Sender                                  |
| blinkt doppelt                    | Sender gefunden und synchronisiert, Repeater startet gleich  |
| leuchtet dauerhaft                | Repeater sendet („Auracaster +" ist auf Sendung)             |
| blinkt schnell                    | Fehler: Bluetooth startet nicht (Board wird neu gestartet)   |

Geht der Sender verloren (Mac zu, außer Reichweite), blinkt die LED wieder langsam.
Der eigene Broadcast läuft dann noch bis zu 15 s weiter; kommt derselbe Sender zurück,
hören die Empfänger nach einer kurzen Lücke einfach weiter. Danach schaltet der Repeater
ab und sucht weiter. Ein Hardware-Watchdog startet das Board neu, falls es hängt.

---

## Empfänger einstellen

Der Repeater sendet einen **zweiten** Broadcast mit dem Namen des Originals plus
„ +", also z. B. **„Auracaster +"** (eigene Broadcast-ID, gleiche Audio-Einstellungen,
gleicher Broadcast Code).

- **Smartphone / Hörgeräte-App / Auracast-Assistent:** In der Liste der Broadcasts
  **„Auracaster +"** wählen, wenn du weit weg bist; nah am Mac weiterhin „Auracaster".
- **Kopfhörer mit Auracast-Taste:** Sie verbinden sich meist mit dem stärksten Signal –
  nah am Repeater ist das „Auracaster +".
- Ist der Sender verschlüsselt, gilt **derselbe Code** auch für den Repeater (siehe
  Konfiguration).

---

## Verzögerung (Zusatzlatenz)

Gegenüber dem Original hören Empfänger am Repeater den Ton etwas später:

| Anteil                                                         | typisch     |
|----------------------------------------------------------------|-------------|
| Weiterreichen im Chip (Controller → Host → Controller)         | < 1 ms      |
| Warten auf das nächste eigene Sendefenster (0 … 1 SDU-Intervall) | Ø 5 ms (0–10 ms) |
| eigene Übertragung im BIG (BIG-Sync-Delay, RTN 0, 2 BIS, 2M)   | ca. 1,5–2 ms |
| Puffer gegen Taktdrift (max. 1 SDU zusätzlich, selten)          | 0–10 ms     |
| **Summe**                                                      | **≈ 3–13 ms, typisch ≈ 7 ms**, Ausnahmefall bis ≈ 23 ms |

Bei 7,5-ms-Rahmen entsprechend weniger. Sendet das Original mehrere Pakete pro
Ereignis (aktuelle Sender-Voreinstellung: 5 Pakete alle 50 ms), reicht der Repeater sie
in fünf aufeinanderfolgenden 10-ms-Fenstern weiter; das gleicht genau die Verzögerung
aus, die das Original für diese Pakete ohnehin schon einplant, und ändert die Summe
oben nicht. Die Presentation Delay (Abspielverzögerung im
Empfänger) wird **1:1 vom Original übernommen** (Auracaster-Standard: 40 ms); sie kommt
beim Original wie beim Repeater gleichermaßen dazu und ist daher keine Zusatzlatenz.

Sitzen zwei Personen – eine am Original, eine am Repeater – im selben Raum, ist der
Versatz von rund 10 ms nicht als Echo hörbar. Lautsprecher am Original und am Repeater
gleichzeitig im selben Raum können dagegen leicht „hallig" klingen.

---

## Grenzen

- **Kein nahtloses Roaming.** Original und Repeater sind zwei getrennte Broadcasts.
  Ein Empfänger springt nicht automatisch um, wenn er durchs Haus läuft – er muss
  umgeschaltet werden (App/Taste). Für einen Ort, der nur über den Repeater erreicht
  wird, ist das kein Problem.
- **Ein Funkchip, zwei Aufgaben.** Der nRF52840 hat nur ein Funkteil: Er muss den
  Original-BIG empfangen *und* den eigenen BIG senden. Beide laufen auf unterschied-
  lichen Uhren und verschieben sich langsam gegeneinander. Wenn sich die Zeitfenster
  überlappen, muss der Chip eines auslassen – es fehlen dann einzelne Audio-Pakete
  (der Empfänger überbrückt kurze Lücken, längere hört man als Aussetzer). Wie oft das
  passiert, hängt vor allem davon ab, wie lang die Sende-Ereignisse des **Originals**
  sind:
  - Die aktuelle Voreinstellung des Auracaster-Senders (`max_transport_latency_ms = 65`,
    `rtn = 4`) erzeugt beim Zephyr-Controller **50-ms-ISO-Intervalle mit ≈ 30 ms langen
    Ereignissen**. Das lässt dem Repeater zu wenig Luft – **mit diesen Einstellungen
    sind regelmäßige Aussetzer zu erwarten.**
  - Für den Repeater-Betrieb den Sender auf **`max_transport_latency_ms` ≤ 20 und
    `rtn` 1–2** stellen (kurze 10-ms-Ereignisse). Das ist aktuell nur im Engine-Preset
    möglich (`preset` im JSON an `auracaster_helper.py`), nicht in der App-Oberfläche.
  - Selbst dann teilen sich beide BIGs ein 10-ms-Raster; erwartet werden Phasen mit
    sauberem Ton und Phasen mit Paketverlusten, die im Takt der Uhrdrift (Minuten)
    wechseln. **Das muss auf echter Hardware gemessen werden** (Statistik auf der
    USB-Konsole, s. u.).
- **Zuverlässige Alternative mit zwei Boards** (du hast drei): Ein Board empfängt, das
  andere sendet; beide über UART verbunden. Jedes Funkteil hat dann nur eine Aufgabe.
  Das ist nicht Teil dieser Firmware, wäre aber der nächste Schritt, falls die
  Messungen mit einem Board nicht reichen.
- Maximal **2 Audiokanäle** (BIS) – genau das, was der Auracaster sendet (Stereo).
- Repeater werden **nicht hintereinander** geschaltet: Broadcasts, deren Name auf
  „ +" endet, werden ignoriert (sonst würde ein Repeater den anderen wiederholen).
- 32-kHz-Quarz: Die Firmware nutzt wie die Dongle-Firmware den Board-Standard
  (externer 32,768-kHz-Quarz). Klone ohne Quarz würden beim Start hängen bleiben.

---

## Gleichzeitig empfangen und senden

Kann der Zephyr-Controller (Link Layer `BT_LL_SW_SPLIT`, Zephyr v4.4.2) überhaupt
gleichzeitig einen BIG empfangen und einen senden?

- **Kconfig: ja.** `BT_CTLR_ADV_ISO` (senden) und `BT_CTLR_SYNC_ISO` (empfangen) haben
  keine gegenseitige Abhängigkeit oder Ausschluss
  (`subsys/bluetooth/controller/Kconfig`); der nRF5-Link-Layer wählt beide
  `…_SUPPORT`-Symbole (`Kconfig.ll_sw_split`). Zephyrs eigener BIS-Test
  (`tests/bsim/bluetooth/ll/bis/prj.conf`) baut beide in **ein** Image.
- **Laufzeit:** Beide Rollen sind gewöhnliche Ticker-Knoten im selben Scheduler. Es
  gibt keine Kopplung der Zeitfenster: Überlappen sie, wird eines ausgelassen
  (`ticker_worker` / `ticker_resolve_collision` in `ticker/ticker.c`). Der
  Empfangs-BIG reserviert dabei immer alle Subevents (`ull_sync_iso.c`: Slot =
  `sub_interval × NSE × BIS`; der Parameter *MSE* wird vom Zephyr-Controller nicht
  ausgewertet). Der Fall „ein Gerät empfängt und sendet gleichzeitig" ist in Zephyrs
  Tests nicht abgedeckt.

---

## Konfiguration (für Bastler)

Die Optionen stehen in `Kconfig` und lassen sich beim Bauen setzen, z. B.:

```sh
west build -b promicro_nrf52840/nrf52840/uf2 firmware/repeater -- \
  -DCONFIG_AURACAST_REPEATER_BROADCAST_CODE=\"geheim123\" \
  -DCONFIG_AURACAST_REPEATER_NAME=\"Garten\"
```

| Option                                        | Standard       | Bedeutung |
|-----------------------------------------------|----------------|-----------|
| `AURACAST_REPEATER_SOURCE_NAME_PREFIX`        | `Auracaster`   | Nur Broadcasts, deren Name so beginnt (leer = alle) |
| `AURACAST_REPEATER_FALLBACK_STRONGEST`        | `y`            | Passt keiner, den stärksten Auracast-Broadcast nehmen |
| `AURACAST_REPEATER_NAME`                      | leer           | Fester Name; leer = Originalname + Suffix |
| `AURACAST_REPEATER_NAME_SUFFIX`               | ` +`           | Suffix für den Namen |
| `AURACAST_REPEATER_BROADCAST_CODE`            | leer           | Code für verschlüsselte Sender (wird auch für den Repeater verwendet) |
| `AURACAST_REPEATER_BROADCAST_ID`              | `0`            | 0 = aus der Chip-ID abgeleitet (bleibt nach Neustart gleich) |
| `AURACAST_REPEATER_RTN`                       | `0`            | Wiederholungen im eigenen BIG (mehr = robuster, aber mehr Funkzeit) |
| `AURACAST_REPEATER_MAX_LATENCY_MS`            | `10`           | < 30 ms ⇒ ein SDU pro Ereignis, sofortiges Weiterreichen |
| `AURACAST_REPEATER_PRESENTATION_DELAY_US`     | `0`            | 0 = vom Original übernehmen |
| `AURACAST_REPEATER_GRACE_MS`                  | `15000`        | So lange läuft der eigene Broadcast bei Verlust weiter |
| `AURACAST_REPEATER_HW_WATCHDOG`               | `y`            | Hardware-Watchdog (8 s) |

### USB-Konsole

Am Rechner meldet sich der Repeater als serielle Schnittstelle **„Auracaster
Repeater"** (USB-ID 2fe3:0005 – bewusst anders als der Dongle, damit die Mac-App ihn
nicht verwechselt). Mit einem Terminal (z. B. `screen /dev/cu.usbmodem… 115200`)
siehst du, welcher Sender gewählt wurde, die BIGInfo des Originals und alle 10 s
eine Statistik:

```
rx ok 2000 lost 3 | tx ok 1998 drop 2 err 0 | queue 1/1
```

`lost` = beim Empfang fehlende Pakete, `drop` = verworfene Pakete (Puffer voll). Steigen
diese Zahlen in Phasen stark an, ist das die Zeitfenster-Kollision aus [Grenzen](#grenzen).

---

## Technik in Kürze

- Zephyr v4.4.2 (gleiche `firmware/west.yml` wie der Dongle), Host **und** Controller
  auf dem Chip.
- Direkt `bt_le_per_adv_sync` + `bt_iso_big_sync` / `bt_iso_big_create` statt der
  BAP-Broadcast-Sink/Source-APIs: Die BAP-Sink verlangt PACS, Scan Delegator und einen
  verbindbaren GATT-Server; die BAP-Source würde die BASE aus geparsten Strukturen neu
  bauen. So wird die BASE (Codec, Metadaten, Kanalzuordnung) **Byte für Byte**
  kopiert, und pro Audiopaket fällt genau ein `memcpy` an.
- Ablauf: passiver Scan → Kandidat mit Broadcast Audio Announcement (0x1852) →
  PA-Sync → BIGInfo + BASE → BIG-Sync (alle BIS, ggf. mit Code) → eigenes EA/PA/BIG
  (gleiches SDU-Intervall, max. SDU, Framing, BIS-Zahl, Verschlüsselung; 2M PHY) →
  jedes gültige SDU sofort an den passenden eigenen BIS (gleiche Sequenznummer).
- Pro BIS dürfen höchstens 2 SDUs im Controller warten; mehr wird verworfen, damit
  die Verzögerung durch Taktdrift nicht wächst.

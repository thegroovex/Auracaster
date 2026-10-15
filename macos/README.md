# Auracaster für macOS

Auracaster sendet Audio vom Mac – das gesamte Systemaudio, einzelne Apps (z. B. Ableton Live, Musik) oder ein Mikrofon/Audio-Interface – als **Auracast™-Broadcast** (Bluetooth LE Audio, Broadcast Isochronous Stream). Jedes Auracast-fähige Gerät in Reichweite kann zuhören: Hörgeräte, Earbuds, Lautsprecher, Smartphones.

Ziele: niedrige Latenz (Preset *Ultra-Low* ≈ 18 ms), eine native Mac-Oberfläche für macOS 27 „Golden Gate“ und eine Menüleisten-Steuerung im Stil des Kontrollzentrums.

> Status: **erstes Gerüst** (v0.1). UI, Engine-Protokoll und Python-Helper stehen; der Audio-Pfad ist bis zur FIFO verdrahtet, aber noch nicht mit echter Hardware getestet.

## Architektur

```
┌──────────────────────────── macOS-App (SwiftUI, Swift 6) ────────────────────────────┐
│  Hauptfenster (NavigationSplitView)   MenuBarExtra (Glass-Module)   Settings          │
│                 │                                                                     │
│            AppModel (@Observable, MainActor)                                          │
│        ┌────────┴──────────────┐                                                      │
│  BroadcastEngine (Protokoll)   AudioCapture (Protokoll)                               │
│   ├─ BumbleEngineClient         └─ ProcessTapCapture                                  │
│   └─ MockEngine (Previews)          CATapDescription / AudioHardwareCreateProcessTap  │
│        │  JSON Lines (stdin/stdout)        │ Float32-PCM                              │
└────────┼───────────────────────────────────┼─────────────────────────────────────────┘
         ▼                                   ▼
  engine/auracaster_helper.py  ◀──── PCMTransport: Named Pipe (FIFO)  → später Shared-Memory-Ringpuffer
  (Python, Bumble aus diesem Repo, LC3-Encoder via lc3py)
         │  HCI über USB (libusb)
         ▼
  USB-HCI-Dongle: nRF52840 mit Zephyr `samples/bluetooth/hci_usb`
  (CONFIG_BT_ISO_BROADCASTER, CONFIG_BT_CTLR_ADV_ISO, Periodic Advertising)
         │  Extended + Periodic Advertising, BIG/BIS (LC3, 48 kHz, 7,5/10 ms)
         ▼
  Auracast-Empfänger (Hörgeräte, Earbuds, Lautsprecher …)
```

**Warum ein Dongle?** Der interne Bluetooth-Chip des Mac ist für eigene Stacks nicht nutzbar: macOS gibt keinen rohen HCI-Zugriff frei, und CoreBluetooth bietet weder LE-Audio-Broadcast (BIG/BIS) noch Periodic Advertising als Sender an. Deshalb läuft der komplette Host-Stack (Bumble) in Python und spricht über USB direkt mit einem eigenen Controller.

### Bausteine

| Ebene | Datei(en) | Aufgabe |
|---|---|---|
| App | `Auracaster/App/AuracasterApp.swift` | `WindowGroup` (Hauptfenster), `MenuBarExtra` (.window-Stil), `Settings`; sauberes Beenden des Helpers |
| Model | `Model/AppModel.swift` | Zentraler Zustand, Start/Stopp-Ablauf (Tap → FIFO → Helper → Capture) |
| Model | `Model/BroadcastPreset.swift` | Presets: Ultra-Low (7,5 ms, 10 ms Delay), Ausgewogen (10 ms, 20 ms), Hohe Qualität (10 ms, 40 ms, 96 kbit/s) |
| Engine | `Engine/BroadcastEngine.swift` | Protokoll `BroadcastEngine`, Events, Status-Typen |
| Engine | `Engine/BumbleEngineClient.swift` | Startet `auracaster_helper.py` als Subprozess, JSON Lines über stdin/stdout, stderr → Log |
| Engine | `Engine/HelperProtocol.swift` | Wire-Format (Befehle/Events, snake_case) |
| Engine | `Engine/MockEngine.swift` | Simulation (Pegel, Scan) für Previews und UI-Arbeit ohne Dongle |
| Audio | `Audio/ProcessTapCapture.swift` | Core Audio Process Tap (systemweit/pro App) + Eingangsgeräte, IOProc |
| Audio | `Audio/PCMTransport.swift` | FIFO-Transport (echt), Shared-Memory-Ringpuffer (Stub mit Layout) |
| UI | `Views/…` | Studio, Routing-Matrix (Canvas), Quellen, Empfänger, Einstellungen, Menüleiste |
| Helper | `../engine/auracaster_helper.py` | Bumble-Broadcaster: Advertising, BIG, LC3-Encoding, Pegel, Scan |

### Steuerprotokoll (JSON Lines)

App → Helper (stdin), eine Zeile pro Befehl:

```json
{"cmd":"start","id":1,"broadcast":{"name":"Wohnzimmer","broadcast_id":0,"code":null,"language":"deu","public":true},
 "audio":{"input":"fifo:/tmp/auracaster-123.pcm","format":"float32le,48000,2"},
 "preset":{"frame_duration_us":7500,"bitrate":80000,"presentation_delay_us":10000,"rtn":2,"max_transport_latency_ms":10}}
{"cmd":"stop","id":2}
{"cmd":"status","id":3}
{"cmd":"scan","id":4,"duration":6}
{"cmd":"shutdown","id":5}
```

Helper → App (stdout): `ready`, `ack`, `error`, `status` (idle/starting/live/stopping/error), `level` (Peak/RMS in dBFS, ~20 Hz), `broadcast_found`, `scan_complete`. Logs gehen ausschließlich nach stderr.

Audio läuft **nicht** über stdin, sondern über einen eigenen Kanal (`PCMTransport`): derzeit eine Named Pipe mit Float32-PCM, später ein Shared-Memory-Ringpuffer (Layout in `PCMTransport.swift` dokumentiert).

## Design (macOS 27 „Golden Gate“)

Mockups und Spezifikation liegen in [`Design/`](Design/) (`gui_1_studio.png`, `gui_2_matrix.png`, `gui_3_menubar.png`, Logos, `design-spec.md`). Umgesetzte Regeln:

- System-Liquid-Glass (`.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)`) statt eigener Blur-Effekte.
- Einheitliche Toolbar mit prominentem On-Air-Button (rot, solange live), Latenz-Pill und Dongle-Status.
- Sidebar edge-to-edge mit **farbigen** SF-Symbol-Icons pro Kategorie.
- Standard-`WindowGroup`, keine eigene Fensterform, Systemschatten.
- Menü-Icons sparsam; in der Menüleisten-Extra sind Icons erlaubt.

App-Icon: Vektor-Master `Branding/AppIcon.svg` (Squircle, Indigo→Violett, weißer Punkt mit drei leuchtenden Ringen, Vorlage `Design/logo_a_halo.png`). Neu rendern mit:

```sh
pip install cairosvg
python3 Branding/make_icon.py   # schreibt AppIcon.svg + alle PNGs (16–1024 px) ins AppIcon.appiconset
```

Ein mehrschichtiges Icon-Composer-Icon (hell/dunkel/getönt/klar) ist ein offener Punkt.

## Build

Voraussetzungen: macOS 26 oder neuer (Ziel: macOS 27), Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Python ≥ 3.11.

```sh
# 1. Xcode-Projekt erzeugen
brew install xcodegen
cd macos
xcodegen generate          # erzeugt Auracaster.xcodeproj, Info.plist und Entitlements
open Auracaster.xcodeproj  # Schema „Auracaster“, ⌘R

# 2. Python-Umgebung für den Helper (im Repo-Root)
cd ..
python3 -m venv .venv
.venv/bin/pip install -r engine/requirements.txt   # Bumble aus diesem Repo + lc3py
```

In der App unter **Einstellungen → Engine**:

- Engine: *Bumble (USB-Dongle)* (Standard ist *Simulation*), danach App neu starten.
- Python: Pfad zu `.venv/bin/python` (absolut).
- Transport: `usb:0` oder gezielt per VID/PID, z. B. `usb:2FE3:000B` (typisch für Zephyr `hci_usb`; mit `bumble-usb-probe` prüfen).
- Hinweis: `/usr/bin/python3` von macOS ist zu alt (Bumble braucht ≥ 3.11) – unbedingt das venv angeben.

Helper ohne App testen:

```sh
.venv/bin/python engine/auracaster_helper.py --transport usb:0
{"cmd":"start","id":1,"audio":{"input":"silence"}}
{"cmd":"stop","id":2}
```

### Dongle vorbereiten (nRF52840)

Zephyr-Sample `samples/bluetooth/hci_usb` mit ISO-Broadcast bauen, z. B. für den nRF52840-Dongle:

```sh
west build -b nrf52840dongle/nrf52840 samples/bluetooth/hci_usb -- \
  -DCONFIG_BT_CTLR_ADV_EXT=y -DCONFIG_BT_CTLR_ADV_PERIODIC=y \
  -DCONFIG_BT_CTLR_ADV_ISO=y -DCONFIG_BT_ISO_BROADCASTER=y \
  -DCONFIG_BT_CTLR_ISO_TX_BUFFERS=8 -DCONFIG_BT_CTLR_ISO_TX_BUFFER_SIZE=251
```

(Die genauen Kconfig-Optionen hängen von der Zephyr-Version ab; ggf. das Overlay aus `samples/bluetooth/hci_uart`/`iso_broadcast` übernehmen.)

### Berechtigungen

- **Systemaudio-Aufnahme**: beim ersten Start eines Taps fragt macOS nach (`NSAudioCaptureUsageDescription`).
- **Mikrofon**: für Eingangsgeräte (`NSMicrophoneUsageDescription`).
- Die App ist derzeit **nicht sandboxed**, weil der Python-Helper libusb benutzt.

## Was ist echt, was ist Stub?

| Bereich | Stand |
|---|---|
| SwiftUI-Oberfläche (Studio, Routing, Quellen, Empfänger, Einstellungen, Menüleiste) | implementiert |
| `MockEngine` | implementiert (Simulation) |
| `BumbleEngineClient` (Subprozess, JSON Lines, Logs) | implementiert, noch ohne Hardware-Test |
| Helper: Advertising, BIG, LC3, Pegel, Scan, Stop | implementiert; gegen Bumbles virtuellen Controller getestet (ohne ISO-Datenpfad) |
| Process Tap (systemweit/App) + Eingangsgeräte | implementiert, Kompilierung/Laufzeit auf dem Mac noch zu prüfen |
| PCM über Named Pipe (Float32, Lautstärke) | implementiert |
| Resampling (z. B. 44,1 → 48 kHz) | fehlt – nur 16/24/48 kHz werden akzeptiert |
| Shared-Memory-Ringpuffer | Stub mit dokumentiertem Layout |
| Empfängerliste | Platzhalter (benötigt Broadcast Assistant) |
| Routing-Matrix | UI echt; nur Stream 1 wird gesendet |
| QR-Code (Broadcast Audio URI) | implementiert, mit Assistenten noch zu verifizieren |

## Roadmap

1. **Hardware-Inbetriebnahme**: nRF52840 + Zephyr `hci_usb`, End-to-End-Test mit Hörgeräten/Earbuds, Latenz messen und Presets kalibrieren.
2. **Shared-Memory-Ringpuffer** statt FIFO (lock-free SPSC, `mmap` im Helper), Resampling via `AVAudioConverter`.
3. **Virtuelles CoreAudio-Gerät** (AudioServerPlugIn, „Auracaster Output“) – beliebige Apps wählen Auracaster als Ausgabegerät.
4. **AU/VST3-Plugin für Ableton Live** – Send-Effekt, der den Kanal direkt in den Broadcast speist.
5. **Mehrere Streams**: mehrere BIGs bzw. BIG-Subgroups (z. B. Sprachen, Hörhilfe-Mono), Routing-Matrix voll funktionsfähig.
6. **Verschlüsselung** (Broadcast Code) in UI + QR-Code, getestet mit Empfängern.
7. **Scan / Receive / Assist**: Auracast in der Nähe empfangen, Broadcast-Assistant-Rolle (BASS) für echte Empfängerliste.
8. **Kurzbefehle (Shortcuts/App Intents)**: Broadcast starten/stoppen, Quelle/Preset wechseln.
9. Icon-Composer-Icon (mehrschichtig, hell/dunkel/getönt/klar), Sandboxing über XPC-Helper, Signierung/Notarisierung.

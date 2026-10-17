# Auracaster für macOS

Auracaster sendet Audio vom Mac – das gesamte Systemaudio, einzelne Apps (z. B. Ableton Live, Musik) oder ein Mikrofon/Audio-Interface – als **Auracast™-Broadcast** (Bluetooth LE Audio, Broadcast Isochronous Stream). Jedes Auracast-fähige Gerät in Reichweite kann zuhören: Hörgeräte, Earbuds, Lautsprecher, Smartphones.

Ziele: niedrige Latenz (Preset *Ultra-Low* ≈ 18 ms), eine native Mac-Oberfläche für macOS 27 „Golden Gate“ und eine Menüleisten-Steuerung im Stil des Kontrollzentrums.

> Status: **v0.1**. UI, Engine-Protokoll, Python-Helper, Updater, Assistent und Installer stehen; der Audio-Pfad ist bis zur FIFO verdrahtet, aber noch nicht mit echter Hardware getestet.

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
         │  HCI H4 über USB-CDC (serial, Transport auto)
         ▼
  Auracaster Dongle: nRF52840 (Pro Micro), Zephyr `hci_uart` (H4 über USB-CDC)
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

## Fertige App laden

Für Nutzer: **[Auracaster-macOS.dmg](https://github.com/thegroovex/Auracaster/releases/latest/download/Auracaster-macOS.dmg)** aus dem
[neuesten Release](https://github.com/thegroovex/Auracaster/releases/latest) – die bebilderte Schritt-für-Schritt-Anleitung steht im
[Haupt-README](../README.md#installation-schritt-für-schritt) und als „Zuerst lesen“ im DMG. Ohne Gatekeeper-Abfrage per Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/thegroovex/Auracaster/main/macos/Installer/install.sh | bash
```

Zwischenstände: jeder Push auf `main` baut unter **Actions → Auracaster macOS app** die Artefakte `Auracaster-macOS` (ZIP + DMG) und `screenshots`.

## Erster Start, Engine, Updates

| Baustein | Datei(en) | Aufgabe |
|---|---|---|
| Willkommens-Assistent | `Onboarding/OnboardingView.swift` | 4 Schritte (Was ist Auracaster → Dongle → Engine & Audio → erster Stream); erneut über *Hilfe → Einrichtungsassistent …* |
| Dongle-Erkennung | `Onboarding/DongleDetector.swift` | IOKit: USB `2fe3:0004` („Auracaster Dongle“), UF2-Bootloader-Laufwerk (`INFO_UF2.TXT`), `/dev/cu.usbmodem*` |
| Engine-Einrichtung | `Onboarding/EngineSetup.swift`, `../engine/setup-engine.sh` | Ein Klick: `uv` → Python 3.12-venv in `~/Library/Application Support/Auracaster/venv` → Bumble (Tarball dieses Repos, Tag = App-Version) + lc3py; stellt danach Engine *Bumble* + Transport `auto` ein. Kein Xcode/Homebrew/git nötig. `BumbleEngineClient` nimmt dieses venv automatisch, solange kein eigener Python-Pfad gesetzt ist. |
| Updater | `Update/UpdateService.swift`, `Update/UpdateController.swift`, `Update/UpdateSheet.swift` | GitHub-Releases-API (`/releases/latest`), SemVer-Vergleich, Sheet mit Release-Notes, Download (ZIP bevorzugt, DMG möglich) mit Fortschritt, Entpacken (`ditto`/`hdiutil`), Prüfung von Bundle-ID und Signatur (`codesign --verify`), Austausch nach dem Beenden durch ein Hilfsskript (Backup + Rollback, `xattr -dr com.apple.quarantine`, Neustart). Menü *Auracaster → Nach Updates suchen …*, Menüleiste (⋯), Toolbar-Badge, Einstellung „Automatisch täglich prüfen“ (Standard an). |

Warum kein Sparkle? Ohne Developer-ID und EdDSA-Schlüsselinfrastruktur bringt es wenig; per `URLSession` geladene Dateien bekommen
ohnehin kein Quarantäne-Attribut, Updates lösen also kein Gatekeeper aus.

**Signatur:** Release-Builds sind ad-hoc signiert mit fester designierter Anforderung
(`codesign -s - -r='=designated => identifier "de.groovex.Auracaster"'`), damit Datenschutz-Freigaben (Audioaufnahme, Mikrofon) Updates überleben.
Nicht notarisiert – deshalb DMG mit *Gatekeeper-Fix.command* und Anleitung „Dennoch öffnen“.

## Screenshot-Modus (Doku-Bilder aus der echten App)

```sh
Auracaster.app/Contents/MacOS/Auracaster -AuracasterExportScreenshots /tmp/shots
```

Startet mit `MockEngine` und Demo-Daten (On Air), überspringt Assistent und Update-Prüfung, schaltet Studio, Routing, Empfänger,
Quellen und Einstellungen sowie Menüleisten-Panel, Assistent und Update-Dialog jeweils hell und dunkel durch und schreibt
`app-<name>.png` (In-Process-Rendering per `cacheDisplay`) bzw. – wenn ein Helfer auf `request-<name>.txt` mit `screencapture -l <id>`
antwortet – `window-<name>.png` (Compositor-Aufnahme inkl. Liquid Glass). Die CI macht genau das (`ScreenshotMode.swift`, Workflow-Schritt
*Screenshots*); die besten Bilder liegen in [`../docs/images/`](../docs/images/).

## Installer & Release

- `Installer/make_artwork.py` – rendert DMG-Hintergrund und Anleitungsgrafiken (`docs/images/guide-*.png`).
- `Installer/make_liesmich.py` – baut „Zuerst lesen.html“ (offline, Bilder eingebettet) für das DMG.
- `Installer/Gatekeeper-Fix.command`, `Installer/install.sh` – Quarantäne entfernen bzw. Installation per Terminal.
- Workflow `.github/workflows/auracaster-macos.yml`: Build → Signatur → Screenshots → ZIP + DMG (create-dmg). Nur bei Tags `v*`
  zusätzlich Firmware (`firmware.yml` als Reusable Workflow) und Veröffentlichung per `softprops/action-gh-release`.
  Neues Release: Version in `project.yml` anheben, `git tag vX.Y.Z && git push origin vX.Y.Z` (die Version im Build kommt aus dem Tag).

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
- Python: Pfad zu `.venv/bin/python` (absolut) – oder leer lassen, dann nimmt die App das venv aus *Engine einrichten*.
- Transport: `auto` (Standard: findet den Auracaster Dongle als `serial:/dev/cu.usbmodem…,resync`), alternativ explizit `serial:…` oder `usb:0`.
- Hinweis: `/usr/bin/python3` von macOS ist zu alt (Bumble braucht ≥ 3.11) – unbedingt das venv angeben.

Helper ohne App testen:

```sh
.venv/bin/python engine/auracaster_helper.py --transport usb:0
{"cmd":"start","id":1,"audio":{"input":"silence"}}
{"cmd":"stop","id":2}
```

### Dongle vorbereiten (nRF52840)

Fertige UF2-Dateien liegen in jedem Release; Quelle, Bootloader-Varianten und Selbstbau in [`../firmware/README.md`](../firmware/README.md)
(Zephyr `hci_uart` = HCI H4 über USB-CDC, weil Zephyrs `hci_usb` keinen ISO-Datenpfad hat).

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

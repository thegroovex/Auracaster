# Auracaster – Design-Spec (macOS 27 Golden Gate)

Gewählt: Logo **A Halo** (design/logo_a_halo.png), GUI = Kombination 1 Studio (Hauptfenster) + 2 Routing-Matrix (Tab) + 3 Menüleisten-Extra.

## Golden-Gate-Regeln (Quellen: Apple-Release-Notes macOS 27, MacRumors 2026-06-09, 9to5Mac 2026-06-09)
- Liquid Glass überarbeitet: gleichmäßigere Refraktion, besserer Kontrast, dunklere Kante + hellere Glanzlichter. Systemmaterialien nutzen (`.glassEffect`), keine eigenen Blur-Hacks; respektiert den Nutzer-Slider "klar ↔ getönt".
- **Einheitliche Toolbar** oben (unified toolbar), Steuerelemente in der Toolbar statt eigener Kopfzeile.
- **Sidebar edge-to-edge**, nicht schwebend, ohne extra Schatten. **Sidebar-Icons wieder farbig** (SF Symbols mit Farbe pro Kategorie).
- Engere, einheitliche Fensterecken – Standard-`WindowGroup`, keine eigene Fensterform.
- App-Icon: Squircle Pflicht, mehrschichtiges Liquid-Glass-Icon (Icon Composer), Varianten hell/dunkel/getönt/klar.
- Menü-Icons nur sparsam und mit Zweck (Geräte, häufige Aktionen). Menüleisten-Extra: Icons erlaubt.
- Aktives Fenster deutlicher (Systemschatten) – nichts überschreiben.

## Mapping auf Mockups
- On-Air-Button in die Toolbar (prominent, Glass, rot wenn live). Latenz-Pill + Dongle-Status ebenfalls Toolbar.
- Sidebar: Quellen (farbige Icons), Broadcasts, Empfänger, Einstellungen.
- Detail: große Latenzanzeige, Preset-Segmented-Control, Pegel, Codec-Karte, QR-Code.
- Routing-Tab: Node-Matrix Quellen → Streams.
- MenuBarExtra im Kontrollzentrum-Stil (Glass-Module).

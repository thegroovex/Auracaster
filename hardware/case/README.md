# Auracaster – Gehäuse für den Sender-Dongle

Stick-Gehäuse für das **„Pro Micro nRF52840“** (nice!nano-v2-Klon, Pro-Micro-Formfaktor,
z. B. Ulegqin, Amazon B0HFJQLBFK). Zwei Teile – **Wanne** und **Deckel** – halten per
Reibschluss + zwei Schnappnasen, ohne Schrauben. Beide Teile drucken flach **ohne Stützmaterial**.

![Zusammengebaut](preview/assembled_iso.png)
![Explosionsansicht](preview/exploded.png)

| Datei | Inhalt |
|---|---|
| `auracaster_case.scad` | parametrisches OpenSCAD-Modell (alle Maße oben im Skript) |
| `tray.stl` / `tray.3mf` | Wanne (Boden), schon in Druckorientierung |
| `tray_eye.stl` / `tray_eye.3mf` | Wanne mit Öse für Schlüsselband |
| `lid_print.stl` / `lid_print.3mf` | Deckel, **Oberseite nach unten** (Druckorientierung) |
| `preview.scad`, `build.sh` | Vorschau-Szene und Skript zum Neuerzeugen aller Dateien |
| `preview/*.png` | Vorschauen: zusammengebaut, explodiert, Draufsicht, USB-Seite, Schnitt, Öse, Druckbett |

## Außenmaße (Standardparameter)

- **37,5 × 22,2 × 9,2 mm** (L × B × H), mit Öse **43,7 mm** lang
- Wanne 7,4 mm hoch, Deckel 1,8 mm Platte + 2,1 mm Steckrand
- Wand 1,8 mm (seitlich, USB-Seite), **1,4 mm am Antennenende**, Boden 1,4 mm,
  Deckel 1,8 mm (1,3 mm unter dem Halo-Relief, **1,2 mm über der Antenne**)

## Merkmale

- **USB-C-Öffnung 12,5 × 7 mm** (abgerundet) für die Stecker-Umspritzung; die Buchse ragt 0,8 mm
  in die Wand, der Stecker taucht ~1 mm ein.
- **Board-Fixierung:** zwei Auflageleisten unter den PCB-Längskanten + kleiner Stützpunkt;
  der umlaufende Steckrand des Deckels drückt von oben auf die Pad-Reihen (0,1 mm Vorspannung).
  In Längsrichtung liegt die PCB zwischen USB-Stirnwand und Antennen-Stirnwand.
- **Antennenzone (letzte 7 mm):** keine Rippen, kein Steckrand, Deckel von innen auf 1,2 mm
  ausgedünnt, dünne Stirnwand. Kein Metall im Gehäuse.
- **Reset:** 1,5-mm-Loch mit Führungsröhrchen genau über der Mitte zwischen **GND- und RST-Pad**
  (rechte Lochreihe, Pos. 2/3 ab USB). Eine aufgebogene Büroklammer brückt beide Pads →
  **zweimal schnell drücken** = UF2-Bootloader (Laufwerk erscheint).
  Ein reiner „Flex-Taster“ aus Kunststoff kann zwei Pads nicht leitend verbinden, daher Loch statt Taster.
- **Status-LED:** von innen gebohrtes Fenster mit 0,45 mm Haut – leuchtet durch helles/weißes PLA.
  Mit `led_mode="hole"` wird ein Durchgangsloch daraus (für dunkle Filamente oder einen Lichtleiter Ø 3 mm).
- **Optik „Halo“:** 0,5 mm tief eingelassener Punkt + drei Aura-Ringe auf dem Deckel,
  Squircle-Grundriss (Superellipsen-Ecken), Kanten gerundet (unter 45° als Fase gekappt → stützfrei),
  „AURACASTER“ 0,4 mm in die Seitenwand eingeprägt.
- **Öse (Variante):** nur für **Textil-Schlüsselband** – kein Metall-Schlüsselring am Antennenende!

## Druckeinstellungen

| | |
|---|---|
| Düse | 0,4 mm |
| Schichthöhe | **0,2 mm** (Deckel optional 0,12–0,16 mm für feinere Ringe) |
| Perimeter | **3** |
| Infill | **20 %** (Gyroid oder Grid) |
| Top/Bottom | 5 / 4 Schichten |
| Stützmaterial | **aus** |
| Material | **PLA** (einfach, Deckel in Weiß für das LED-Fenster) oder **PETG** (wärmefester, zäher Schnapp). Für den Look: Wanne dunkel, Deckel weiß. |
| Orientierung | `tray*.stl` mit Boden aufs Bett, `lid_print.stl` mit Oberseite (Halo) aufs Bett – beide Dateien liegen schon richtig |
| Elefantenfuß | Kompensation 0,1–0,15 mm einschalten (Halo-Ringe liegen am Bett) |

PETG schrumpft weniger, ist aber „klebriger“: bei PETG `fit_clr` auf 0,15 und `snap_h` auf 0,25 setzen.

## Montage

1. Board (ohne Stiftleisten) Bauteilseite nach oben, USB-Buchse voran, in die Wanne legen – die Buchse
   sitzt in der Aussparung.
2. Deckel mit dem Reset-Loch auf der Seite der USB-Buchse aufsetzen (Halo zeigt nach oben) und
   gleichmäßig eindrücken, bis beide Schnappnasen einrasten.
3. Öffnen: Fingernagel/Plektrum am Antennenende zwischen Deckel und Wanne.

## Nach Erhalt des Boards nachmessen (Messschieber)

Klone weichen ab – bitte diese Werte messen und oben im `.scad` eintragen, dann `./build.sh`:

| Parameter | Was messen | Standard |
|---|---|---|
| `pcb_l` | PCB-Länge **ohne** USB-Überstand | 33,8 |
| `pcb_w` | PCB-Breite | 18,1 |
| `pcb_t` | PCB-Stärke (an der Kante) | 1,6 (oft 1,0!) |
| `usb_over` | wie weit die USB-Buchse über die PCB-Kante steht | 0,8 |
| `usb_below` | wie weit die Buchse unter die PCB-Unterseite ragt (Mid-Mount) | 1,0 |
| `usb_y` | seitlicher Versatz der Buchse (meist 0) | 0 |
| `comp_top` | höchstes Bauteil auf der Oberseite (außer USB) + 0,5 mm | 2,0 |
| `pin0_x` | Mitte der ersten (USB-nächsten) Lochposition ab PCB-Kante | 1,27 |
| `rst_idx`, `rst_side` | Lage von GND/RST: Positionsnummer ab USB (0-basiert, Mitte zwischen beiden) und Seite (+1 rechts in Draufsicht, USB oben) | 2,5 / +1 |
| `led_x`, `led_y` | Mitte der Status-LED ab USB-Kante / ab Boardmitte | 6,0 / −4,0 |
| `ant_len` | Länge der Antennenzone (Chip-Antenne + Freifläche) | 7,0 |
| `center_post` | auf `false`, wenn unter der PCB bei x≈25 mm Bauteile sitzen | true |

Feintuning: `clr` (Spiel Board, 0,15–0,4), `fit_clr` (Deckelsitz; zu locker → 0,08, zu stramm → 0,18),
`snap_h` (Rasthöhe 0,2–0,4), `press` (Vorspannung auf die PCB).
Das Skript prüft per `assert`, dass USB-Aussparung, Halo und Schrift keine Wand unter 1,2 mm erzeugen.

## Neu erzeugen

```bash
openscad -D 'part="lid_print"' -o lid_print.stl auracaster_case.scad   # einzelnes Teil
./build.sh                                                             # alles inkl. PNGs
```

Geprüft: alle STL/3MF wasserdicht/manifold (trimesh, ein Körper je Teil), keine Durchdringung
Wanne↔Deckel, einzige Board-Berührung ist die gewollte 0,1-mm-Vorspannung des Steckrands.
Maße aus: nicekeyboards.com/docs/nice-nano (3,2 mm Gesamthöhe, Pinout), mechboards.co.uk
(34,1 × 18,3 × 3,3 mm), astrobeano.blogspot.com (Klon 17,78 × 33,0 mm, 13 Positionen inkl. Akku-Pads).

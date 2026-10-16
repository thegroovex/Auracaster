#!/usr/bin/env bash
# Erzeugt STL/3MF + Vorschau-PNGs neu.  OPENSCAD=/pfad/zu/openscad ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
OS=${OPENSCAD:-openscad}
X=""; command -v xvfb-run >/dev/null && [ -z "${DISPLAY:-}" ] && X="xvfb-run -a"
mkdir -p build preview
for p in tray lid_print; do
  $OS -D "part=\"$p\"" -o $p.stl auracaster_case.scad
  $OS -D "part=\"$p\"" -o $p.3mf auracaster_case.scad
done
$OS -D 'part="tray"' -D with_eye=true -o tray_eye.stl auracaster_case.scad
$OS -D 'part="tray"' -D with_eye=true -o tray_eye.3mf auracaster_case.scad
$OS -D 'part="lid"' -o build/lid_asm.stl auracaster_case.scad
r(){ $X $OS -D 'part="none"' -D "view=\"$1\"" --colorscheme=Tomorrow --imgsize=1400,1000 --projection=${4:-p} --camera=$2 -o preview/$3.png preview.scad; }
r assembled 18.7,0,4.6,55,0,35,95 assembled_iso
r exploded  18.7,0,9,55,0,35,115 exploded
r top       17.6,0,4.6,22,0,0,70 top o
r usb       -2,0,4.6,80,0,250,70 usb_end
r section   18.7,0,4.6,80,0,270,60 section_rst
r eye       21,0,4.6,55,0,35,105 variant_eye
r plate     18.7,13,0,50,0,20,120 print_plate

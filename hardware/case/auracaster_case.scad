// =====================================================================
//  AURACASTER – Gehäuse für den Auracast-Sender-Dongle
//  Board: "Pro Micro nRF52840" (nice!nano-v2-Klon, z. B. Ulegqin B0HFJQLBFK)
//  FDM, 0,4-mm-Düse, PLA/PETG, beide Teile flach OHNE Stützmaterial.
//
//  Koordinaten: x = Boardlänge (x=0 = USB-seitige PCB-Kante, +x Richtung
//  Antenne), y = quer (0 = Boardmitte), z = hoch (0 = Unterseite Boden).
//  Board liegt Bauteilseite nach OBEN (USB-C mid-mount, Pads an den Längsseiten).
//
//  Teile:  part = "tray" | "lid" | "lid_print" | "tray_print" |
//               "assembled" | "exploded" | "top" | "board"
//  Aufruf: openscad -D 'part="lid_print"' -o lid.stl auracaster_case.scad
// =====================================================================

part      = "assembled";
with_eye  = false;      // true = Öse für Schlüsselband (nur Textilband, kein Metallring!)

/* ---------- [Board – NACHMESSEN] ---------- */
pcb_l       = 33.8;   // PCB-Länge ohne USB-Überstand (Quellen: 33,0 … 34,1)
pcb_w       = 18.1;   // PCB-Breite (17,78 … 18,3)
pcb_t       = 1.6;    // PCB-Stärke (1,0 … 1,6) – bei 1,0-mm-Board hier 1.0 setzen!
clr         = 0.25;   // Spiel Board ↔ Gehäuse rundum (0,15 … 0,4)

usb_w       = 8.94;   // USB-C-Buchse Breite
usb_h       = 3.26;   // USB-C-Buchse Höhe
usb_below   = 1.0;    // wie weit die Mid-Mount-Buchse UNTER die PCB-Unterseite ragt
usb_over    = 0.8;    // Überstand der Buchse über die PCB-Kante (x<0)
usb_y       = 0;      // seitlicher Versatz der Buchse (0 = mittig)
plug_w      = 12.5;   // Aussparung für Stecker-Umspritzung (Breite)
plug_h      = 7.0;    // … (Höhe)
plug_r      = 1.6;    // Eckradius der Aussparung

comp_top    = 2.0;    // Freiraum über PCB-Oberseite (höchstes Bauteil außer USB +Luft)
gap_bottom  = 2.4;    // Freiraum unter PCB (≥ usb_below + 0,4; bestimmt USB-Höhe)
ant_len     = 7.0;
center_post = true;   // kleiner Stützpunkt unter der PCB (aus, falls dort Bauteile auf der Unterseite)    // Länge der Antennenzone am Board-Ende (keine Rippen, dünner Deckel)

pitch       = 2.54;   // Lochraster
row_sp      = 15.24;  // Abstand der beiden Lochreihen (0,6")
pin0_x      = 1.27;   // Mitte der ersten Lochposition ab USB-Kante (nice!nano: 13 Pos.)
rst_idx     = 2.5;    // Reset-Loch zwischen GND (Pos. 2) und RST (Pos. 3) → Büroklammer brückt
rst_side    = 1;      // +1 = rechte Reihe (Draufsicht, USB oben), -1 = linke
rst_d       = 1.5;    // Lochdurchmesser für Büroklammer
rst_tube    = true;   // Führungsröhrchen bis kurz über die Pads

led_x       = 6.0;    // Status-LED Position (ab USB-Kante) – NACHMESSEN
led_y       = -4.0;   // (+ = rechte Seite in Draufsicht, USB oben)
led_d       = 3.2;    // Fenster-/Lochdurchmesser
led_mode    = "window"; // "window" = 0,45-mm-Haut (leuchtet durch helles PLA) | "hole"
led_skin    = 0.45;

/* ---------- [Gehäuse] ---------- */
floor_t     = 1.4;    // Bodenstärke
wall        = 1.8;    // Seitenwand
wall_usb    = 1.8;    // Wand an der USB-Seite
wall_ant    = 1.4;    // dünne Wand am Antennenende (oben nach Einführfase 1,2)
lid_t       = 1.8;    // Deckelplatte
lid_ant_t   = 1.2;    // Deckel über der Antenne (von innen ausgedünnt)
corner_r    = 5.0;    // Eckradius Grundriss (Squircle-Ecke)
corner_n    = 4;      // Superellipsen-Exponent der Ecke (2 = Kreis, 4 = Squircle)
r_bot       = 1.6;    // Kantenrundung unten (unter 45° gekappt → druckbar)
r_top       = 1.5;    // Kantenrundung Deckel oben (ebenso)

lip_t       = 0.9;    // Steckrand des Deckels (sitzt innen in der Wanne)
fit_clr     = 0.12;   // Spiel Steckrand ↔ Wannen-Innenwand (Reibschluss)
press       = 0.10;   // Steckrand drückt so viel auf die PCB-Oberkante
snap_h      = 0.30;   // Rasthöhe der Schnappnasen
snap_len    = 10;     // Länge der Schnappnasen
snap_clr    = 0.08;   // zusätzlicher Freiraum in der Rastnut

halo_depth  = 0.5;    // Tiefe Halo-Relief
halo_r      = [3.6, 5.6, 7.6];  // Ringradien (Mitte)
halo_w      = [1.0, 0.8, 0.7];  // Ringbreiten (≥0,6 für 0,4er Düse)
halo_dot    = 1.5;    // Radius Mittelpunkt
text_on     = true;
text_str    = "AURACASTER";
text_size   = 3.0;
text_depth  = 0.4;

eye_r       = 3.5;    // Ösen-Außenradius
eye_hole    = 3.4;    // Ösen-Loch
eye_h       = 3.0;    // Ösen-Höhe

explode     = 14;
$fn         = 64;

/* ---------- abgeleitete Maße ---------- */
in_x0   = -clr;                 in_x1 = pcb_l + clr;
in_w    = pcb_w + 2*clr;
o_x0    = in_x0 - wall_usb;     o_x1  = in_x1 + wall_ant;
o_w     = in_w + 2*wall;
o_l     = o_x1 - o_x0;
pcb_z0  = floor_t + gap_bottom;          // PCB-Unterseite
pcb_z1  = pcb_z0 + pcb_t;                // PCB-Oberseite
z_split = pcb_z1 + comp_top;             // Trennebene = Unterseite Deckelplatte
H       = z_split + lid_t;               // Gesamthöhe
usb_cz  = pcb_z0 - usb_below + usb_h/2;  // Mitte USB-Buchse
ant_x0  = pcb_l - ant_len;
eye_x   = o_x1 + eye_r - 0.8;
halo_x  = min((ant_x0 - max(halo_r) - 1.2), pcb_l/2);

assert(usb_cz - plug_h/2 >= 0.7, "USB-Aussparung schneidet den Boden – gap_bottom erhöhen");
assert(H - (usb_cz + plug_h/2) >= 1.0, "zu wenig Material über USB-Aussparung – comp_top/lid_t erhöhen");
assert(gap_bottom >= usb_below + 0.3, "gap_bottom < usb_below");
assert(lid_t - halo_depth >= 1.2, "Deckel unter Halo < 1,2 mm");
assert(wall - text_depth >= 1.2, "Wand unter Schriftzug < 1,2 mm");

echo(str("AUSSENMASSE (ohne Öse): L=", o_l, " B=", o_w, " H=", H, " mm"));
echo(str("mit Öse L=", (eye_x + eye_r) - o_x0));
echo(str("z_split=", z_split, " usb_cz=", usb_cz, " halo_x=", halo_x));

/* ---------- 2D-Grundformen ---------- */
module squircle_rect(x0, x1, w, r, n) {
    hw = w/2;
    function cp(cx, cy, sx, sy) =
        [for (t = [0:5:90]) [cx + sx*r*pow(cos(t), 2/n), cy + sy*r*pow(sin(t), 2/n)]];
    // Reihenfolge sortieren (CCW): Quadranten I, II (rückwärts), III, IV (rückwärts)
    q1 = cp(x1 - r,  hw - r,  1,  1);                       // 0..90° : rechts → oben
    q2 = [for (i=[18:-1:0]) cp(x0 + r,  hw - r, -1,  1)[i]]; // oben → links
    q3 = cp(x0 + r, -hw + r, -1, -1);                        // links → unten
    q4 = [for (i=[18:-1:0]) cp(x1 - r, -hw + r,  1, -1)[i]]; // unten → rechts
    polygon(concat(q1, q2, q3, q4));
}
module outline2d() { squircle_rect(o_x0, o_x1, o_w, corner_r, corner_n); }
module cavity2d(extra = 0) {
    r = 0.5;
    offset(r = r) offset(delta = -r)
        translate([in_x0 - extra, -in_w/2 - extra]) square([in_x1 - in_x0 + 2*extra, in_w + 2*extra]);
}

// Kantenprofil: Viertelkreis, unterhalb 45° als Fase fortgesetzt (stützfrei)
function inset_at(d, R) = let(zc = R*(1 - cos(45)))
    d <= zc ? (2*zc - d) : R - sqrt(max(0, R*R - (R - d)*(R - d)));

module outer_solid() {
    steps = 10;
    hull() {
        for (i = [0:steps]) {
            d = r_bot * i / steps;
            translate([0, 0, d]) linear_extrude(0.01) offset(delta = -inset_at(d, r_bot)) outline2d();
        }
        for (i = [0:steps]) {
            d = r_top * i / steps;
            translate([0, 0, H - d - 0.01]) linear_extrude(0.01) offset(delta = -inset_at(d, r_top)) outline2d();
        }
    }
}

/* ---------- Detail-Körper ---------- */
module usb_cut() {
    // Stecker-Aussparung durch die USB-Stirnwand
    translate([o_x0 - 1, usb_y, usb_cz])
        rotate([0, 90, 0]) linear_extrude(-o_x0 + 1 + 0.01)
            offset(r = plug_r) offset(delta = -plug_r) square([plug_h, plug_w], center = true);
}
module snap_profile(grow = 0) {
    // Dreiecksnase, 45°-Flanken → stützfrei
    h = snap_h + grow;
    polygon([[-0.3, -h - grow], [0, -h - grow], [h, 0], [0, h + grow], [-0.3, h + grow]]);
}
module snaps(grow = 0) {
    zc = z_split - comp_top/2;
    xc = ant_x0/2 + 1;
    for (s = [-1, 1])
        translate([xc - snap_len/2, s*(in_w/2 - fit_clr), zc])
            rotate([90, 0, 90]) linear_extrude(snap_len)
                mirror([s < 0 ? 1 : 0, 0]) snap_profile(grow);
}
module side_text() {
    if (text_on)
        translate([(o_x0 + o_x1)/2, -o_w/2 + text_depth, (r_bot + z_split)/2])
            rotate([90, 0, 0]) linear_extrude(text_depth + 1)
                text(text_str, size = text_size, font = "Liberation Sans:style=Bold",
                     halign = "center", valign = "center", spacing = 1.12);
}
module eye() {
    linear_extrude(eye_h) difference() {
        hull() {
            translate([eye_x, 0]) circle(r = eye_r);
            translate([o_x1 - 3, -eye_r]) square([1, 2*eye_r]);
        }
        translate([eye_x, 0]) circle(d = eye_hole);
    }
}

/* ---------- WANNE (Boden) ---------- */
module tray() {
    difference() {
        union() {
            intersection() {
                outer_solid();
                translate([o_x0 - 1, -o_w, -1]) cube([o_l + 2, 2*o_w, z_split + 1]);
            }
            if (with_eye) eye();
        }
        // Innenraum
        translate([0, 0, floor_t]) linear_extrude(H) cavity2d();
        // Einführfase oben innen
        hull() {
            translate([0, 0, z_split - 0.4]) linear_extrude(0.01) cavity2d();
            translate([0, 0, z_split]) linear_extrude(0.01) offset(delta = 0.2) cavity2d();
        }
        usb_cut();
        snaps(snap_clr);           // Rastnuten
        side_text();
    }
    // Auflageleisten unter den PCB-Längskanten (nicht in der Antennenzone)
    lw = 1.2;
    for (s = [-1, 1])
        translate([0.6, s > 0 ? pcb_w/2 - lw : -in_w/2, floor_t - 0.01])
            cube([ant_x0 - 0.6, lw + clr, gap_bottom + 0.01]);
    // Stützpunkt unter der PCB-Mitte (Antennenseite, vor der Antennenzone)
    if (center_post) translate([ant_x0 - 2, 0, floor_t - 0.01]) cylinder(d = 2.4, h = gap_bottom + 0.01);
}

/* ---------- DECKEL ---------- */
rst_x = pin0_x + rst_idx * pitch;
rst_y = rst_side * row_sp / 2;

module lid() {
    difference() {
        union() {
            intersection() {
                outer_solid();
                translate([o_x0 - 1, -o_w, z_split]) cube([o_l + 2, 2*o_w, H]);
            }
            // Steckrand (innen) – drückt auf die PCB-Längskanten
            difference() {
                translate([0, 0, pcb_z1 - press]) linear_extrude(z_split - pcb_z1 + press + 0.01)
                    difference() { offset(delta = -fit_clr) cavity2d(); offset(delta = -fit_clr - lip_t) cavity2d(); }
                // Antennenzone frei
                translate([ant_x0, -o_w, 0]) cube([50, 2*o_w, H]);
                // USB-Buchse frei
                translate([o_x0 - 1, usb_y - plug_w/2, 0]) cube([-o_x0 + 1 + usb_over + 1.5, plug_w, H]);
            }
            snaps(0);
            if (rst_tube)
                translate([rst_x, rst_y, pcb_z1 + 0.6]) cylinder(d = rst_d + 1.8, h = z_split - pcb_z1 - 0.6 + 0.01);
        }
        usb_cut();
        // Halo-Relief
        translate([halo_x, 0, H - halo_depth]) linear_extrude(1) {
            circle(r = halo_dot);
            for (i = [0:len(halo_r) - 1])
                difference() { circle(r = halo_r[i] + halo_w[i]/2); circle(r = halo_r[i] - halo_w[i]/2); }
        }
        // Deckel über der Antenne von innen ausdünnen
        translate([0, 0, z_split - 0.01]) linear_extrude(lid_t - lid_ant_t + 0.01)
            intersection() { cavity2d(); translate([ant_x0, -o_w]) square([50, 2*o_w]); }
        // Reset-Loch (Büroklammer) + Fase
        translate([rst_x, rst_y, 0]) cylinder(d = rst_d, h = H + 1);
        translate([rst_x, rst_y, H - 0.5]) cylinder(d1 = rst_d, d2 = rst_d + 1.2, h = 0.51);
        // LED
        if (led_mode == "hole") translate([led_x, led_y, 0]) cylinder(d = led_d, h = H + 1);
        else translate([led_x, led_y, z_split - 1]) cylinder(d = led_d, h = 1 + lid_t - led_skin);
    }
}

/* ---------- Board-Dummy (nur Vorschau) ---------- */
module board() {
    color("darkgreen") difference() {
        translate([0, -pcb_w/2, pcb_z0]) cube([pcb_l, pcb_w, pcb_t]);
        for (s = [-1, 1], k = [0:12]) translate([pin0_x + k*pitch, s*row_sp/2, 0]) cylinder(d = 1.0, h = 20, $fn = 12);
    }
    color("gold") for (s = [-1, 1], k = [0:12])
        translate([pin0_x + k*pitch, s*row_sp/2, pcb_z1]) cylinder(d = 1.7, h = 0.05, $fn = 16);
    color("silver") translate([-usb_over, usb_y - usb_w/2, pcb_z0 - usb_below]) cube([7.35, usb_w, usb_h]);
    color("black") translate([pcb_l/2 - 6, -3.5, pcb_z1]) cube([7, 7, 0.9]);
    color("white") translate([pcb_l - ant_len + 1.5, -1.5, pcb_z1]) cube([3.2, 1.6, 1.1]);   // Chip-Antenne
    color("red") translate([led_x, led_y, pcb_z1]) cylinder(d = 1.0, h = 0.6);
}
module plug() { // USB-C-Stecker-Umspritzung (Vorschau)
    color("dimgray") translate([o_x0 - 20, usb_y - 12.2/2, usb_cz - 6.5/2]) cube([20 + wall_usb - 0.9, 12.2, 6.5]);
}

/* ---------- Ausgabe ---------- */
lid_col = [0.93, 0.93, 0.95];
tray_col = [0.20, 0.22, 0.30];
if (part == "tray")        tray();
if (part == "tray_print")  tray();
if (part == "lid")         lid();
if (part == "lid_print")   translate([0, 0, H]) rotate([180, 0, 0]) lid();   // Oberseite aufs Bett
if (part == "board")       board();
if (part == "assembled")   { color(tray_col) tray(); color(lid_col) lid(); }
if (part == "assembled_x") { color(tray_col) tray(); color(lid_col, 0.35) lid(); board(); plug(); }
if (part == "exploded")    { color(tray_col) tray(); board(); color(lid_col) translate([0, 0, explode]) lid(); }
if (part == "exploded_under") { color(tray_col) tray(); board(); color(lid_col) translate([0, 0, explode + H]) rotate([180,0,0]) translate([0,0,-H]) lid(); }
if (part == "top")         { color(tray_col) tray(); color(lid_col) lid(); }
if (part == "section")     difference() { union() { color(tray_col) tray(); color(lid_col) lid(); board(); }
                                          translate([-50, 0, -10]) cube([100, 50, 50]); }
if (part == "section_x")   difference() { union() { color(tray_col) tray(); color(lid_col) lid(); board(); }
                                          translate([rst_x, -50, -10]) cube([100, 100, 50]); }

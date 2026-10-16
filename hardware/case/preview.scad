// Vorschau-Szene: importiert die exportierten STLs (zuverlässige Farben)
include <auracaster_case.scad>
view = "assembled";
T=[0.16,0.18,0.26]; L=[0.95,0.95,0.97];
module T_() color(T) import("tray.stl");
module L_() color(L) import("build/lid_asm.stl");
if (view=="assembled") { T_(); L_(); }
if (view=="exploded")  { T_(); board(); translate([0,0,14]) L_(); }
if (view=="top")       { T_(); L_(); }
if (view=="usb")       { T_(); L_(); board(); }
if (view=="section")   difference(){ union(){ T_(); L_(); board(); } translate([rst_x,-50,-10]) cube([200,100,50]); }
if (view=="section_y") difference(){ union(){ T_(); L_(); board(); } translate([-50,0,-10]) cube([200,50,50]); }
if (view=="eye")       { color(T) import("tray_eye.stl"); L_(); }
if (view=="plate")     { color(T) import("tray.stl"); color(L) translate([0,26,0]) import("lid_print.stl"); }

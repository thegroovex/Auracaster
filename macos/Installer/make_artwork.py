#!/usr/bin/env python3
"""Renders the installer artwork (Halo design) from SVG:

  macos/Installer/dmg-background.png (+ @2x)   DMG window background with arrow + hints
  docs/images/guide-install.png                 "drag the app to Programme"
  docs/images/guide-gatekeeper.png              System Settings → Privacy & Security → "Dennoch öffnen"
  docs/images/guide-flash.png                   flashing the dongle (2× reset → drive → UF2)

usage (repo root):  pip install cairosvg && python3 macos/Installer/make_artwork.py
Font: Inter (falls back to the system sans-serif).
"""
from __future__ import annotations

import base64
import pathlib

import cairosvg

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICON = ROOT / "macos/Auracaster/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png"
FONT = "Inter, 'SF Pro Display', Helvetica, Arial, sans-serif"
INDIGO, VIOLET, DEEP = "#3730A3", "#6D28D9", "#4C1D95"


def icon_href() -> str:
    return "data:image/png;base64," + base64.b64encode(ICON.read_bytes()).decode()


def render(svg: str, out: pathlib.Path, width: int, height: int, scale: int = 1) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out), output_width=width * scale,
                     output_height=height * scale)
    print("wrote", out.relative_to(ROOT))


def defs() -> str:
    return f"""
  <defs>
    <linearGradient id="brand" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{INDIGO}"/><stop offset=".55" stop-color="{DEEP}"/><stop offset="1" stop-color="{VIOLET}"/>
    </linearGradient>
    <linearGradient id="soft" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#F7F5FF"/><stop offset="1" stop-color="#ECE8FB"/>
    </linearGradient>
    <radialGradient id="glow" cx=".5" cy=".5" r=".5">
      <stop offset="0" stop-color="#A78BFA" stop-opacity=".45"/><stop offset="1" stop-color="#A78BFA" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="folder" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#7CC4FA"/><stop offset="1" stop-color="#3B9DF0"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="160%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#1E1B4B" flood-opacity=".18"/>
    </filter>
    <marker id="head" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="5" markerHeight="5" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="{VIOLET}"/>
    </marker>
  </defs>"""


def rings(cx: float, cy: float, radii=(70, 105, 140), opacity=(0.22, 0.14, 0.08), color=VIOLET) -> str:
    return "".join(
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{color}" stroke-opacity="{o}" stroke-width="2"/>'
        for r, o in zip(radii, opacity))


def folder(x: float, y: float, s: float = 1.0) -> str:
    """Applications folder icon, top-left (x, y), 100×80 at s=1."""
    return f"""<g transform="translate({x},{y}) scale({s})">
      <path d="M4,14 Q4,6 12,6 L38,6 L46,14 L88,14 Q96,14 96,22 L96,30 L4,30 Z" fill="#5FB0F5"/>
      <rect x="2" y="22" width="96" height="62" rx="9" fill="url(#folder)"/>
      <g transform="translate(50,54)" fill="none" stroke="#fff" stroke-opacity=".85" stroke-width="5" stroke-linecap="round">
        <path d="M-14,14 L0,-16 L14,14"/><path d="M-8,4 L8,4"/>
      </g></g>"""


def dmg_background() -> str:
    w, h = 680, 500
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{defs()}
  <rect width="{w}" height="{h}" fill="url(#soft)"/>
  <circle cx="175" cy="205" r="110" fill="url(#glow)"/>
  {rings(175, 205, (66, 90, 112))}
  <text x="40" y="52" font-family="{FONT}" font-size="26" font-weight="800" fill="{DEEP}">Auracaster</text>
  <text x="40" y="76" font-family="{FONT}" font-size="14" fill="#5B5675">Mac-Audio als Auracast™ – an beliebig viele Hörgeräte &amp; Kopfhörer</text>
  <path d="M262,196 C320,150 380,150 438,196" fill="none" stroke="{VIOLET}" stroke-width="6" stroke-linecap="round" marker-end="url(#head)"/>
  <text x="350" y="138" text-anchor="middle" font-family="{FONT}" font-size="15" font-weight="700" fill="{VIOLET}">1 · in „Programme“ ziehen</text>
  <rect x="24" y="292" width="632" height="1" fill="{VIOLET}" fill-opacity=".18"/>
  <text x="340" y="318" text-anchor="middle" font-family="{FONT}" font-size="14" font-weight="700" fill="{DEEP}">2 · Erster Start? Hier steht alles – mit Bildern</text>
  <text x="340" y="337" text-anchor="middle" font-family="{FONT}" font-size="12.5" fill="#5B5675">macOS blockiert den Start? → „Dennoch öffnen“ in den Systemeinstellungen oder Gatekeeper-Fix</text>
</svg>"""


def guide_install() -> str:
    w, h = 1200, 600
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{defs()}
  <rect width="{w}" height="{h}" rx="0" fill="#FFFFFF"/>
  <g filter="url(#shadow)">
    <rect x="100" y="40" width="1000" height="520" rx="22" fill="url(#soft)" stroke="#D9D3F2"/>
  </g>
  <rect x="100" y="40" width="1000" height="52" rx="22" fill="#EFEBFC"/>
  <rect x="100" y="70" width="1000" height="22" fill="#EFEBFC"/>
  <circle cx="132" cy="66" r="8" fill="#FF5F57"/><circle cx="158" cy="66" r="8" fill="#FEBC2E"/><circle cx="184" cy="66" r="8" fill="#28C840"/>
  <text x="600" y="72" text-anchor="middle" font-family="{FONT}" font-size="17" font-weight="600" fill="#4B4766">Auracaster 0.1.0</text>
  <circle cx="360" cy="290" r="190" fill="url(#glow)"/>
  {rings(360, 290, (110, 160, 210))}
  <image href="{icon_href()}" x="270" y="200" width="180" height="180"/>
  <text x="360" y="420" text-anchor="middle" font-family="{FONT}" font-size="20" font-weight="600" fill="#1F1B3A">Auracaster</text>
  {folder(770, 215, 1.8)}
  <text x="860" y="420" text-anchor="middle" font-family="{FONT}" font-size="20" font-weight="600" fill="#1F1B3A">Programme</text>
  <path d="M480,270 C570,190 660,190 745,270" fill="none" stroke="{VIOLET}" stroke-width="9" stroke-linecap="round" marker-end="url(#head)"/>
  <g transform="translate(560,300)">
    <path d="M0,0 L0,34 L9,26 L15,40 L21,37 L15,24 L27,24 Z" fill="#111" stroke="#fff" stroke-width="2.5" stroke-linejoin="round"/>
  </g>
  <rect x="440" y="470" width="320" height="50" rx="25" fill="{VIOLET}"/>
  <text x="600" y="502" text-anchor="middle" font-family="{FONT}" font-size="19" font-weight="700" fill="#fff">Ziehen &amp; loslassen – fertig</text>
</svg>"""


def guide_gatekeeper() -> str:
    w, h = 1200, 720
    side = ["WLAN", "Bluetooth", "Netzwerk", "Allgemein", "Erscheinungsbild", "Bedienungshilfen", "Datenschutz &amp; Sicherheit", "Schreibtisch &amp; Dock"]
    items = ""
    for i, name in enumerate(side):
        y = 150 + i * 46
        selected = name.startswith("Datenschutz")
        if selected:
            items += f'<rect x="78" y="{y - 26}" width="270" height="38" rx="9" fill="#0A84FF"/>'
        color = "#FFFFFF" if selected else "#2B2A33"
        dot = "#0A84FF" if not selected else "#FFFFFF"
        items += (f'<rect x="92" y="{y - 18}" width="22" height="22" rx="6" fill="{dot}" fill-opacity="{1 if selected else .25}"/>'
                  f'<text x="126" y="{y}" font-family="{FONT}" font-size="16" fill="{color}" font-weight="{600 if selected else 400}">{name}</text>')
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{defs()}
  <rect width="{w}" height="{h}" fill="#FFFFFF"/>
  <g filter="url(#shadow)"><rect x="60" y="30" width="1080" height="660" rx="22" fill="#FBFBFD" stroke="#E2E2EA"/></g>
  <rect x="60" y="30" width="310" height="660" rx="22" fill="#F1F0F6"/>
  <rect x="300" y="30" width="70" height="660" fill="#F1F0F6"/>
  <circle cx="92" cy="60" r="8" fill="#FF5F57"/><circle cx="118" cy="60" r="8" fill="#FEBC2E"/><circle cx="144" cy="60" r="8" fill="#28C840"/>
  <rect x="80" y="86" width="268" height="32" rx="9" fill="#E4E2EC"/>
  <text x="100" y="108" font-family="{FONT}" font-size="15" fill="#8A8896">Suchen</text>
  {items}
  <text x="410" y="78" font-family="{FONT}" font-size="22" font-weight="700" fill="#1D1D24">Datenschutz &amp; Sicherheit</text>
  <text x="410" y="132" font-family="{FONT}" font-size="15" fill="#8A8896">… nach unten scrollen …</text>
  <text x="410" y="190" font-family="{FONT}" font-size="18" font-weight="700" fill="#1D1D24">Sicherheit</text>
  <rect x="400" y="206" width="700" height="250" rx="14" fill="#FFFFFF" stroke="#E6E5EE"/>
  <text x="424" y="244" font-family="{FONT}" font-size="16" fill="#2B2A33">Apps erlauben, die geladen wurden von</text>
  <text x="1076" y="244" text-anchor="end" font-family="{FONT}" font-size="16" fill="#6E6C7A">App Store &amp; bekannte Entwickler ⌄</text>
  <rect x="424" y="262" width="652" height="1" fill="#ECEBF2"/>
  <image href="{icon_href()}" x="424" y="288" width="54" height="54"/>
  <text x="494" y="310" font-family="{FONT}" font-size="16" fill="#2B2A33">„Auracaster“ wurde blockiert, um deinen Mac zu schützen.</text>
  <text x="494" y="334" font-family="{FONT}" font-size="14" fill="#6E6C7A">Apple konnte nicht überprüfen, ob die App Schadsoftware enthält.</text>
  <rect x="874" y="372" width="196" height="42" rx="10" fill="#FFFFFF" stroke="#C9C7D6"/>
  <text x="972" y="399" text-anchor="middle" font-family="{FONT}" font-size="16" font-weight="600" fill="#1D1D24">Dennoch öffnen</text>
  <rect x="864" y="362" width="216" height="62" rx="16" fill="none" stroke="{VIOLET}" stroke-width="4"/>
  <g font-family="{FONT}" font-weight="800" font-size="18" fill="#fff">
    <circle cx="60" cy="0" r="0"/>
    <circle cx="66" cy="{150 + 6 * 46 - 7}" r="17" fill="{VIOLET}"/><text x="66" y="{150 + 6 * 46 - 1}" text-anchor="middle">1</text>
    <circle cx="1100" cy="342" r="17" fill="{VIOLET}"/><text x="1100" y="348" text-anchor="middle">2</text>
  </g>
  <rect x="400" y="490" width="700" height="170" rx="14" fill="#F6F3FF" stroke="#DDD3FB"/>
  <text x="424" y="526" font-family="{FONT}" font-size="17" font-weight="700" fill="{DEEP}">So geht’s (einmalig):</text>
  <text x="424" y="558" font-family="{FONT}" font-size="15.5" fill="#2B2A33">1  Systemeinstellungen → Datenschutz &amp; Sicherheit öffnen und nach unten scrollen</text>
  <text x="424" y="586" font-family="{FONT}" font-size="15.5" fill="#2B2A33">2  Bei „Auracaster wurde blockiert“ auf Dennoch öffnen klicken</text>
  <text x="424" y="614" font-family="{FONT}" font-size="15.5" fill="#2B2A33">3  Mit Passwort / Touch ID bestätigen, im Dialog nochmals Dennoch öffnen</text>
  <text x="424" y="642" font-family="{FONT}" font-size="13.5" fill="#6E6C7A">Alternativ: Gatekeeper-Fix.command im DMG doppelklicken – oder die Terminal-Zeile aus „Zuerst lesen“.</text>
</svg>"""


def guide_flash() -> str:
    w, h = 1400, 560
    def panel(x: int, n: int, title: str, sub: str, body: str) -> str:
        return f"""<g transform="translate({x},40)">
      <rect width="420" height="480" rx="26" fill="url(#soft)" stroke="#DDD6F7"/>
      <circle cx="44" cy="46" r="22" fill="{VIOLET}"/>
      <text x="44" y="54" text-anchor="middle" font-family="{FONT}" font-size="22" font-weight="800" fill="#fff">{n}</text>
      <text x="78" y="54" font-family="{FONT}" font-size="22" font-weight="700" fill="#1F1B3A">{title}</text>
      {body}
      <text x="210" y="440" text-anchor="middle" font-family="{FONT}" font-size="15.5" fill="#4B4766">{sub}</text>
    </g>"""

    board = f"""
      <g transform="translate(115,95)">
        <rect x="0" y="0" width="190" height="290" rx="14" fill="#14532D"/>
        <rect x="62" y="-16" width="66" height="34" rx="8" fill="#B9BCC4" stroke="#8B8F99"/>
        <rect x="52" y="70" width="86" height="86" rx="6" fill="#111827"/>
        <text x="95" y="120" text-anchor="middle" font-family="{FONT}" font-size="13" fill="#9CA3AF">nRF52840</text>
        {''.join(f'<circle cx="16" cy="{40 + i * 22}" r="6" fill="#E5C07B"/><circle cx="174" cy="{40 + i * 22}" r="6" fill="#E5C07B"/>' for i in range(11))}
        <circle cx="174" cy="194" r="11" fill="none" stroke="#F472B6" stroke-width="4"/>
        <circle cx="174" cy="238" r="11" fill="none" stroke="#F472B6" stroke-width="4"/>
        <text x="146" y="199" text-anchor="end" font-family="{FONT}" font-size="13" font-weight="700" fill="#FBCFE8">RST</text>
        <text x="146" y="243" text-anchor="end" font-family="{FONT}" font-size="13" font-weight="700" fill="#FBCFE8">GND</text>
        <path d="M200,200 C235,205 235,230 200,236" fill="none" stroke="#F472B6" stroke-width="4" stroke-linecap="round"/>
        <circle cx="95" cy="250" r="7" fill="#60A5FA"/>
      </g>
      <text x="375" y="335" text-anchor="middle" font-family="{FONT}" font-size="34" font-weight="800" fill="#DB2777">2×</text>"""

    drive = f"""
      <g transform="translate(110,110)">
        <rect x="0" y="40" width="200" height="120" rx="18" fill="#D9DCE3" stroke="#A9AEBA" stroke-width="2"/>
        <rect x="0" y="120" width="200" height="40" rx="0" fill="#C5C9D3"/>
        <rect x="0" y="140" width="200" height="20" rx="18" fill="#C5C9D3"/>
        <circle cx="170" cy="140" r="6" fill="#34D399"/>
        <text x="100" y="205" text-anchor="middle" font-family="{FONT}" font-size="20" font-weight="700" fill="#1F1B3A">NICENANO</text>
        <rect x="18" y="232" width="164" height="54" rx="10" fill="#fff" stroke="#DDD6F7"/>
        <text x="100" y="256" text-anchor="middle" font-family="ui-monospace, Menlo, monospace" font-size="13" fill="#4B4766">INFO_UF2.TXT</text>
        <text x="100" y="276" text-anchor="middle" font-family="ui-monospace, Menlo, monospace" font-size="12" fill="{VIOLET}">SoftDevice: S140 6.1.1</text>
      </g>"""

    copy = f"""
      <g transform="translate(40,110)">
        <rect x="0" y="20" width="120" height="150" rx="12" fill="#fff" stroke="#C4B5FD" stroke-width="3"/>
        <path d="M84,20 L120,56 L84,56 Z" fill="#EDE9FE" stroke="#C4B5FD" stroke-width="3"/>
        <text x="60" y="118" text-anchor="middle" font-family="{FONT}" font-size="24" font-weight="800" fill="{VIOLET}">UF2</text>
        <text x="60" y="200" text-anchor="middle" font-family="ui-monospace, Menlo, monospace" font-size="12" fill="#4B4766">…-s140v6-0x26000.uf2</text>
        <path d="M140,95 C180,60 210,60 236,95" fill="none" stroke="{VIOLET}" stroke-width="7" stroke-linecap="round" marker-end="url(#head)"/>
        <g transform="translate(240,40)">
          <rect x="0" y="40" width="100" height="70" rx="12" fill="#D9DCE3" stroke="#A9AEBA" stroke-width="2"/>
          <circle cx="84" cy="96" r="5" fill="#34D399"/>
          <text x="50" y="140" text-anchor="middle" font-family="{FONT}" font-size="15" font-weight="700" fill="#1F1B3A">NICENANO</text>
        </g>
        <text x="170" y="270" text-anchor="middle" font-family="{FONT}" font-size="17" font-weight="700" fill="#059669">✓ Laufwerk verschwindet = fertig</text>
      </g>"""

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{defs()}
  <rect width="{w}" height="{h}" fill="#FFFFFF"/>
  {panel(30, 1, "Reset 2× schnell", "Taster 2× drücken oder RST 2× kurz an GND", board)}
  {panel(490, 2, "Laufwerk erscheint", "SoftDevice-Zeile bestimmt die Datei", drive)}
  {panel(950, 3, "UF2 draufziehen", "Dongle startet als „Auracaster Dongle“", copy)}
</svg>"""


if __name__ == "__main__":
    render(dmg_background(), ROOT / "macos/Installer/dmg-background.png", 680, 500)
    render(dmg_background(), ROOT / "macos/Installer/dmg-background@2x.png", 680, 500, 2)
    render(guide_install(), ROOT / "docs/images/guide-install.png", 1200, 600)
    render(guide_gatekeeper(), ROOT / "docs/images/guide-gatekeeper.png", 1200, 720)
    render(guide_flash(), ROOT / "docs/images/guide-flash.png", 1400, 560)

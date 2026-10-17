#!/usr/bin/env python3
"""Builds "Zuerst lesen.html" for the DMG: a self-contained, illustrated install and
first-launch guide (images embedded as data URIs, opens in Safari offline).

usage: make_liesmich.py OUT.html VERSION IMAGE_DIR [IMAGE_DIR ...]

For every image name the dirs are searched in order for NAME, window-NAME and app-NAME,
so fresh CI screenshots win over the committed docs/images/ copies.
"""
from __future__ import annotations

import base64
import html
import pathlib
import sys

out, version, *dirs = sys.argv[1:]
search = [pathlib.Path(d) for d in dirs]


def img(name: str, alt: str, width: int = 640) -> str:
    for d in search:
        for candidate in (name, f"window-{name}", f"app-{name}"):
            p = d / candidate
            if p.is_file():
                data = base64.b64encode(p.read_bytes()).decode()
                return (f'<figure><img src="data:image/png;base64,{data}" alt="{html.escape(alt)}" '
                        f'style="max-width:{width}px"><figcaption>{html.escape(alt)}</figcaption></figure>')
    return ""


REPO = "https://github.com/thegroovex/Auracaster"
page = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Auracaster {version} – Zuerst lesen</title>
<style>
:root {{ color-scheme: light dark; --accent:#6d28d9; --card:rgba(127,127,127,.09); }}
body {{ font: 16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
       max-width: 860px; margin: 0 auto; padding: 32px 28px 80px; }}
header {{ display:flex; gap:20px; align-items:center; padding:28px; border-radius:28px; color:#fff;
         background: radial-gradient(circle at 15% 30%, #a78bfa55, transparent 45%), linear-gradient(135deg,#3730a3,#4c1d95 55%,#6d28d9); }}
header h1 {{ margin:0; font-size: 34px; }} header p {{ margin:4px 0 0; opacity:.85 }}
.halo {{ width:84px; height:84px; border-radius:22px; flex:none; background:
        radial-gradient(circle, #fff 0 14%, transparent 15% 26%, #ffffffcc 27% 30%, transparent 31% 44%, #ffffff88 45% 48%, transparent 49% 62%, #ffffff55 63% 66%, transparent 67%),
        linear-gradient(135deg,#3730a3,#6d28d9); box-shadow: 0 8px 30px #6d28d966; }}
h2 {{ margin-top: 44px; font-size: 24px; }}
.step {{ display:flex; gap:14px; align-items:flex-start; background:var(--card); border-radius:18px; padding:16px 18px; margin:12px 0; }}
.num {{ flex:none; width:30px; height:30px; border-radius:50%; background:var(--accent); color:#fff; font-weight:700;
       display:flex; align-items:center; justify-content:center; }}
.note {{ border-left: 4px solid #f59e0b; background: #f59e0b18; padding: 12px 16px; border-radius: 10px; }}
code, kbd {{ font: 14px ui-monospace, "SF Mono", Menlo, monospace; background: var(--card); padding: 2px 6px; border-radius: 6px; }}
pre {{ background: #1e1b4b; color: #ede9fe; padding: 14px 16px; border-radius: 12px; overflow-x: auto; }}
figure {{ margin: 16px 0; text-align:center; }} figure img {{ width:100%; border-radius: 14px; box-shadow: 0 6px 30px #0003; }}
figcaption {{ font-size: 13px; opacity: .65; margin-top: 6px; }}
a {{ color: var(--accent); }}
</style></head><body>
<header><div class="halo"></div><div><h1>Auracaster {html.escape(version)}</h1>
<p>Mac-Audio als Auracast™ an beliebig viele Hörgeräte, Kopfhörer und Lautsprecher.</p></div></header>

<h2>1 · Installieren</h2>
<div class="step"><div class="num">1</div><div>Im DMG-Fenster das <b>Auracaster-Symbol</b> auf den Ordner <b>Programme</b> ziehen.</div></div>
{img("guide-install.png", "App auf „Programme“ ziehen")}
<div class="step"><div class="num">2</div><div>Auracaster aus dem Ordner <b>Programme</b> (oder per Spotlight <kbd>⌘ Leertaste</kbd> → „Auracaster“) starten.</div></div>

<h2>2 · Wenn macOS den Start blockiert</h2>
<p>Auracaster ist ein kostenloses Open-Source-Projekt und (noch) nicht bei Apple notarisiert. macOS zeigt deshalb beim
ersten Start <i>„Auracaster“ kann nicht geöffnet werden</i> oder <i>Apple konnte nicht überprüfen …</i>. Das ist normal. Drei Wege – einer reicht:</p>
<div class="step"><div class="num">A</div><div><b>Systemeinstellungen</b> (empfohlen, ab macOS 15 der offizielle Weg):<br>
Meldung mit <b>Fertig</b> schließen → <b>Systemeinstellungen → Datenschutz &amp; Sicherheit</b> → ganz nach unten scrollen →
bei <i>„Auracaster“ wurde blockiert …</i> auf <b>Dennoch öffnen</b> klicken → mit Passwort/Touch ID bestätigen → im nächsten Dialog nochmals <b>Dennoch öffnen</b>.
Das ist nur einmal nötig. (Der frühere Trick „Rechtsklick → Öffnen“ funktioniert seit macOS 15 nicht mehr.)</div></div>
{img("guide-gatekeeper.png", "Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen")}
<div class="step"><div class="num">B</div><div><b>Gatekeeper-Fix.command</b> aus dem DMG doppelklicken. Es entfernt die Quarantäne-Markierung und startet die App.
Weil auch dieses Skript aus dem Internet kommt, kann macOS es beim ersten Mal ebenfalls blockieren – dann wie bei A über
<b>Dennoch öffnen</b> freigeben.</div></div>
<div class="step"><div class="num">C</div><div><b>Terminal</b> (Programme → Dienstprogramme → Terminal), diese Zeile einfügen, <kbd>⏎</kbd>:
<pre>xattr -dr com.apple.quarantine /Applications/Auracaster.app &amp;&amp; open /Applications/Auracaster.app</pre></div></div>
<p class="note">Updates installiert Auracaster später selbst (<b>Auracaster → Nach Updates suchen …</b>). Dabei gibt es keine Gatekeeper-Meldung mehr.</p>

<h2>3 · Erster Start</h2>
<p>Ein Assistent führt durch vier Schritte: Was ist Auracaster → Dongle einstecken → Engine &amp; Audio-Freigabe → erster Stream.</p>
{img("onboarding-light.png", "Willkommens-Assistent")}
<div class="step"><div class="num">1</div><div><b>Engine einrichten</b> klicken: lädt Python, Google Bumble und den LC3-Codec (ca. 1–2 Minuten, Internet nötig, kein Xcode/Homebrew). Danach <b>Neu starten</b>.</div></div>
<div class="step"><div class="num">2</div><div>Beim ersten <b>Senden</b> fragt macOS nach <b>Systemaudio-Aufnahme</b> → <b>Erlauben</b>. Für Mikrofone/Audio-Interfaces kommt eine eigene Abfrage.</div></div>

<h2>4 · Dongle flashen (einmalig)</h2>
<p>Der Mac kann Auracast nicht selbst senden. Ein <b>Pro Micro nRF52840</b> (nice!nano-Klon, ca. 5 €) übernimmt den Funk. Die Firmware liegt im Release
(<code>auracaster-dongle-*.uf2</code>).</p>
{img("guide-flash.png", "Dongle flashen: 2× Reset → Laufwerk → UF2 draufziehen")}
<div class="step"><div class="num">1</div><div>Dongle per USB-C anstecken, <b>zweimal schnell</b> Reset drücken (bzw. RST zweimal kurz mit GND verbinden). Die LED pulsiert, ein Laufwerk (z. B. <b>NICENANO</b>) erscheint.</div></div>
<div class="step"><div class="num">2</div><div><code>INFO_UF2.TXT</code> auf dem Laufwerk öffnen, Zeile <code>SoftDevice:</code> lesen:<br>
<code>S140 version 6.x</code> → <code>auracaster-dongle-s140v6-0x26000.uf2</code> (häufigster Fall)<br>
<code>S140 version 7.x</code> → <code>auracaster-dongle-s140v7-0x27000.uf2</code><br>
<code>not found</code> → <code>auracaster-dongle-nosd-0x1000.uf2</code></div></div>
<div class="step"><div class="num">3</div><div>Die Datei auf das Laufwerk ziehen. Es verschwindet von selbst (macOS meldet evtl. „nicht korrekt ausgeworfen“ – harmlos). Fertig: Auracaster zeigt <b>Auracaster Dongle erkannt</b>.</div></div>

<h2>5 · Senden</h2>
{img("studio-light.png", "Studio: Latenz, Preset, Pegel, QR-Code")}
<div class="step"><div class="num">1</div><div>Links eine <b>Quelle</b> wählen (Systemaudio, eine App oder ein Eingang).</div></div>
<div class="step"><div class="num">2</div><div>Oben rechts <b>Senden</b> → der Knopf wird rot: <b>On Air</b>.</div></div>
<div class="step"><div class="num">3</div><div>Empfänger koppeln: am Smartphone/in der Hörgeräte-App unter <i>Auracast</i> den Sender wählen oder den <b>QR-Code</b> scannen.</div></div>
{img("menubar-light.png", "Steuerung in der Menüleiste", 360)}

<h2>Hilfe</h2>
<p>Ausführliche Anleitung, FAQ und Fehlerbehebung: <a href="{REPO}#readme">{REPO}</a> · Probleme melden: <a href="{REPO}/issues">Issues</a></p>
<p style="opacity:.6;font-size:13px">Auracaster basiert auf Google Bumble (Apache-2.0). Auracast™ ist eine Marke der Bluetooth SIG.</p>
</body></html>
"""
pathlib.Path(out).write_text(page, encoding="utf-8")
print(f"wrote {out} ({len(page) // 1024} KiB)")

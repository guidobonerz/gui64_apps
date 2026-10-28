# RainRadar: Kartenansicht – Plan

Stand: 2026-10-27. Ergebnis der Machbarkeitsprüfung, Empfehlung in zwei Stufen.

## Ziel

Zusätzlich zur Niederschlagskurve (nächste 2 Stunden) kann man optional eine
Karte der Regenwolken-Struktur um den eigenen Ort anzeigen. Umschalten über
das Menü „Radar“ (Kurve / Karte).

## Ergebnis der Machbarkeitsprüfung

### Datenquellen (alle über reines HTTP erreichbar, getestet am 2026-10-27)

| Quelle | Format / Größe | Auf dem C64 nutzbar? |
|---|---|---|
| DWD Radar-Komposit (opendata.dwd.de) | 4 MB Tar mit HDF5 | nein, viel zu groß |
| RainViewer-Kachel (echtes Radar) | PNG 256x256, ca. 36 KB | nein, Entpacken braucht ein 32-KB-Fenster, die App hat ca. 8 KB (`$B000`-`$CFFF`) |
| Open-Meteo, viele Koordinaten pro Anfrage | CSV | ja |

Open-Meteo rund um Erkelenz, gemessen:

- 12x10 Punkte (ca. 84x70 km, Abstand ca. 7 km), aktueller Wert: Anfrage
  1,4 KB, Antwort 7 KB, 0,2 s.
- 12x10 Punkte mit 9 Zeitschritten (2 h): Antwort 31 KB.
- 24x20 Punkte: erste Abfrage ok (28 KB), danach HTTP 429.

### Haken

1. **Kontingent:** Open-Meteo zählt jeden Punkt als eigenen Aufruf (frei:
   ca. 600 pro Minute, 10 000 pro Tag). Eine 12x10-Karte kostet 120 Aufrufe.
   Automatisch alle 5 Minuten wären das 34 000 am Tag, zu viel.
   Konsequenz: Laden nur auf Knopfdruck, automatisch höchstens alle 30
   Minuten.
2. **Modelldaten, keine Messung:** ICON-D2 (ca. 2 km Raster, 15 Minuten).
   Die Struktur der Regengebiete ist erkennbar, aber geglättet.

### Darstellung

**Multicolor-Sprites: nicht empfehlenswert.**

- Laut Projektregel nur die Sprites 6 und 7 (WIN zeichnet 2-5 für die
  Taskleiste). Das ergibt höchstens 24x21 Pixel und 3 Farben.
- Sprites liegen über Menüs, Dialogen und anderen Fenstern. Dafür wäre ein
  Frame-Handler nötig, der dem Fenster folgt (wie Roaches/RunBoyRun).
- Multiplexing reicht zeitlich nicht (IRQ-Budget).

**Eigene Zeichen + Farbspeicher: empfohlen.**

- Eigenes Control wie `CT_RR_GRAPH`, gezeichnet in `PaintCtrls` über
  Paint- und Farbpuffer. Kein Interrupt-Code, läuft auf MAC und WIN, hält
  sich an die Regel „nur gui64.inc.asm-API“.

## Stufe 1: Karte aus Open-Meteo (empfohlen)

### Funktion

- Menü „Radar“: neue Einträge „Karte“ / „Kurve“ (Umschalten) und
  „Karte laden“.
- Raster 12x10 Punkte um den gefundenen Ort (Lat/Lon aus dem Geocoding),
  Abstand Längengrad 0,10 Grad, Breitengrad 0,065 Grad (ca. 7 km).
- Farbe pro Punkt nach Stärke: trocken (dunkel), leicht (hellblau),
  mittel (blau), stark (gelb), sehr stark (rot). Zwischenstufen über
  Rasterzeichen.
- Ort als Kreuz in der Rastermitte.
- Optional Animation: die 9 Zeitschritte (jetzt bis +2 h) per Timer
  abspielen, Zeit im Label anzeigen.

### Technik

- **Anfrage:** `GET /v1/forecast?latitude=a,b,c,...&longitude=a,b,c,...
  &minutely_15=precipitation&forecast_minutely_15=9&format=csv`.
  Die Anfrage ist ca. 1,4 KB lang, also mehrere Write-Befehle in
  `HttpGet` (aktuell passt sie in einen Block bis 255 Bytes).
- **Antwort streamen:** Die 31 KB werden beim Empfang ausgewertet, ohne sie
  komplett zu puffern. Erst der Kopfblock `location_id,latitude,...`
  (120 Zeilen) überspringen, dann pro Zeile `id,zeit,wert`.
  `UciResult` bekommt dafür einen Zeilen-Callback statt Ablage in `RxBuf`.
- **Datenhaltung:** 12x10 Punkte x 9 Schritte x 1 Byte (Wert in 1/100 mm,
  auf 0-255 begrenzt) = 1 080 Bytes. Fester Puffer in der App.
- **Zeichen:** Die Kurve belegt 10 der 16 App-Zeichen. Für die Karte werden
  per `GUI_RegisterChars` beim Umschalten andere Zeichen geladen
  (Rasterstufen), Zurückschalten lädt die Kurvenzeichen wieder.
- **Control:** `CT_RR_MAP` (Typ 51) neben `CT_RR_GRAPH`, je nach Ansicht
  ein- oder ausgeblendet (Control-Bits) oder getrennte Fensterzustände.
  Fenstergröße ggf. anpassen (12 Zellen breit, 10 hoch; mit 2x2-Zeichen pro
  Punkt 24x20).
- **Kontingent:** Zähler „letzter Kartenabruf“ in der App, Neuladen nur auf
  Knopfdruck. Automatischer Refresh frühestens alle 30 Minuten.
  Bei HTTP 429 klare Meldung („Zu viele Abrufe, spaeter“).
- **Speicher:** Code ca. +1 bis 1,5 KB, Puffer +1 KB. Bleibt unter `$D000`
  (aktuell `BuffersEnd` = `$CA01`).

### Test

- VICE: Attrappe für `HttpGet`/`UciResult` mit gespeicherter CSV-Antwort
  (31 KB, vorher per Skript erzeugt), prüft Auswertung, Raster und
  Screenshot. Wie beim bestehenden `test_rr.py`.
- Echte Hardware: nur auf dem Ultimate prüfbar (das Netzwerk des
  Command Interface wird von VICE nicht emuliert).

### Voraussetzung

Vor Stufe 1 klären, ob die Kurve auf dem Ultimate 64 schon Daten holt
(Annahmen zu Netzwerk-Target 3, Lesen mit Längenbytes, Status „00“). Sonst
baut die Karte auf unbestätigtem Netzwerkcode auf.

## Stufe 2 (optional): Echtes Radar über Proxy

- Kleines Python-Skript auf NAS/Raspberry Pi: holt RainViewer-Kachel oder
  DWD-Daten, verkleinert auf z. B. 48x40 Werte und liefert ca. 2 KB Rohdaten
  über HTTP.
- Vorteile: echte Messung im 5-Minuten-Raster, kein Open-Meteo-Kontingent,
  einfachere C64-Seite.
- Nachteile: ein Dienst muss dauerhaft laufen; Nutzungsbedingungen von
  RainViewer vorher prüfen (DWD-Daten sind offen).

## Offene Entscheidungen

1. Raster 12x10 mit einer Zelle pro Punkt oder 24x20 Zeichen (2x2 pro Punkt)?
2. Animation über 2 Stunden in Stufe 1 gleich mitbauen?
3. Soll Stufe 2 (Proxy) überhaupt verfolgt werden?

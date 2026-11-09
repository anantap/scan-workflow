# scan-inbox: negatieven vanzelf omzetten

> **Niet meer nodig:** de Mac-app Roll Converter (`mac/`) doet dit nu: sleep de rolmap erop en klik op Convert.
> Staat scan-inbox nog aan, zet het dan uit met `automation/install.sh --verwijder`, anders wordt elke rol twee keer omgezet.

VueScan scant, de Mac zet om. Elke nieuwe scan in de inbox-map wordt vanzelf een positief,
met dezelfde omzetting als de Negatief Converter:

```
~/Scans/Inbox/
├── scan0001.dng          ← VueScan bewaart hier (raw DNG)
├── scan0002.dng
└── Positief/
    ├── scan0001.tif      16-bit, om te bewerken
    ├── scan0001.jpg      om te bekijken en te delen
    └── …
```

- Een scan wordt pas gelezen als VueScan klaar is met schrijven.
- Komt er een kwartier niets bij, dan is de rol klaar: alle frames van die rol worden dan
  opnieuw omgezet met één kleurbalans, zodat ze bij elkaar passen. Je krijgt een melding.
- Een scan opnieuw laten omzetten? Gooi zijn TIFF in `Positief/` weg.

## Een map per rol

Maak je per rol een eigen map in de inbox (en zet VueScan per rol op die map), dan is elke map
een rol: met een eigen `Positief`, een eigen kleurbalans, en zonder naamconflicten tussen rollen.
Komen er later scans bij in een rol, dan wordt die rol opnieuw in balans gebracht.

```
~/Scans/Inbox/
├── 2026-11 Portra 400 rol 12/
│   ├── scan0001.dng
│   └── Positief/
└── 2026-11 HP5 rol 13 (zw)/      ← "(zw)" in de naam: zwart-wit
```

Haakjes in de mapnaam die beginnen met `zw` of `positief` zeggen wat voor film het is, de rest is
vrije tekst: `(zw)`, `(zw-scanned)`, `(zw, bewerkt)`, `(positief lab)`. Zulke rollen worden TIFF en
JPEG, ook met `--burke`.

## Aanzetten

Eenmalig `brew install node`, dan:

```
~/scan-workflow/automation/install.sh
```

Liever in Compositor bijstellen, met Alex Burke's lagen? `install.sh ~/Scans/Inbox --burke`: dan komt er per scan
een `.comp` in `Positief/` in plaats van TIFF en JPEG (zie `compositor/README.md`).

Andere map of opties: `install.sh ~/Scans/Inbox --zw` (zwart-wit), `--positief` (al positieve scans),
`--geen-jpg`, `--geen-rol`, `--rust 20` (minuten tot een rol klaar heet, standaard 15).

Uitzetten: `install.sh --verwijder`. Logboek: `~/Library/Logs/scan-inbox.log`.

Kies de inbox buiten Bureaublad, Documenten en Downloads: macOS laat een achtergrondtaak daar niet
zonder toestemming in.

## Met de hand

```
node automation/scan-inbox.mjs ~/Scans/Inbox
```

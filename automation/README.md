# scan-inbox: negatieven vanzelf omzetten

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

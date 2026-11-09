# Negatieven omzetten naar Compositor

`neg2comp.mjs` maakt van elke scan een [Compositor](https://github.com/robbietilton/Compositor)-project
(`.comp`), met dezelfde omzetting als de Negatief Converter. In elk project:

| Laag | Wat |
|---|---|
| Kleurbalans, Curven, Niveaus | Aanpassingslagen op nulstand: hier stel je bij |
| **Positief** | Het omgezette beeld, 16-bit |
| Negatief (origineel) | Alleen met `--met-negatief`; verborgen |

## Eenmalig

```
brew install node
```

Een recente Compositor: de projecten gebruiken 16-bit lagen (projectformaat 12). De huidige versie (1.6.6) kan dat.

## Alex Burke's methode: `burke2comp.mjs`

Zijn [handmatige inversie](https://www.alexburkephoto.com/blog/2019/10/16/manual-inversion-of-color-negative-film),
als Compositor-project met al zijn lagen, ingesteld op de scan en allemaal bij te stellen:

| Laag | Wat |
|---|---|
| Contrast | Curven: zachte S-curve |
| Hue/Saturation | neutraal; cyaan naar blauw als de lucht te cyaan is |
| Witpunt & kleur | Curven: witpunt per kanaal net voor het clippen, zwartpunt, blauw en groen omlaag in schaduw en midden, RGB omlaag |
| Filmbasis | de kleur van de filmrand, **Subtract** op 80% |
| Inversie | Curven: zwart en wit omgedraaid |
| Scan | de scan zoals hij is, 16-bit |

```
node compositor/burke2comp.mjs --rol ~/Pictures/Scans/rol-12
```

Opties: `--rol` (één witpunt en kleurbalans voor de hele rol), `--basis 80` (dekking van de filmbasis),
`--neutraal 75` (lager houdt meer sfeer bij schemer en zonsondergang; Burke trekt groen dan minder ver),
`--vervang`, `--uit <map>`. Zet de scan zó in de houder dat er wat filmrand in beeld is.

Bij schemer of zonsondergang: open **Witpunt & kleur** en trek in het groene kanaal het witpunt minder ver,
zoals Burke beschrijft.

## Makkelijkst: de sleep-app

Eenmalig, in Terminal:

```
~/scan-workflow/compositor/install-droplet.sh
```

Dat maakt **Negatieven naar Compositor** in je Programma's-map (in je thuismap). Zet hem in je Dock.
Sleep daarna een map met DNG's op het icoon, kies het soort scans, en de `.comp`-bestanden
verschijnen naast de scans. Makkelijker: de Mac-app Roll Converter (`mac/`) maakt dezelfde `.comp`-bestanden voor een hele rol.

## Vanuit Terminal

Vanuit de map van deze repo, met de raw DNG's van VueScan:

```
node compositor/neg2comp.mjs --rol ~/Pictures/Scans/2026-11-rol-12
```

Elke scan krijgt een `naam.comp` ernaast. Open die in Compositor.

| Optie | |
|---|---|
| `--rol` | Eén kleurbalans voor de hele rol, zodat de frames bij elkaar passen |
| `--positief` | De scans zijn al positief (bijvoorbeeld van een lab): niet omkeren |
| `--zw` | Zwart-wit |
| `--rand 8` | Procent rand dat de analyse negeert (houder en filmrand) |
| `--belichting 0` | -100 tot 100 |
| `--contrast 30` | 0 tot 100 |
| `--met-negatief` | Het negatief als verborgen laag erbij (project wordt twee keer zo groot) |
| `--uit <map>` | Projecten in een andere map |

Een bestaand project wordt niet overschreven: er komt dan `naam 2.comp`.

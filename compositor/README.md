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

## Gebruik

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

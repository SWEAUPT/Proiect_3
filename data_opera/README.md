# Compozitul radar european OPERA, decupat pe Timișoara

Set de date **separat** de arhiva TIM din `data/`. Este produs de
`opera_fetch_timisoara.m` din compozitul radar EUMETNET OPERA (arhivă deschisă,
`https://s3.waw3-1.cloudferro.com/openradar-archive/`).

## De ce există

Arhiva TIM de la ANM are o fereastră rulantă de ~3,5 zile și goluri permanente
(cele mai mari: 26–28 aug, 31 aug–5 sep, 4–17 oct și 20–28 oct 2026). OPERA
păstrează istoria, deci aici se află și zilele lipsă din `data/`, plus lunile ianuarie–august 2026 (iarnă,
primăvară, furtuni de vară) pe care arhiva TIM nu le-a avut niciodată.

## Nu este același produs ca `data/`

| | `data/` (TIM, ANM) | `data_opera/` (OPERA) |
|---|---|---|
| Sursă | un singur radar, Timișoara | compozit din mai multe radare europene |
| Geometrie | polar, 920 × 360, elevația 0,5° | cartezian LAEA, 1 km |
| Control de calitate | fără (clutter prezent) | da (clutter eliminat) |
| Exemplu: 2026-09-12 12:00, 160 km în jur | ecou 9 %, max 59,5 dBZ | ecou 6 %, max 44 dBZ |

**Nu amestecați cadrele cu cele din `data/`.** Este un set coerent cu sine:
format verificat identic lună de lună din iulie 2024 până în octombrie 2026
(ODIM 2.4, grilă 3800 × 4400 la 1 km, aceeași proiecție și calibrare, 288 de
cadre DBZH pe zi).

## Format

Un fișier pe zi, `OPERA_TIM_<yyyyMMdd>.mat` (~13 MB):

| Variabilă | Ce este |
|---|---|
| `q` | `uint8 [600 × 600 × 288]`: 0 = fără ecou, 255 = fără date / cadru lipsă, altfel **dBZ = q · 0,5 − 32**. Rândul 1 = nord, coloana 1 = vest. |
| `timestamps` | `datetime [288 × 1]`, UTC, din 5 în 5 minute |
| `present` | `logical [288 × 1]`; `false` = cadrul lipsește |
| `georef` | proiecția, poziția decupajului în grila OPERA, coordonatele LAEA ale celulelor, centrul (radarul TIM, 45,7717 N 21,2577 E) |

Decupajul are 600 × 600 km, centrat pe Timișoara: discul de 230 km al radarului
TIM plus o margine pentru ploaia care urmează să intre în domeniu.

## Stare (2026-10-31)

Complet: 303 zile, 2026-01-01 → 2026-10-30, ~4,3 GB. Verificat: structură,
marcaje de timp, georeferință identică, concordanță cu logul și 12 cadre
aleatoare identice bit cu bit cu serverul.

- **273 de cadre lipsă** din 87 264 (0,3 %), în 31 de zile. Niciunul nu există pe
  server (verificat prin listarea S3, respectiv cerere HTTP), deci nu se pot
  descărca. Goluri mari: 6 mar (39), 29 apr (74), 7 mai (19), 7 aug (102);
  restul sunt cadre izolate.
  Vectorul `present` le marchează. Produsul RATE (din 15 în 15 min) există doar
  la 51 din aceste momente; nu s-a folosit, ar fi o reconstrucție.
- **6 cadre prezente, dar complet nodata**: 2026-07-08 16:55–17:20. Tratați-le
  ca lipsă (`all(q(:,:,k)==255)`).
- **Valori nerealiste**: OPERA însăși plafonează la 95 dBZ (verificat în datele
  brute). 0,0055 % din pixelii cu ecou au ≥ 65 dBZ, concentrați în puncte fixe
  de clutter (ex. 5 km E / 4 km N și 18 km N de radarul TIM, ≥ 65 dBZ în ~8 % din
  cadre) și benzi de interferență. `opera_feature_table.m` le tratează: hartă de
  clutter pe frecvență (≥ 65 dBZ în > 0,1 % din cadre → 36 de pixeli excluși)
  și cadre cu < 90 % date valide excluse. Fișierele brute rămân nemodificate.

## Cum se folosește în proiect

`opera_feature_table.m` calculează din aceste fișiere aceleași statistici pe
cadru ca pentru TIM (cache în `opera_feature_cache.mat`, regenerabil).
`opera_training_rows.m` adaugă eșantioanele rezultate **doar la train-ul Random
Forest-ului, la variantele A și C**, și doar pe cele anterioare segmentului de
validare TIM. La B nu se folosește (OPERA măsoară ~1,6× mai multă ploaie decât
TIM). Rezultatele comparației sunt în `README.md` din rădăcina proiectului.

## Completare / reluare

```matlab
opera_fetch_timisoara('Start', datetime(2026,10,31), 'Workers', 4)   % de la prima zi lipsă până ieri
```

Pe un PC cu ~16 GB RAM folosiți **cel mult 4 procese**: cu valoarea implicită
(24) și cu 8, descărcarea a fost oprită de sistem din lipsă de memorie.

Zilele existente se sar; o oprire pierde cel mult ziua în lucru. Fiecare zi
adaugă o linie în `fetch_log.txt` (cadre prezente / lipsă, durata).

Se citește doar decupajul, direct de pe server: verificat identic bit cu bit
cu decupajul fișierului complet. Cu 4 procese durează ~1–2 minute pe zi,
limitat de rețea. Nu rulați fără `'Start'`: implicit pornește de la 2024-07-01.

## Licență

Date EUMETNET OPERA. Seturile derivate publicate le citează sub CC BY 4.0;
confirmați condițiile la `info@eumetnet.eu` înainte de orice redistribuire.

# Arhiva locală de date radar

## Cum o obțineți

1. Descărcați arhiva de pe Drive-ul indicat de profesor.
2. Copiați **toate fișierele `TIM_*.hdf`** direct în acest folder (`data/`), nu într-un subfolder.
3. Completați-o cu cadrele apărute între timp:
   ```matlab
   w1_sync_archive()      % descarcă doar cadrele care lipsesc, nu suprascrie nimic
   ```

Dacă pe Drive se află și `feature_cache.mat` sau `cart_grid_cache.mat`, **nu le copiați**: se regenerează automat din fișierele `.hdf`, iar `feature_cache.mat` trebuie construit cu **propriul** vostru `w2_clean_and_stats`.

## Nu ștergeți nimic de aici

Serverul MeteoRomania (`https://opendata.meteoromania.ro/radar/TIM/`) păstrează
doar o **fereastră rulantă de aproximativ 3,5 zile**. Cadrele care ies din
fereastră **nu mai pot fi descărcate din nicio sursă publică**.

Rulați sincronizarea la **2–3 zile**, cât durează proiectul:

```
w1_sync_archive()      % din MATLAB
auto_sync              % din MATLAB, cu jurnal în sync_log.txt
auto_sync.cmd          % dublu-clic, fără să deschideți MATLAB
```

Fiecare rulare `auto_sync` adaugă o linie în `sync_log.txt` din rădăcina proiectului:

```
2026-09-10 15:17:06  OK   descarcate=621  existau=139  esuate=0  total=3318  ultimul=...
```

Verdictul `ATENTIE-GOL-PERMANENT` înseamnă că sincronizarea **nu a găsit nicio
suprapunere** cu serverul, deci o bucată de serie s-a pierdut definitiv.

Descărcarea scrie întâi într-un fișier `.part` și îl redenumește doar la succes,
deci o întrerupere nu poate corupe un fișier existent.

## Conținut

| Fișier | Ce este |
|---|---|
| `TIM_<YYYYMMDDHHMM>0200dBZ.hdf` | cadru radar ODIM HDF5, 570 KB – 1,2 MB (tipic ~770 KB), la fiecare 5 minute |
| `feature_cache.mat` | statistici pe cadru, regenerabile; **ștergeți-l după orice modificare în `w2_clean_and_stats`** |
| `cart_grid_cache.mat` | grile carteziene de 2 km pentru `radar_motion_table`, ~0,5 GB, regenerabile |

Modelele antrenate **nu** se salvează aici, ci în `models/`.

## Două produse sub același tipar de nume

| Produs | `/what/object` | Geometrie | Dimensiune |
|---|---|---|---|
| Volum polar | `PVOL` | 12 elevații, 0,5° … 19,5° | `920 × 360` |
| PCAPPI 500 m | `IMAGE` | cartezian, proiecție AEQD | `700 × 700` |

Calibrarea se află în locuri diferite (`/dataset1/data1/what` pentru PVOL,
`/dataset1/what` pentru IMAGE). `radar_read_frame.m` le tratează pe amândouă.

Implicit se antrenează doar pe `PVOL`, pentru că statisticile celor două produse
diferă sistematic (mediana intensității pe suprafață: 0,0344 mm/h pe PVOL față
de 0,0165 mm/h pe IMAGE).

## Goluri cunoscute în arhivă

Sincronizările ratate au lăsat goluri permanente (măsurate pe arhivă, peste 1 oră):

| De la | Până la | Durată |
|---|---|---|
| 2026-08-26 06:00 | 2026-08-28 20:55 | 62,9 h |
| 2026-08-31 08:50 | 2026-09-05 20:55 | 132,1 h |
| 2026-09-11 16:40 | 2026-09-11 18:50 | 2,2 h |
| 2026-09-16 14:10 | 2026-09-16 20:55 | 6,8 h |
| 2026-09-20 19:05 | 2026-09-21 10:40 | 15,6 h |
| 2026-09-21 12:10 | 2026-09-21 20:55 | 8,8 h |
| 2026-09-27 14:30 | 2026-09-27 20:55 | 6,4 h |
| 2026-09-28 12:00 | 2026-09-28 16:40 | 4,7 h |
| 2026-10-04 08:10 | 2026-10-17 20:55 | 324,8 h |
| 2026-10-20 17:40 | 2026-10-28 21:55 | 196,2 h |

Orele sunt UTC: ultimul cadru dinaintea golului și primul de după el. Țineți
cont de goluri în raport; intervalul calendaristic al arhivei supraestimează
acoperirea reală.

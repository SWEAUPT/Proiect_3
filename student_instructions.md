# Ghid pentru Student: TIM Radar Lab (7 Săptămâni)

Proiectul folosește date radar meteorologice reale (ODIM HDF5) de pe serverul MeteoRomania (ANM), stația Timișoara (`TIM`).

---

## 0. Citește asta înainte de orice

Serverul ANM păstrează doar ultimele ~3,5 zile. Ce iese din ea nu se mai poate descărca. Folderul `data/` este singura copie a arhivei tale.

- **Nu șterge fișiere `.hdf` din `data/`.**
- Rulează `w1_sync_archive()` la 2–3 zile ca să nu rămâi cu goluri.
- Sincronizarea se pornește manual (`auto_sync.cmd` sau `auto_sync` în MATLAB).
  Verifică `sync_log.txt`: dacă apare cuvântul `ATENTIE-GOL-PERMANENT`, s-a
  pierdut definitiv o bucată din serie.
- Arhiva inițială o descarci de pe Drive-ul indicat de profesor (vezi `START_AICI.md`).

---

## 1. Cum rulez proiectul?

```matlab
main
```

| Săpt. | Funcție | Ce face |
|-------|---------|---------|
| 1 | `w1_sync_archive()` / `w1_download_radar(N)` | Sincronizează arhiva / aduce N cadre |
| 2 | `w2_clean_and_stats(frame)` | Curăță semnalul, calculează statistici fizice ponderate cu aria |
| 3 | `w3_extract_features(variantă, ...)` | Construiește setul de date de prognoză (t → t+30 min) |
| 4 | `w4_train_random_forest(X, y, nume, ...)` | Antrenează Random Forest |
| 5 | `w5_train_lstm(secvențe, y, ...)` | Antrenează LSTM pe secvențe temporale |
| 6 | `w6_evaluate_models(rf, lstm, X, y, taskInfo)` | Evaluează pe segmentul de test |
| 7 | `w7_main_dashboard(frame, stats, ...)` | Afișează dashboard-ul cu 4 panouri |

Varianta se schimbă editând `PROJECT_VARIANT` la începutul lui `main.m`.

Funcțiile săptămânilor 2–7 au porțiuni marcate `todo(...)` pe care le scrii tu. `main` se oprește la primul TODO rămas. Lista completă este în `START_AICI.md`.

---

## 2. Cum verific dacă e corect?

```matlab
run_all_tests           % toate testele
run_all_tests('Week', 3)  % doar săptămâna 3
```

Pe lângă formatul ieșirilor, testele verifică și metodologia: ținta e în viitor, nu poate fi reconstruită liniar din trăsături, segmentele train/val/test sunt disjuncte, ordonate cronologic și separate de un embargo, iar secvențele LSTM au mai mult de un pas de timp.

Unele teste sunt sărite automat dacă lipsesc datele locale. Asta e normal și nu înseamnă eșec.

---

## 3. Cum se citește rezultatul din Săptămâna 6

Tabelul conține întotdeauna două referințe pe lângă modele:

- **Persistență**: „vremea rămâne exact cum e acum”. La 30 de minute e surprinzător de bună.
- **Climatologie / clasa majoritară**: media, respectiv clasa cea mai frecventă din setul de antrenament.

Pentru regresie, coloana `SkillVsPersistenta` este cea care contează:

| Valoare | Interpretare |
|---|---|
| `> 0` | modelul bate persistența, deci aduce ceva în plus |
| `≈ 0` | modelul e la fel de bun ca „nu se schimbă nimic” |
| `< 0` | modelul e mai slab decât să nu faci nimic |

Un $R^2$ de 0,85 poate părea excelent și totuși să fie mai slab decât persistența. Raportează întotdeauna ambele.

---

## 4. Raportul

Completează manual `student_project_report.md`:

- rezultatele tale (statistici, tabelul din Săptămâna 6, grafice),
- interpretarea lor, **inclusiv comparația cu persistența**,
- limitările setului de date (vezi secțiunea 5),
- concluzii personale.

Raportul nu se generează automat.

---

## 5. Limitări pe care trebuie să le menționezi în raport

Fiecare dintre ele influențează rezultatele, așa că discută-le:

1. **Arhiva e scurtă și are goluri.** Câteva săptămâni, nu un an, și nu o serie continuă: sincronizările ratate au lăsat pauze de mai multe zile care nu se mai pot recupera (lista e în `data/README.md`). Verifică câte zile de date ai efectiv, nu doar prima și ultima dată. Sezonalitatea și ciclul diurn nu se pot învăța; de aceea trăsăturile diurne se dezactivează automat sub 14 zile de acoperire reală (suma intervalelor cu date, nu intervalul calendaristic; mesajul `[w3] Trasaturi diurne excluse` îți arată ambele numere).
2. **Segmentele sunt contigue în timp.** Un segment scurt poate conține un singur regim meteo, iar acuratețea pe el devine puțin informativă. Codul avertizează când se întâmplă.
3. **Elevația de 0,5° conține clutter.** Mediana maximului de reflectivitate pe arhivă depășește 75 dBZ, ceea ce e imposibil meteorologic. De aceea `maximum` **nu** e folosit ca trăsătură, iar relația Z–R e plafonată la 53 dBZ.
4. **Ținta e o mărime pe suprafață**, mediată peste tot domeniul radar, nu precipitația într-un punct anume.
5. **OPERA este alt produs.** La variantele A și C, Random Forest-ul învață și din compozitul european OPERA (`data_opera/`, ~10 luni). Validarea și testul rămân doar TIM. La B nu se folosește: OPERA măsoară sistematic ~1,6× mai multă ploaie decât TIM.

---

## 6. Cerințe MATLAB

- Statistics and Machine Learning Toolbox: obligatoriu
- Deep Learning Toolbox: obligatoriu
- Parallel Computing Toolbox: opțional (GPU pentru mișcare și LSTM, `parfor` pentru citire; fără el totul rulează pe CPU)
- Vocea românească Piper: opțională (fără ea, prognoza se afișează ca text; nu cere niciun toolbox), se instalează o singură dată cu `tts_piper\setup_piper.ps1` (vezi `README.md`)

Testat pe R2026b.

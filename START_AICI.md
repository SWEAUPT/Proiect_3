# TIM Radar Lab: începeți de aici

Acesta este spațiul vostru de lucru pentru proiectul de 7 săptămâni: prognoza precipitațiilor la Timișoara, la **t + 30 de minute**, din date radar reale (ANM, stația `TIM`).

Fiecare document are și o versiune `.html` (de exemplu `START_AICI.html`), care se deschide cu dublu-clic în orice browser. Copiile `.html` sunt doar pentru citit: nu se actualizează când modificați un `.md`, deci raportul îl scrieți și îl predați în `student_project_report.md`.

Ordinea de citire:

1. acest fișier: instalarea și ce aveți de scris în fiecare săptămână;
2. `variante_proiect_studenti.md`: ce variantă (A, B sau C) vă revine;
3. `student_instructions.md`: reguli, interpretarea rezultatelor, limitări;
4. `project_roadmap_7_weeks.md` și `flowchart.md`: imaginea de ansamblu;
5. `README.md`: referința tehnică;
6. `student_project_report.md`: șablonul raportului, de completat la final.

---

## 1. Instalare (o singură dată)

1. **MATLAB R2026b** cu Statistics and Machine Learning Toolbox și Deep Learning Toolbox (obligatorii). Parallel Computing Toolbox este opțional. Vocea nu are nevoie de niciun toolbox (Piper, vezi mai jos).
2. **Datele radar.** Descărcați arhiva de pe Drive-ul indicat de profesor și copiați **toate fișierele `TIM_*.hdf`** în folderul `data/` (detalii în `data/README.md`).
3. **Completați arhiva** cu cadrele apărute între timp:
   ```matlab
   w1_sync_archive()
   ```
4. **Verificați** că totul e la locul lui:
   ```matlab
   run_all_tests('Week', 1)
   ```
   Toate testele săptămânii 1 trebuie să treacă.

Opțional:
- **Compozitul european OPERA**, dacă profesorul îl pune la dispoziție (`data_opera/README.md`). La variantele A și C adaugă exemple de antrenament. Fără el proiectul funcționează normal, doar cu un avertisment.
- **Vocea românească pentru prognoză**: `powershell -ExecutionPolicy Bypass -File tts_piper\setup_piper.ps1`.

---

## 2. Regula datelor

Serverul ANM păstrează doar ultimele ~3,5 zile. Ce iese din fereastră nu se mai poate descărca.

- Rulați `w1_sync_archive()` (sau dublu-clic pe `auto_sync.cmd`) la fiecare 2–3 zile, cât durează proiectul.
- **Nu ștergeți niciodată fișiere `.hdf` din `data/`.**
- În `sync_log.txt` cuvântul `ATENTIE-GOL-PERMANENT` înseamnă că s-a pierdut definitiv o bucată din serie.

---

## 3. Ce aveți de scris

Codul de infrastructură este complet: citirea ODIM HDF5, sincronizarea, cache-urile, mișcarea pe GPU, OPERA, vocea. Voi scrieți partea centrală a fiecărei săptămâni. Locurile sunt marcate în cod cu apeluri `todo('N.k', ...)`. Fiecare oprește execuția cu un mesaj clar până îl înlocuiți cu cod. Comentariile de deasupra spun exact ce trebuie calculat.

| Săpt. | Fișier | TODO-uri | Ce învățați |
|:--:|---|---|---|
| 1 | `w1_sync_archive.m`, `radar_read_frame.m` | niciunul (de citit și rulat) | formatul ODIM, calibrarea, fereastra rulantă |
| 2 | `w2_clean_and_stats.m` | 2.1 – 2.3 | statistici doar pe ecou, ponderate cu aria; Z–R pe pixel |
| 3 | `w3_extract_features.m` | 3.1 – 3.5 | tendințe, țintă din viitor, split temporal cu embargo, secvențe |
| 4 | `w4_train_random_forest.m` | 4.1 – 4.4 | Random Forest Breiman, ancorare pe persistență, importanță OOB |
| 5 | `w5_train_lstm.m` | 5.1 – 5.4 | normalizare fără scurgere, LSTM, oprire timpurie |
| 6 | `w6_evaluate_models.m` | 6.1 – 6.3 | referințe, abilitate față de persistență, Macro-F1, Brier |
| 7 | `w7_main_dashboard.m` | 7.1 – 7.2 | hartă polară în km, histogramă ponderată, dashboard |

Pentru a găsi toate TODO-urile rămase: în editorul MATLAB, **Find Files** (Ctrl+Shift+F) și căutați `todo(` în folderul proiectului.

### Cum lucrați într-o săptămână

1. Citiți antetul fișierului săptămânii (secțiunea `CE AVETI DE FACUT`).
2. Înlocuiți fiecare `todo(...)` cu codul cerut.
3. Rulați testele săptămânii, de exemplu `run_all_tests('Week', 2)`, până trec toate.
4. Abia apoi treceți la săptămâna următoare: fiecare se sprijină pe cea dinainte.

> **După ce terminați sau modificați săptămâna 2**, ștergeți `data/feature_cache.mat`. Statisticile pe cadru se păstrează în acest cache, iar o modificare în `w2_clean_and_stats` nu îl invalidează automat. Reconstruirea durează câteva minute.

### La final

```matlab
main                     % fluxul complet: w1 → w7, pentru varianta din main.m
run_all_tests            % toată suita
```

Setați varianta voastră în `main.m` (`PROJECT_VARIANT = 'A'`, `'B'` sau `'C'`). Completați apoi `student_project_report.md` cu rezultatele voastre: tabelul din săptămâna 6 se copiază din rulare, nu din documentație.

---

## 4. Când ceva nu merge

| Mesaj | Cauză |
|---|---|
| `TODO 3.1 neimplementat: ...` | ați ajuns la un loc pe care trebuie să-l scrieți voi |
| `Doar N cadre utilizabile` | arhiva din `data/` lipsește sau e prea mică (pasul 2 din instalare) |
| `Segmentul ... contine o singura clasa` | arhiva e prea scurtă pentru varianta voastră; sincronizați mai multe zile |
| `OPERA cerut, dar data_opera/ lipseste` | doar un avertisment; se antrenează pe TIM |
| teste „sărite” | lipsesc datele locale pentru acel test; e normal fără `data/` |

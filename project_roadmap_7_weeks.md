# TIM Radar Lab: foaia de parcurs (7 săptămâni)

Proiect dedicat prelucrării datelor radar reale de la MeteoRomania (ANM), stația Timișoara (`TIM`), și prognozei pe termen scurt a precipitațiilor prin Machine Learning și Deep Learning.

---

## 1. Cele 3 variante

Toate variantele prezic starea la **t + 30 de minute**, pornind de la cadrul de la momentul **t** și de la ultima oră de evoluție.

| Variantă | Obiectiv | Tip | Metrici | Ce vede studentul |
|---|---|:--:|---|---|
| **A** | Regimul de extindere a precipitațiilor | Clasificare, 4 clase | Acuratețe, Macro-F1, matrice de confuzie | „Precipitații extinse peste 30 min” |
| **B** | Intensitatea medie pe suprafață | Regresie | $R^2$, RMSE, MAE, **abilitate vs persistență** | „0,082 mm/h medie pe suprafață peste 30 min” |
| **C** | Probabilitatea de precipitații (PoP) | Clasificare binară | **Scor Brier**, AUC, acuratețe | „62% șanse de ploaie extinsă în următoarele 30 de minute” |

Definițiile țintelor:

- **A**: fracțiunea din domeniul radar cu ploaie măsurabilă ($R \ge 0{,}1$ mm/h) la $t+30$, discretizată la pragurile `0.05 / 0.15 / 0.30`.
- **B**: intensitatea medie pe suprafață la $t+30$, cu Marshall-Palmer aplicat **pe fiecare pixel** și mediat cu **ponderi de arie**.
- **C**: evenimentul binar „ploaie pe cel puțin 10% din domeniu” la $t+30$; modelul emite o probabilitate (fracțiunea de voturi a pădurii, respectiv softmax-ul LSTM). Probabilitatea nu este calibrată (nu există un pas Platt sau izotonic); scorul Brier arată cât de bună este, dar nu garantează calibrarea.

---

## 2. Progresia pe 7 săptămâni (varianta B)

```
[SAPTAMANA 1] -> w1_sync_archive.m / w1_download_radar.m / radar_read_frame.m
  * Sincronizare incrementala cu ANM (fereastra rulanta ~3.5 zile)
  * Citire ODIM: calibrare din /datasetN/dataM/what, elevatie aleasa dupa unghi
  * Suport pentru ambele produse: PVOL polar si IMAGE (PCAPPI) cartezian
        |
        v
[SAPTAMANA 2] -> w2_clean_and_stats.m
  * Statistici calculate DOAR pe pixelii cu ecou, PONDERATE CU ARIA
  * Marimi fizice: echoFraction, arealRainRate, rainAreaFraction
  * Diagnostic de clutter (ecouri > 60 dBZ, nemeteorologice)
        |
        v
[SAPTAMANA 3] -> w3_extract_features.m
  * Trasaturi la momentul t + tendinte pe 15 si 30 min (+ ora zilei, daca
    arhiva are >= 14 zile de date)
  * Doar la B: miscarea ecourilor si advectia (radar_motion_table, GPU)
  * Eticheta din cadrul VIITOR de la t+30 min
  * Secvente [canale x 12 pasi] pentru LSTM (numarul de canale il afiseaza [w5])
  * Split temporal 70/15/15 cu embargo (istoric + orizont); persistenta ca referinta
        |
        v
[SAPTAMANA 4] -> w4_train_random_forest.m
  * Random Forest Breiman: p/3 predictori pe ramificatie la regresie,
    sqrt(p) la clasificare
  * Importanta prin permutare Out-of-Bag (mai putin biasata decat castigul de impuritate)
  * La A si C, train-ul se completeaza cu esantioane din compozitul OPERA
    (opera_training_rows); validarea si testul raman doar TIM
        |
        v
[SAPTAMANA 5] -> w5_train_lstm.m
  * LSTM(32) pe secvente reale, normalizare estimata doar pe train
  * Ancorare pe persistenta: reteaua invata SCHIMBAREA, nu nivelul
  * Oprire timpurie pe validare, se pastreaza cea mai buna retea
        |
        v
[SAPTAMANA 6] -> w6_evaluate_models.m
  * Evaluare pe segmentul de TEST, niciodata vazut
  * Referinte obligatorii: persistenta si climatologie
  * Regresie: R2, RMSE, MAE, SkillVsPersistenta
  * Binar: scor Brier + AUC
        |
        v
[SAPTAMANA 7] -> w7_main_dashboard.m
  * Harta dBZ si harta mm/h in KILOMETRI fata de radar (conversie polar->cartezian)
  * Histograma pe pixelii cu ecou
  * Card de prognoza condus explicit de varianta
  * Anunt vocal in romana (speak_forecast, vocea Piper ro_RO-mihai, offline)
```

---

## 3. Verificarea automată

```matlab
run_all_tests
```

Suita acoperă contractele de intrare/ieșire ale fiecărei săptămâni **și** proprietățile care validează metodologia: ținta este în viitor, nu poate fi reconstruită din trăsături, segmentele sunt disjuncte și ordonate cronologic, secvențele LSTM au adâncime temporală reală, iar testele nu suprascriu modelele antrenate pe date reale.

Numărul de teste nu este fixat în documentație: rulați suita și citiți raportul final (trecute / eșuate / sărite).

---

## 4. Cum se interpretează rezultatele

Persistența („vremea rămâne neschimbată”) este o prognoză foarte bună la 30 de minute: $R^2$ de ordinul $0{,}8$–$0{,}95$ pe arhivele de până acum, în funcție de segment. Valoarea care contează este cea din tabelul vostru, nu una citată de aici.

Prin urmare:

- un model cu $R^2 = 0{,}85$ poate fi **mai slab** decât să nu faci nimic;
- singura cifră care arată valoare adăugată este `SkillVsPersistenta > 0`;
- pentru varianta C, scorul Brier trebuie comparat cu cel al ratei de bază.

Raportați întotdeauna modelul **și** referința.

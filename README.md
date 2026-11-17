# TIM Radar Lab: proiect semestrial MATLAB (7 săptămâni)

Proiect universitar pentru prelucrarea semnalului radar meteorologic real (ODIM HDF5) de la MeteoRomania (ANM), stația Timișoara (`TIM`), și pentru **prognoza pe termen scurt (nowcasting)** a precipitațiilor prin învățare automată.

---

## 1. Ce prezice, de fapt, proiectul

Trăsăturile se extrag din cadrul radar de la momentul **t** și din **ultima oră** de evoluție. Eticheta se ia dintr-un cadru **viitor**, de la **t + 30 de minute**. Este o problemă reală de prognoză, cu orizont diferit de zero.

Referința obligatorie este **persistența** („vremea rămâne neschimbată”). La 30 de minute este o referință foarte puternică: pe arhivele de până acum $R^2$ de ordinul $0{,}8$–$0{,}95$, în funcție de segment. **Nu citați o valoare din acest document:** citiți-o din tabelul produs de `w6_evaluate_models` pe arhiva voastră. Un model se compară cu ea, nu cu zero.

| Variantă | Obiectiv | Tip | Ținta la $t+30$ min | Metrici |
|:--:|---|:--:|---|---|
| **A** | Regimul de extindere a precipitațiilor | Clasificare, 4 clase | fracțiunea din domeniu cu ploaie măsurabilă, praguri `0.05 / 0.15 / 0.30` | Acuratețe, Macro-F1, matrice de confuzie |
| **B** | Intensitatea medie pe suprafață | Regresie | mm/h, Marshall-Palmer **pe pixel**, mediat cu ponderi de arie | $R^2$, RMSE, MAE, **abilitate față de persistență** |
| **C** | Probabilitatea de precipitații (PoP) | Clasificare binară | eveniment „ploaie pe ≥ 10% din domeniu” | **Scor Brier**, AUC, acuratețe |

Pragurile nu sunt alese arbitrar: provin din distribuția reală a arhivei și dau clase utilizabile. Distribuția exactă depinde de arhiva voastră și se afișează la fiecare rulare (`[w3] Distributia claselor`); folosiți acel număr, nu unul din documentație.

---

## 2. Structura proiectului

```
student_workspace/
├── START_AICI.md             ← Începeți de aici: instalare și TODO-urile pe săptămâni
├── todo.m                    ← Marcajul porțiunilor de scris de voi
├── main.m                    ← Punct unic de intrare (w1 → w7)
│
├── radar_read_frame.m        ← Citire ODIM HDF5 (sursă unică de adevăr)
├── radar_feature_table.m     ← Statistici pe cadru pentru toată arhiva, cu cache
├── radar_motion_table.m      ← Mișcarea ecourilor + advecție (GPU), cu cache
├── radar_phase_shift.m       ← Corelație de fază (FFT, GPU): deplasarea dintre cadre
├── opera_fetch_timisoara.m   ← Compozitul european OPERA, decupat pe Timișoara (ian–oct 2026)
├── opera_feature_table.m     ← Statistici + mișcare pe cadrele OPERA, cu cache
├── opera_training_rows.m     ← Eșantioane OPERA adăugate la train-ul RF (variantele A și C)
│
├── w1_download_radar.m       ← Săpt. 1: obținerea cadrelor (live sau local)
├── w1_sync_archive.m         ← Săpt. 1: sincronizare incrementală a arhivei
├── w2_clean_and_stats.m      ← Săpt. 2: curățare + statistici fizice ponderate cu aria
├── w3_extract_features.m     ← Săpt. 3: set de date de prognoză (t → t+H)
├── w4_train_random_forest.m  ← Săpt. 4: Random Forest (Breiman), ancorat pe persistență
├── w4_predict.m              ← Predicție cu RF (adaugă ancora înapoi), ca w5_predict
├── w5_train_lstm.m           ← Săpt. 5: LSTM pe secvențe temporale reale
├── w5_predict.m              ← Predicție cu modelul LSTM (denormalizare + ancorare)
├── w6_evaluate_models.m      ← Săpt. 6: evaluare pe test + referințe
├── w7_main_dashboard.m       ← Săpt. 7: dashboard cu 4 panouri
│
├── speak_forecast.m          ← Anunț vocal în limba română
├── tts_piper/                ← Vocea românească Piper (offline): setup_piper.ps1, piper_say.py
├── train_full_year.m         ← Antrenament pe toată arhiva locală
│
├── run_all_tests.m           ← Suita de teste
├── run_tests.m               ← Scurtătură → run_all_tests
├── tests/                    ← test_w1.m … test_w7.m
│
├── auto_sync.m               ← Sincronizare cu jurnal în sync_log.txt (pornită manual)
├── auto_sync.cmd             ← Wrapper .cmd: dublu-clic pentru sincronizare
│
├── data/                     ← Arhiva HDF5 (NU ștergeți)
│   ├── feature_cache.mat     ← cache regenerabil de statistici
│   └── cart_grid_cache.mat   ← grile carteziene de 2 km, regenerabile (~0,5 GB)
├── data_opera/              ← OPERA pe Timișoara, ~13 MB/zi; ALT produs, vezi README-ul lui
└── models/                   ← Modelele antrenate (.mat)
```

---

## 3. Utilizare

```matlab
main                    % fluxul complet, varianta configurată în main.m
run_all_tests           % suita de teste
w1_sync_archive()       % adaugă cadrele noi apărute pe serverul ANM
train_full_year([], 'B')  % antrenament pe toată arhiva locală
```

Varianta se schimbă editând `PROJECT_VARIANT` în `main.m` (`'A'`, `'B'` sau `'C'`).

Fiecare document `.md` are o copie `.html` alături, care se deschide în orice browser (sau din MATLAB: `web('README.html')`). Formulele și diagramele au nevoie de internet; fără conexiune apar ca text.

---

## 4. Cerințe MATLAB

Testat pe **R2026b**.

| Toolbox | Folosit pentru | Obligatoriu |
|---|---|:--:|
| Statistics and Machine Learning Toolbox | `fitrensemble`, `fitcensemble`, `templateTree`, `confusionmat` | da |
| Deep Learning Toolbox | `dlnetwork`, `trainnet`, `lstmLayer`, `minibatchpredict` | da |
| Parallel Computing Toolbox | `gpuArray` (mișcare, advecție), `parfor` (citirea cadrelor) | nu (fără el totul rulează pe CPU, serial) |

`speak_forecast` nu cere niciun toolbox: fără Piper instalat afișează doar textul prognozei.

### Vocea românească (Piper)

`speak_forecast` folosește **doar** Piper (HiFi-GAN și vocile Windows sunt doar
englezești și citesc textul românesc cu pronunție engleză). Vocea este
[Piper](https://github.com/OHF-Voice/piper1-gpl) cu modelul `ro_RO-mihai-medium`
(set de date CC0), complet offline, ~3–4 s pe mesaj pe CPU.

```powershell
powershell -ExecutionPolicy Bypass -File tts_piper\setup_piper.ps1   # o singură dată, fără admin, ~230 MB
```

Implicit `'Client', 'piper'`; dacă Piper nu este instalat rămâne doar textul.
`'Client', 'TextOnly'` sare peste sinteză.
Diacriticele se adaugă doar pentru voce; textul afișat rămâne neschimbat.

### GPU

Partea grea din `radar_motion_table` (corelația de fază și advecția prin FFT)
rulează pe `gpuArray`, sute de cadre deodată (toată arhiva: ~6 s pe un RTX 4060
Laptop). Citirea fișierelor HDF5 este limitată de disc, nu de calcul, deci se face
în paralel pe CPU (`parfor`; ~2 min pentru 9 600 de cadre cu 12 procese). LSTM-ul
se antrenează automat pe GPU dacă există unul. Random Forest nu are implementare
GPU în MATLAB și rulează pe CPU.

### Trăsături de mișcare (varianta B)

Trăsăturile de bază sunt medii pe domeniu: spun cât plouă, nu încotro se mișcă
ploaia. `radar_motion_table` adaugă viteza ecourilor și ploaia de pe marginile din
amonte/aval. Pe arhiva completă (4 semințe, selecție pe validare) abilitatea față
de persistență a variantei B a crescut de la 0,532 la 0,588 (test: 0,537 → 0,587).
Pentru A și C nu au ajutat, deci `w3_extract_features` le activează implicit doar
pentru B (`'MotionFeatures', 'auto'`).

### Date suplimentare OPERA (variantele A și C)

Compozitul european OPERA (`data_opera/`, ian–oct 2026) acoperă ~10 luni, față de
~2 luni ale arhivei TIM. Eșantioanele lui se adaugă **doar la segmentul de train**
al Random Forest-ului; validarea și testul rămân exclusiv TIM. Se folosesc numai
eșantioane cu ținta anterioară segmentului de validare, deci fără scurgere.

| Variantă | Doar TIM (val / test) | TIM + OPERA (val / test) |
|:--:|---|---|
| A, macro-F1 | 0,896 / 0,923 | **0,930 / 0,927** |
| B, abilitate | **0,589 / 0,586** | 0,510 / 0,577 |
| C, Brier (mai mic = mai bine) | 0,0181 / 0,0565 | **0,0176 / 0,0474** |

La B strică: OPERA măsoară sistematic ~1,6× mai multă ploaie decât TIM, iar B
prezice exact intensitatea. De aceea `opera_training_rows` îl activează implicit
doar pentru A și C (`train_full_year(..., 'Opera', false)` îl oprește). OPERA
singur este mai slab la toate trei variantele; LSTM-ul rămâne antrenat doar pe TIM.

---

## 5. Sursa de date și o avertizare importantă

Date ODIM HDF5 de pe **https://opendata.meteoromania.ro/radar/TIM/**

> **Serverul păstrează doar o fereastră rulantă de aproximativ 3,5 zile.**
> Cadrele care ies din fereastră **nu mai pot fi recuperate din această sursă**.
> Folderul `data/` este singura copie a arhivei acumulate. **Nu ștergeți fișiere `.hdf` din `data/`.**
> Rulați `w1_sync_archive()` cel puțin o dată la 2–3 zile pentru a nu pierde cadre.

Arhiva conține **două produse** sub același tipar de nume, iar codul le tratează diferit:

| Produs | Geometrie | Dimensiune | Frecvență |
|---|---|---|---|
| `PVOL` | polar, 12 elevații (0,5° … 19,5°) | `920 × 360` | majoritatea cadrelor |
| `IMAGE` (PCAPPI 500 m) | cartezian, proiecție AEQD | `700 × 700` | de regulă unul pe zi, la 23:55, dar apar și serii ocazionale în cursul zilei |

Implicit se antrenează doar pe `PVOL`, pentru că statisticile celor două produse diferă sistematic. Vezi opțiunea `'Product'` din `w3_extract_features`.

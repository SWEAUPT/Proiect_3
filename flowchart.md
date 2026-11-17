# TIM Radar Lab: diagrame de flux

## 1. Fluxul de date, de la fișier la prognoză

```mermaid
flowchart TD
    A["Server ANM<br/>fereastra rulanta ~3.5 zile"] -->|w1_sync_archive| B["data/*.hdf<br/>arhiva locala, aditiva"]
    B --> C["radar_read_frame<br/>calibrare din /datasetN/dataM/what<br/>elevatie aleasa dupa unghi<br/>ponderi de arie"]
    C --> D["w2_clean_and_stats<br/>statistici pe ecou, ponderate cu aria<br/>Z-R pe pixel, plafon 53 dBZ"]
    D --> E["radar_feature_table<br/>cache pe disc"]
    E --> F["w3_extract_features"]

    B --> MT["radar_motion_table (GPU)<br/>miscare + advectie, doar B"]
    MT --> F

    F --> G["X la momentul t<br/>+ tendinte 15/30 min"]
    F --> H["y din cadrul t+30 min"]
    F --> I["secvente canale x 12<br/>pentru LSTM"]
    F --> J["persistenta<br/>(referinta)"]

    O["data_opera/ (OPERA)<br/>opera_training_rows<br/>doar A si C, doar train"] --> K
    G --> K["w4 Random Forest"]
    I --> L["w5 LSTM"]
    K --> M["w6 evaluare pe TEST"]
    L --> M
    J --> M
    H --> M
    M --> N["w7 dashboard<br/>+ speak_forecast"]
```

## 2. Separarea temporală a datelor

Splitul este **cronologic**, nu aleator, iar între segmente există un **embargo**.
Fără embargo, ultimele exemple de antrenament ar avea ținta căzând în intervalul
de validare.

```
|<------------- train 70% ------------->|xxxx|<- val ->|xxxx|<- test ->|
                                         ^^^^           ^^^^
                                       embargo        embargo
                            (= fereastra de intrare + orizontul)
```

Embargoul se **scade din** segmentele de validare și test, nu se inserează între
blocuri de dimensiune completă: train rămâne exact 70%, iar val și test sunt
fiecare 15% *minus* lungimea embargoului.

Lungimea embargoului este `istoric + orizont` (implicit 12 + 6 = 18 cadre), nu
doar orizontul. Amprenta unui eșantion în serie cuprinde și cadrele pe care le
citește ca intrare; cu un embargo egal doar cu orizontul, primele eșantioane de
validare ar împărți cadre de intrare cu ultimele eșantioane de antrenament.

## 3. Ce intră și ce iese din fiecare modul

```mermaid
flowchart LR
    subgraph S1["Saptamana 1"]
        A1["w1_sync_archive()"] --> A2["cadre .hdf noi"]
        A3["radar_read_frame(cale)"] --> A4["struct: dbz, masti,<br/>areaWeight, rainRate,<br/>geometrie, calibrare"]
    end
    subgraph S2["Saptamana 2"]
        B1["w2_clean_and_stats(frame)"] --> B2["cleanMatrix + stats fizice"]
    end
    subgraph S3["Saptamana 3"]
        C1["w3_extract_features(varianta)"] --> C2["X, y, featureNames, taskInfo"]
    end
```

## 4. Decizia asupra tipului de problemă

Tipul problemei vine explicit din `taskInfo`, produs de `w3_extract_features`;
nu se deduce din valorile etichetelor:

```mermaid
flowchart TD
    V{"varianta"} -->|A| A["classification<br/>4 clase"]
    V -->|B| B["regression<br/>mm/h"]
    V -->|C| C["classification binara<br/>+ probabilitate PoP"]
    A --> T["taskInfo.type"]
    B --> T
    C --> T
    T --> W4["w4_train_random_forest"]
    T --> W5["w5_train_lstm"]
    T --> W6["w6_evaluate_models"]
    T --> W7["w7_main_dashboard"]
```

## 5. Cum se citește tabelul din Săptămâna 6

```
Model                      R2      RMSE     MAE    MaxError  SkillVsPersistenta
-------------------------------------------------------------------------------
Random Forest            0.895   0.0089  0.0055   0.041           > 0   <- valoare adaugata
LSTM                     0.810   0.0091  0.0061   0.038           > 0
Persistenta (referinta)  0.775   0.0106  0.0068   0.052             0   <- pragul real
Climatologie (medie)    -0.043   0.0224  0.0180   0.074           < 0
```

Cifrele sunt ilustrative; citiți-le din rularea voastră.

`Climatologie (medie)` are $R^2$ **ușor negativ**, nu exact zero: media este
estimată pe segmentul de antrenament, nu pe cel evaluat. Un $R^2$ exact 0 pe
acest rând ar însemna că referința a fost calculată din chiar etichetele pe care
le măsoară.

Cifra care contează este `SkillVsPersistenta`. Un $R^2$ mare, singur, poate
ascunde un model mai slab decât „vremea rămâne neschimbată”.

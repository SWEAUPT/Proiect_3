# Raport de proiect: TIM Radar Lab

> Șablon. Se completează manual. Înlocuiți textul dintre `<...>` cu rezultatele proprii.
> Raportul nu se generează automat; face parte din evaluare.

**Student:** `<nume, grupa>`
**Varianta atribuită:** `<A / B / C>`
**Orizont de prognoză:** `<30>` minute
**Data rulării:** `<zz.ll.aaaa>`

---

## 1. Obiectivul

`<Descrieți în 3–5 rânduri ce prezice modelul: mărimea țintă, orizontul, și de ce contează.>`

Formularea problemei: trăsăturile provin din cadrul radar de la momentul $t$ și din ultima oră de evoluție; eticheta provine din cadrul de la $t + H$. Este o prognoză cu orizont diferit de zero.

---

## 2. Datele

| Element | Valoare |
|---|---|
| Sursa | `https://opendata.meteoromania.ro/radar/TIM/` |
| Stația | TIM (Timișoara), 45,7717° N / 21,2577° E, altitudine 145 m |
| Instrument | Leonardo METEOR 1700SDP10, bandă S ($\lambda = 10{,}221$ cm) |
| Produs folosit | `<PVOL: volum polar, 12 elevații, 920 × 360, rezoluție 250 m>` |
| Perioada acoperită | `<...>` → `<...>` (`<...>` zile calendaristice) |
| Zile cu date efective | `<...>` (goluri: `<...>`) |
| Număr de cadre | `<...>` |
| Cadre excluse (alt produs) | `<...>` |
| Număr de eșantioane | `<...>` (train `<...>` / val `<...>` / test `<...>`) |

**Observație obligatorie despre sursă:** serverul păstrează o fereastră rulantă de ~3,5 zile, deci arhiva nu poate fi reconstituită retroactiv. `<Comentați cum a afectat asta dimensiunea setului.>`

---

## 3. Prelucrarea semnalului

| Pas | Ce am făcut |
|---|---|
| Calibrare | gain/offset citite din `/dataset1/data1/what` |
| Selecția sweep-ului | elevația `<0,5>°, aleasă explicit după unghi |
| Pixeli `nodata` | excluși din toate statisticile |
| Pixeli `undetect` | tratați ca „fără ecou”, $R = 0$ |
| Ponderare | cu aria (celulele polare cresc cu distanța) |
| Z–R | Marshall-Palmer $Z = 200R^{1{,}6}$, **pe pixel**, plafon 53 dBZ |

`<Explicați de ce media pe toți pixelii ar fi fost greșită și ce măsoară de fapt echoFraction.>`

---

## 4. Trăsături

`<Listați trăsăturile folosite și cele eliminate automat, cu motivul.>`

| Trăsătură | Rol |
|---|---|
| `echoFraction`, `meanDbz`, `p95Dbz`, `p99Dbz`, `stdDbz` | starea curentă a câmpului |
| `fracAbove20`, `fracAbove35` | prezența nucleelor convective |
| `arealRainRate`, `rainAreaFraction` | intensitate și extindere |
| `dArealRain15/30`, `dEchoFrac15/30` | tendința, de regulă cele mai informative |
| `hourSin`, `hourCos` | ora zilei (ciclul diurn), doar dacă arhiva are ≥ 14 zile de date |
| `motionU/V`, `motionSpeed`, `motionQuality`, `advArealDelta`, `advRainFracDelta`, `inflowRain`, `outflowRain` | **doar varianta B**: mișcarea ecourilor și ploaia advectată din amonte |

Trăsături eliminate: `<...>`; motiv: `<varianță nulă / arhivă prea scurtă pentru ciclul diurn>`.

---

## 5. Modele

| | Random Forest | LSTM |
|---|---|---|
| Configurație | `<300 arbori; p/3 predictori/ramificație la B, √p la A și C>` | `<LSTM(32), secvențe <canale> × 12, vezi linia [w5]>` |
| Antrenat pe | segmentul de train (la A și C: + eșantioane OPERA) | segmentul de train (doar TIM) |
| Regularizare | agregare + `MinLeafSize` | dropout 0,2 + oprire timpurie pe validare |

---

## 6. Rezultate pe segmentul de TEST

> Copiați aici tabelul afișat de `w6_evaluate_models`.

```
<lipiți tabelul>
```

| Întrebare | Răspuns |
|---|---|
| Modelul bate persistența? | `<da / nu>`. B: `SkillVsPersistenta = <...>`; A: Macro-F1 model vs persistență; C: Brier model vs persistență |
| Care model e mai bun și de ce? | `<...>` |
| Ce trăsături domină clasamentul de importanță? | `<...>` |

**Interpretare obligatorie:** la 30 de minute persistența este o referință foarte puternică (la B, $R^2$ de ordinul $0{,}8$–$0{,}95$). Citiți valoarea ei de pe rândul `Persistenta (referinta)` din tabelul vostru. `<Comentați dacă modelul aduce valoare peste ea. Un scor mare fără această comparație nu demonstrează nimic.>`

---

## 7. Grafice

`<Inserați dashboard-ul din w7 și, opțional, o serie temporală observat vs prezis.>`

- Figura 1: harta de reflectivitate (km față de radar)
- Figura 2: harta de intensitate (mm/h)
- Figura 3: distribuția dBZ pe pixelii cu ecou
- Figura 4: cardul de prognoză

---

## 8. Limitări

`<Discutați cel puțin acestea:>`

1. Arhiva TIM acoperă câteva săptămâni, nu un an, deci fără sezonalitate. Menționați și golurile (lista e în `data/README.md`): o sincronizare ratată scoate definitiv din serie mai multe zile, iar intervalul calendaristic supraestimează acoperirea reală.
2. Segmentele sunt contigue în timp, deci pot conține un singur regim meteo.
3. Elevația de 0,5° conține clutter de sol; `maximum` nu este folosit ca trăsătură.
4. Ținta este o mărime mediată pe tot domeniul radar, nu precipitația într-un punct.
5. Marshall-Palmer cu coeficienți ficși este o aproximare; nu distinge ploaia de grindină.

---

## 9. Concluzii

`<3–6 rânduri: ce ați învățat, ce ar îmbunătăți rezultatul, ce ați face diferit cu o arhivă de un an.>`

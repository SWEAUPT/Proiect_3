# Ghid de Atribuire a Variantelor de Proiect

Proiectul TIM Radar Lab are 3 variante. Toate rezolvă aceeași problemă, **prognoza precipitațiilor la t + 30 de minute** din date radar reale, dar cu ținte și metrici diferite.

---

## 1. Tabelul celor 3 variante

| Variantă | Denumire | Tip | Ținta la $t+30$ min | Interpretare |
|:---:|---|:---:|---|---|
| **A** | Regimul de extindere a precipitațiilor | Clasificare multiclasă | 4 clase după fracțiunea din domeniu cu ploaie măsurabilă:<br>1: `< 5%`<br>2: `5–15%`<br>3: `15–30%`<br>4: `> 30%` | Cât de extinsă va fi ploaia peste o jumătate de oră. |
| **B** | Intensitatea medie pe suprafață | Regresie | $R \ge 0$ mm/h, prin Marshall-Palmer $Z = 200 R^{1{,}6}$ aplicat **pe fiecare pixel** și mediat cu **ponderi de arie** | Cât de tare va ploua, în medie, pe domeniul radar. |
| **C** | Probabilitatea de precipitații (PoP) | Clasificare binară + probabilitate | $P(\text{ploaie pe} \ge 10\% \text{ din domeniu})$ | „62% șanse de ploaie extinsă în următoarele 30 de minute”. |

### De ce aceste praguri

Nu sunt alese arbitrar, ci din distribuția reală a arhivei, ca să dea clase utilizabile.
Distribuția exactă depinde de arhiva voastră și este afișată la fiecare rulare
(`[w3] Distributia claselor`). Nu o citați dintr-un document: se schimbă la
fiecare sincronizare.

> **De ce fracțiunea de arie și nu percentila reflectivității.** Clase definite pe percentila 95 a reflectivității ar ieși pe datele reale aproape numai 1 și 2 din 4; clasele 3 și 4 ar rămâne goale, iar acuratețea n-ar mai spune nimic.

---

## 2. Atribuirea către studenți

Pe baza numărului de ordine din catalog $N$:

$$\text{Varianta} = \begin{cases}
\mathbf{A}, & N \bmod 3 = 1 \\
\mathbf{B}, & N \bmod 3 = 2 \\
\mathbf{C}, & N \bmod 3 = 0
\end{cases}$$

Exemplu: studentul #1 → **A**, #2 → **B**, #3 → **C**, #4 → **A** …

---

## 3. Configurarea în cod

În `main.m`:

```matlab
PROJECT_VARIANT = 'C';    % 'A', 'B' sau 'C' - valoarea din main.m
HORIZON_MINUTES = 30;     % orizontul de prognoză
```

Programatic:

```matlab
[X, y, featureNames, taskInfo] = w3_extract_features('C', 'HorizonMinutes', 60);
```

---

## 4. Metrici de raportat, pe variantă

| Variantă | Metrici principale | Referință obligatorie |
|---|---|---|
| **A** | Acuratețe, Macro-F1, matrice de confuzie | persistență + clasa majoritară |
| **B** | $R^2$, RMSE, MAE, **SkillVsPersistenta** | persistență + climatologie |
| **C** | **Scor Brier**, AUC, acuratețe | scorul Brier al ratei de bază |

Toate referințele apar automat în tabelul produs de `w6_evaluate_models`. Un rezultat raportat fără referință nu este interpretabil: la 30 de minute persistența singură ajunge la un $R^2$ de ordinul $0{,}8$–$0{,}95$, deci citiți valoarea măsurată pe arhiva voastră.

---

## 5. Dificultate comparativă

| Variantă | Dificultate | Observație |
|---|:--:|---|
| **B** | medie | Cea mai directă de interpretat; țintă continuă, referință clară. |
| **A** | medie-ridicată | Clasele dezechilibrate cer Macro-F1, nu doar acuratețe. |
| **C** | ridicată | Cere înțelegerea scorului Brier și a diferenței dintre o probabilitate emisă și una calibrată (modelul nu este calibrat). |

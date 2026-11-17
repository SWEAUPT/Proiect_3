function [X, y, featureNames, taskInfo] = w3_extract_features(variant, varargin)
% W3_EXTRACT_FEATURES Saptamana 3: Construirea unui set de date de PROGNOZA reala.
%
% Semnatura:
%   [X, y, featureNames, taskInfo] = w3_extract_features(variant, Name, Value, ...)
%
% Optiuni:
%   'DataDir'        folderul arhivei locale        (implicit: <pwd>/data)
%   'HorizonMinutes' orizontul de prognoza in minute (implicit: 30)
%   'HistoryFrames'  cate cadre de istoric intra in secventa (implicit: 12 = 1h)
%   'Product'        'PVOL' | 'IMAGE' | 'all'        (implicit: 'PVOL')
%   'MaxFrames'      limitare pentru rulari rapide  (implicit: Inf)
%   'UseCache'       reutilizeaza statisticile deja calculate (implicit: true)
%   'MotionFeatures' 'auto' | true | false - miscarea ecourilor si advectia,
%                    din radar_motion_table (GPU). 'auto' = doar varianta B,
%                    singura unde castiga pe validare (vezi mai jos).
%   'Source'         'TIM' | 'OPERA' (implicit 'TIM'). 'OPERA' foloseste
%                    compozitul european din data_opera/ (opera_feature_table):
%                    acelasi disc de 230 km, aceleasi definitii, ian-oct 2026.
%                    ALT PRODUS decat radarul TIM - nu se amesteca cele doua.
%
% CE AVETI DE FACUT (Saptamana 3) - cautati apelurile todo(...)
% ---------------------------------------------------------------------
%   3.1  tendintele pe 15 si 30 de minute
%   3.2  impartirea temporala 70/15/15 cu embargo (functia temporal_split)
%   3.3  eliminarea trasaturilor constante, decisa DOAR pe train
%   3.4  tinta si persistenta, din cadrul VIITOR t+H, pentru A, B si C
%   3.5  secventele LSTM [canale x K pasi]
% Verificare: run_all_tests('Week', 3)
%
% REGULA DE AUR: eticheta NU are voie sa poata fi calculata din trasaturi.
% O tinta calculata din chiar coloanele lui X (de ex. p95 si mean ale cadrului
% curent) ar face modelele sa "invete" o identitate algebrica, cu orizont de
% prognoza zero. Testele din test_w3 verifica asta.
%
% PRINCIPII:
%   - Trasaturile provin din cadrul de la momentul t si din istoricul lui.
%   - Eticheta provine dintr-un cadru VIITOR, de la t + HorizonMinutes; nu se
%     calculeaza niciodata din trasaturile aceluiasi cadru (ar fi o identitate
%     algebrica, nu o prognoza).
%   - Nu se genereaza niciun esantion sintetic. Doar date masurate.
%   - Se returneaza si predictia de PERSISTENTA, referinta fata de care
%     are sens sa raportezi performanta.
%
% Persistenta la 30 de minute este o referinta foarte puternica (R2 de ordinul
% 0.8-0.95, in functie de segment si de arhiva). Nu luati numarul de aici:
% w6_evaluate_models il masoara si il tipareste pe randul
% 'Persistenta (referinta)'. Orice model se compara cu acea valoare, nu cu zero.
%
% VARIANTE
%   A  Clasificare in 4 regimuri de extindere a precipitatiilor la t+H,
%      dupa fractiunea din domeniu acoperita de ploaie masurabila.
%      Praguri FIXE 0.05 / 0.15 / 0.30, alese o singura data din distributia
%      unei arhive-pilot. Nu se reajusteaza per rulare, deci nu constituie o
%      scurgere. Distributia realizata se afiseaza la rulare.
%      (O definitie pe percentila p95 de dBZ lasa clasele 3 si 4 vide.)
%   B  Regresie pe intensitatea medie pe suprafata la t+H, in mm/h,
%      prin Marshall-Palmer aplicat pe fiecare pixel si mediat cu ponderi
%      de arie.
%   C  Probabilitatea de precipitatii (PoP): clasificare binara a evenimentului
%      "cel putin 10% din domeniu are ploaie masurabila la t+H".
%      Modelul emite o probabilitate evaluata cu scor Brier.
%
%      NU este o probabilitate CALIBRATA: sursele sunt fractiunea de voturi a
%      padurii si un softmax brut, fara pas de calibrare (Platt / izotonica)
%      si fara diagrama de fiabilitate. Scorul Brier nu garanteaza calibrare.
%      Rata de baza depinde de arhiva si se afiseaza la rulare.

% ---------------------------------------------------------------------
% Praguri de definire a tintelor (documentate, nu magice)
% ---------------------------------------------------------------------
CLASS_EDGES_A = [0.05 0.15 0.30];   % fractiune de arie cu ploaie masurabila
POP_THRESHOLD_C = 0.10;             % eveniment "ploaie extinsa" pentru PoP
RAIN_MIN_MMH = 0.1;                 % prag de ploaie masurabila (folosit in w2)

if nargin < 1 || isempty(variant), variant = 'B'; end
variant = upper(char(variant));
if ~ismember(variant, {'A', 'B', 'C'})
    error('TIMRadar:BadVariant', 'Varianta trebuie sa fie A, B sau C (primit: %s).', variant);
end

p = inputParser;
p.addParameter('DataDir', fullfile(pwd, 'data'), @(x) ischar(x) || isstring(x));
p.addParameter('HorizonMinutes', 30, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('HistoryFrames', 12, @(x) isnumeric(x) && isscalar(x) && x >= 1);
p.addParameter('Product', 'PVOL', @(x) ischar(x) || isstring(x));
p.addParameter('MaxFrames', Inf, @(x) isnumeric(x) && isscalar(x));
p.addParameter('UseCache', true, @(x) islogical(x) || isnumeric(x));
p.addParameter('AllowDiurnal', true, @(x) islogical(x) || isnumeric(x));
p.addParameter('MinDaysForDiurnal', 14, @(x) isnumeric(x) && isscalar(x));
p.addParameter('MotionFeatures', 'auto', @(x) islogical(x) || isnumeric(x) || ...
    ((ischar(x) || isstring(x)) && strcmpi(x, 'auto')));
p.addParameter('Source', 'TIM', @(x) (ischar(x) || isstring(x)) && ...
    ismember(upper(char(x)), {'TIM', 'OPERA'}));
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;
dataDir = char(o.DataDir);
verbose = logical(o.Verbose);
isOpera = strcmpi(o.Source, 'OPERA');

% TRASATURI DE MISCARE (radar_motion_table): viteza ecourilor si ploaia de
% pe marginile din amonte/aval. 'auto' le activeaza DOAR unde castiga pe
% VALIDARE (4 seminte, arhiva completa):
%   B  abilitate fata de persistenta 0.532 -> 0.588 (4/4 seminte; test 0.537 -> 0.587)
%   A  macro-F1 0.896 -> 0.886 (1/4)      C  Brier 0.0283 -> 0.0304 (0/4)
% Pentru A si C nu ajuta: ele clasifica CAT din domeniu este ud, iar asta
% descriu deja trasaturile de suprafata.
if (ischar(o.MotionFeatures) || isstring(o.MotionFeatures))
    useMotion = strcmp(variant, 'B');
else
    useMotion = logical(o.MotionFeatures);
end
if useMotion && ~isOpera && ~strcmpi(o.Product, 'PVOL')
    warning('TIMRadar:MotionNeedsPVOL', ...
        'Trasaturile de miscare exista doar pentru PVOL; se dezactiveaza pentru Product=%s.', o.Product);
    useMotion = false;
end

% ---------------------------------------------------------------------
% 1. Statistici pe cadru (cu cache pe disc - o trecere completa dureaza ~6 min)
% ---------------------------------------------------------------------
if isOpera
    % Statisticile si miscarea vin impreuna; directorul este data_opera/.
    [T, Mopera, meta] = opera_feature_table('HorizonMinutes', o.HorizonMinutes, ...
        'UseCache', logical(o.UseCache), 'Verbose', verbose);
    if isfinite(o.MaxFrames) && height(T) > o.MaxFrames
        T = T(end - o.MaxFrames + 1:end, :);
        Mopera = Mopera(end - o.MaxFrames + 1:end, :);
    end
else
    [T, meta] = radar_feature_table(dataDir, 'Product', o.Product, ...
        'MaxFrames', o.MaxFrames, 'UseCache', logical(o.UseCache), 'Verbose', verbose);
end

if height(T) < 20
    error('TIMRadar:NotEnoughData', ...
        ['Doar %d cadre utilizabile in %s. Ruleaza w1_sync_archive() pentru a ' ...
         'completa arhiva (serverul ANM pastreaza doar ~3.5 zile).'], height(T), dataDir);
end

stepMin = meta.stepMinutes;
H = round(o.HorizonMinutes / stepMin);      % orizont in numar de cadre
K = round(o.HistoryFrames);                 % istoric in numar de cadre
if H < 1
    error('TIMRadar:BadHorizon', 'Orizontul (%g min) este mai mic decat pasul de scanare (%g min).', ...
        o.HorizonMinutes, stepMin);
end

% Cat de departe in urma se uita efectiv un esantion: istoricul cerut pentru
% LSTM (K cadre) SAU decalajul celei mai lungi tendinte (30 min), care poate fi
% mai mare cand HistoryFrames este mic (ex. 'HistoryFrames', 3 si pas de 5 min:
% tendinta pe 30 min cere tot 6 cadre in urma).
lag15 = max(1, round(15 / stepMin));
lag30 = max(1, round(30 / stepMin));
back  = max(K, lag30);

% ---------------------------------------------------------------------
% 2. Esantioane valide: istoric complet in urma SI tinta existenta in fata,
%    toate pe grila temporala regulata (fara sarituri peste pauze)
% ---------------------------------------------------------------------
ts = T.timestamp;
n  = height(T);
isSample = false(n, 1);
for i = (back + 1):(n - H)
    span = ts(i + H) - ts(i - back);
    expected = minutes(stepMin * (back + H));
    if abs(span - expected) <= minutes(stepMin / 2)
        isSample(i) = true;
    end
end
idx = find(isSample);
if isempty(idx)
    error('TIMRadar:NoSamples', ...
        ['Niciun esantion cu istoric de %d cadre si orizont de %d cadre pe o grila ' ...
         'continua. Arhiva are probabil pauze.'], K, H);
end

% ---------------------------------------------------------------------
% 3. Trasaturi la momentul t
% ---------------------------------------------------------------------
% Numele campurilor asa cum le produce w2_clean_and_stats, si etichetele
% lizibile folosite mai departe in importanta predictorilor.
%
% maxRainRate NU este in lista, desi w2 il calculeaza.
% Este constant prin constructie: plafonul de grindina taie reflectivitatea la
% 53 dBZ, iar elevatia de 0.5 grade contine clutter in aproape fiecare cadru,
% deci maximul punctual atinge plafonul mereu (74.88 mm/h in fiecare cadru).
% Ar fi un canal mort si in secventele LSTM. Intensitatea punctuala este oricum
% acoperita de p99Dbz si fracAbove35. Ramane in stats ca diagnostic de calitate.
baseFields = {'echoFraction', 'mean', 'p95', 'p99', 'std', ...
              'fracAbove20', 'fracAbove35', 'arealRainRate', 'rainAreaFraction'};
baseNames  = {'echoFraction', 'meanDbz', 'p95Dbz', 'p99Dbz', 'stdDbz', ...
              'fracAbove20', 'fracAbove35', 'arealRainRate', 'rainAreaFraction'};
missing = baseFields(~ismember(baseFields, T.Properties.VariableNames));
if ~isempty(missing)
    error('TIMRadar:MissingStat', ...
        'Statisticile pe cadru nu contin campurile: %s. Sterge %s si reia.', ...
        strjoin(missing, ', '), fullfile(dataDir, 'feature_cache.mat'));
end
B = zeros(n, numel(baseFields));
for j = 1:numel(baseFields)
    B(:, j) = T.(baseFields{j});
end

colAreal = find(strcmp(baseNames, 'arealRainRate'), 1);
colEcho  = find(strcmp(baseNames, 'echoFraction'), 1);

% Miscarea la momentul t, aliniata pe acelasi tabel T (unire dupa numele
% fisierului, nu dupa pozitie: radar_motion_table are propria lista de cadre).
motionNames = {'motionU', 'motionV', 'motionSpeed', 'motionQuality', ...
               'advArealDelta', 'advRainFracDelta', 'inflowRain', 'outflowRain'};
motionMeta = struct();
if useMotion
    if isOpera
        Mt = Mopera;
        motionMeta = struct('source', 'OPERA', 'nWithMotion', sum(Mt.motionQuality > 0));
    else
        [Mt, motionMeta] = radar_motion_table(dataDir, 'HorizonMinutes', o.HorizonMinutes, ...
            'MaxFrames', o.MaxFrames, 'Verbose', verbose);
    end
    [found, loc] = ismember(T.file, Mt.file);
    if ~all(found)
        error('TIMRadar:MotionMismatch', ...
            '%d cadre fara rand in tabelul de miscare.', sum(~found));
    end
    Mo = zeros(n, numel(motionNames));
    for j = 1:numel(motionNames)
        Mo(:, j) = Mt.(motionNames{j})(loc);
    end
else
    motionNames = {};
    Mo = zeros(n, 0);
end

N = numel(idx);
trendNames = {'dArealRain15', 'dArealRain30', 'dEchoFrac15', 'dEchoFrac30'};
Tr = zeros(N, 4);
% TODO 3.1: tendintele, in ordinea din trendNames.
%   B(i, colAreal) = intensitatea medie pe suprafata la cadrul i
%   B(i, colEcho)  = fractiunea de ecou la cadrul i
%   idx            = indicii cadrelor "acum" (t) ale esantioanelor
%   lag15, lag30   = cate cadre inseamna 15, respectiv 30 de minute
%   dArealRain15 = valoarea acum minus valoarea de acum 15 minute, etc.
%   Tendinta este de regula cea mai informativa trasatura: spune incotro merge ploaia.
%   Modelul de calcul il gasiti mai jos, la esantionul "live" (liveTr).
todo('3.1', 'tendintele Tr(:, 1:4)');

% Ora zilei, codificata ciclic (23:55 si 00:05 trebuie sa fie vecine).
% Luna si anotimpul nu sunt trasaturi: pe arhiva disponibila sunt constante.
% Ciclul diurn se poate INVATA doar daca arhiva acopera destule zile. Pe cateva
% zile, ora zilei devine practic un identificator unic al episodului meteo:
% modelul memoreaza "la ora 03:00 ploua", ceea ce umfla scorurile fara nicio
% putere de generalizare. De aceea trasaturile diurne se includ doar peste un
% prag de acoperire.
%
% ACOPERIREA SE MASOARA PE DATE, NU PE CALENDAR: arhiva are goluri de zile
% intregi din sincronizari ratate, iar intervalul calendaristic le-ar numara ca
% si cum ar contine date. Se insumeaza doar intervalele efectiv acoperite.
spanDays = days(max(ts) - min(ts));
dtsAll = minutes(diff(ts));
coverageDays = (sum(dtsAll(dtsAll <= stepMin * 1.5)) + stepMin) / (60 * 24);
useDiurnal = o.AllowDiurnal && coverageDays >= o.MinDaysForDiurnal;
if useDiurnal
    hod = hour(ts(idx)) + minute(ts(idx)) / 60;
    timeNames = {'hourSin', 'hourCos'};
    Tm = [sin(2 * pi * hod / 24), cos(2 * pi * hod / 24)];
else
    timeNames = {};
    Tm = zeros(N, 0);
    if verbose
        fprintf(['   [w3] Trasaturi diurne excluse: acoperire reala %.1f zile ' ...
                 '(interval calendaristic %.1f zile, prag %g). ' ...
                 'Ora zilei ar fi memorata, nu invatata.\n'], ...
                 coverageDays, spanDays, o.MinDaysForDiurnal);
    end
end

X = [B(idx, :), Tr, Tm, Mo(idx, :)];
featureNames = [baseNames, trendNames, timeNames, motionNames];

% ---------------------------------------------------------------------
% Esantionul "live": cel mai recent cadru care are istoric complet in urma.
% Tinta lui este inca in viitor, deci nu poate intra in antrenament, dar este
% exact cazul pentru care exista proiectul - prognoza pentru acum.
% ---------------------------------------------------------------------
liveIdx = [];
for i = n:-1:(back + 1)
    if abs((ts(i) - ts(i - back)) - minutes(stepMin * back)) <= minutes(stepMin / 2)
        liveIdx = i;
        break;
    end
end
if isempty(liveIdx)
    live = struct('available', false);
else
    liveTr = [B(liveIdx, colAreal) - B(liveIdx - lag15, colAreal), ...
              B(liveIdx, colAreal) - B(liveIdx - lag30, colAreal), ...
              B(liveIdx, colEcho)  - B(liveIdx - lag15, colEcho), ...
              B(liveIdx, colEcho)  - B(liveIdx - lag30, colEcho)];
    if useDiurnal
        h0 = hour(ts(liveIdx)) + minute(ts(liveIdx)) / 60;
        liveTm = [sin(2 * pi * h0 / 24), cos(2 * pi * h0 / 24)];
    else
        liveTm = zeros(1, 0);
    end
    live = struct('available', true, ...
                  'X', [B(liveIdx, :), liveTr, liveTm, Mo(liveIdx, :)], ...
                  'sequence', {{B(liveIdx - K + 1:liveIdx, :).'}}, ...
                  'timestamp', ts(liveIdx), ...
                  'validTime', ts(liveIdx) + minutes(o.HorizonMinutes), ...
                  'file', T.file(liveIdx), ...
                  'persistence', B(liveIdx, colAreal));
end

% Impartirea temporala se calculeaza AICI, inainte de selectia de trasaturi,
% care trebuie sa se uite doar la segmentul de antrenament.
%
% EMBARGO = fereastra de intrare + orizontul, nu doar orizontul. Un esantion
% citeste cadrele [i-back, i] ca intrare si cadrul i+H ca eticheta, deci
% "amprenta" lui in serie are back+H cadre. Un embargo mai scurt lasa primele
% esantioane de validare sa reia ferestrele ultimelor esantioane de antrenament,
% iar oprirea timpurie ar alege pe date deja vazute.
split = temporal_split(N, back + H);

% Eliminarea trasaturilor constante (fara varianta nu pot ajuta si incurca
% importanta predictorilor). Se decide DOAR pe train: o decizie luata pe toate
% esantioanele ar privi validarea si testul, adica tot o scurgere.
% TODO 3.3: vectorul logic `keep` [1 x nTrasaturi]: true pentru trasaturile
%   care VARIAZA pe segmentul de train (abatere standard > 1e-12).
%   Decizia se ia DOAR pe split.train: daca ati privi si validarea si testul,
%   ati alege trasaturile stiind deja datele pe care veti fi evaluati.
todo('3.3', 'keep (trasaturile neconstante pe train)');
if ~all(keep)
    if verbose
        fprintf('   [w3] Trasaturi constante eliminate: %s\n', strjoin(featureNames(~keep), ', '));
    end
    X = X(:, keep);
    featureNames = featureNames(keep);
    if live.available
        live.X = live.X(:, keep);
    end
end

% ---------------------------------------------------------------------
% SIMETRIA INTRARILOR CELOR DOUA MODELE
% ---------------------------------------------------------------------
% Random Forest-ul si LSTM-ul primesc ACELEASI intrari: aceleasi canale de baza
% (filtrate ca X), aceleasi trasaturi diurne si de miscare. Altfel orice
% diferenta de performanta din w6 ar fi in parte o diferenta de intrari, nu de
% arhitectura.
keepBase = keep(1:numel(baseNames));
keepMo   = keep(end - numel(motionNames) + 1:end);
seqNames = [baseNames(keepBase), timeNames, motionNames(keepMo)];

% ---------------------------------------------------------------------
% 4. Tinta, din cadrul VIITOR t+H
% ---------------------------------------------------------------------
% TODO 3.4: tinta y si persistenta, pentru fiecare varianta din switch-ul de mai jos.
%   Tinta vine din cadrul VIITOR, idx + H. Persistenta = "vremea ramane cum e
%   acum", adica ACEEASI marime calculata pe cadrul curent idx.
%     B: intensitatea medie pe suprafata (T.arealRainRate)
%     A: clasa 1..4 a fractiunii cu ploaie (T.rainAreaFraction), prin
%        discretize_classes(..., CLASS_EDGES_A)
%     C: 1 daca T.rainAreaFraction >= POP_THRESHOLD_C, altfel 0 (ca double)
%   Blocul `if live.available` de dupa switch arata aceleasi formule pe
%   cadrul live.
todo('3.4', 'y si persistence');

switch variant
    case 'B'
        taskInfo.type = 'regression';
        taskInfo.targetName = sprintf('Intensitate medie pe suprafata la t+%g min', o.HorizonMinutes);
        taskInfo.unit = 'mm/h';
        taskInfo.classNames = {};
    case 'A'
        taskInfo.type = 'classification';
        taskInfo.targetName = sprintf('Regim de extindere a precipitatiilor la t+%g min', o.HorizonMinutes);
        taskInfo.unit = 'clasa';
        taskInfo.classNames = { ...
            'Fara precipitatii semnificative (<5% din domeniu)', ...
            'Precipitatii izolate (5-15%)', ...
            'Precipitatii extinse (15-30%)', ...
            'Precipitatii generalizate (>30%)'};
    case 'C'
        taskInfo.type = 'classification';
        taskInfo.targetName = sprintf('Probabilitate de precipitatii extinse la t+%g min', o.HorizonMinutes);
        taskInfo.unit = '%';
        taskInfo.classNames = {'Fara ploaie extinsa', 'Ploaie extinsa'};
end

% Persistenta esantionului "live" se exprima pe scara TINTEI variantei curente:
% mm/h pentru B, clasa pentru A, 0/1 pentru C. `live` se construieste inainte
% de switch-ul pe varianta, deci valoarea provizorie de acolo se rescrie aici.
if live.available
    switch variant
        case 'B'
            live.persistence = T.arealRainRate(liveIdx);
        case 'A'
            live.persistence = discretize_classes(T.rainAreaFraction(liveIdx), CLASS_EDGES_A);
        case 'C'
            live.persistence = double(T.rainAreaFraction(liveIdx) >= POP_THRESHOLD_C);
    end
end

% ---------------------------------------------------------------------
% 5. Secvente reale pentru LSTM: [nCanale x K] pe fiecare esantion
%    (K pasi de timp; cu un singur pas LSTM-ul ar fi un simplu perceptron).
% ---------------------------------------------------------------------
% Canalele sunt aceleasi pe care le vede si Random Forest-ul (vezi SIMETRIA
% INTRARILOR), evaluate la FIECARE pas de timp.
Bseq = B(:, keepBase);
if useDiurnal
    hodAll = hour(ts) + minute(ts) / 60;
    Bseq = [Bseq, sin(2 * pi * hodAll / 24), cos(2 * pi * hodAll / 24)];
end
Bseq = [Bseq, Mo(:, keepMo)];          % miscarea, la fiecare pas al secventei

sequences = cell(N, 1);
% TODO 3.5: pentru fiecare esantion s, sequences{s} = ultimele K randuri ale lui
%   Bseq pana la cadrul idx(s) INCLUSIV, transpuse, deci o matrice [nCanale x K]
%   in ordine cronologica (cel mai vechi pas primul). Modelul este linia
%   live.sequence de mai jos. Un LSTM pe un singur pas de timp nu are ce invata.
todo('3.5', 'secventele LSTM');
if live.available
    live.sequence = {Bseq(liveIdx - K + 1:liveIdx, :).'};
end


taskInfo.variant          = variant;
taskInfo.horizonMinutes   = o.HorizonMinutes;
taskInfo.horizonFrames    = H;
taskInfo.historyFrames    = K;
taskInfo.stepMinutes      = stepMin;
taskInfo.featureNames     = featureNames;
taskInfo.usesMotion       = useMotion;
taskInfo.motion           = motionMeta;
% Numele canalelor secventelor, in aceeasi ordine ca rândurile din
% taskInfo.sequences. w5_train_lstm rezolva canalul de ancorare prin acest
% vector, deci trebuie sa descrie secventele EFECTIVE, nu lista bruta de
% statistici: altfel ancora ar indexa un canal greșit dupa filtrarea coloanelor.
taskInfo.baseFeatureNames = seqNames;
taskInfo.sequences        = sequences;
taskInfo.timestamps       = ts(idx);
taskInfo.targetTimestamps = ts(idx + H);
taskInfo.persistence      = persistence;
taskInfo.split            = split;
taskInfo.nSamples         = N;
taskInfo.realSamples      = N;
taskInfo.augmentedSamples = 0;          % nu se fabrica esantioane
taskInfo.totalSamples     = N;
taskInfo.source           = meta;
taskInfo.dataSource       = upper(char(o.Source));
taskInfo.live             = live;
taskInfo.classEdgesA      = CLASS_EDGES_A;
taskInfo.popThresholdC    = POP_THRESHOLD_C;
taskInfo.rainMinMmh       = RAIN_MIN_MMH;

% Segmentele fiind contigue in timp, un segment scurt poate contine o singura
% clasa, caz in care acuratetea pe el nu inseamna nimic.
%
% Aceasta verificare NU sta sub `if verbose`: este o avertizare de corectitudine,
% nu un element de afisaj, si trebuie sa ajunga si la apelantii cu
% 'Verbose', false (inclusiv testele).
if strcmp(taskInfo.type, 'classification')
    segNames = {'train', 'val', 'test'};
    for sname = segNames
        seg = split.(sname{1});
        if ~isempty(seg) && numel(unique(y(seg))) < 2
            warning('TIMRadar:DegenerateSplit', ...
                ['Segmentul %s contine o singura clasa (%d esantioane). ' ...
                 'Acuratetea pe el nu este interpretabila - arhiva este prea ' ...
                 'scurta pentru varianta %s la acest orizont.'], ...
                sname{1}, numel(seg), variant);
        end
    end
end

if verbose
    fprintf('   [w3] Varianta %s | %d esantioane | orizont %g min | istoric %d cadre\n', ...
        variant, N, o.HorizonMinutes, K);
    fprintf('   [w3] Split temporal: train %d / val %d / test %d (embargo %d cadre)\n', ...
        numel(split.train), numel(split.val), numel(split.test), split.embargo);
    if strcmp(taskInfo.type, 'classification')
        u = unique(y);
        cnt = arrayfun(@(c) sum(y == c), u);
        fprintf('   [w3] Distributia claselor: %s\n', ...
            strjoin(arrayfun(@(a, b) sprintf('%g:%.0f%%', a, 100 * b / N), u(:)', cnt(:)', ...
            'UniformOutput', false), '  '));
    else
        fprintf('   [w3] Tinta: medie %.4f, abatere %.4f, interval [%.4f, %.4f] %s\n', ...
            mean(y), std(y), min(y), max(y), taskInfo.unit);
    end
end
end

% =====================================================================
function c = discretize_classes(v, edges)
c = ones(size(v));
for k = 1:numel(edges)
    c(v >= edges(k)) = k + 1;
end
end

% =====================================================================
function split = temporal_split(N, embargo)
% Impartire cronologica 70/15/15 cu embargo intre segmente.
%
% Embargoul elimina cadrele din jurul granitei: fara el, ultimele esantioane
% de antrenament au tinte care cad in intervalul de validare, iar suprapunerea
% ferestrelor de istoric ar produce scurgere de informatie peste granita.
%
% TODO 3.2: vectorii coloana trainIdx, valIdx, testIdx.
%   - CRONOLOGIC, nu aleator: train = primele 70% din esantioane,
%     val = urmatoarele 15%, test = restul.
%   - Embargoul se SCADE din inceputul segmentelor de validare si de test:
%     train ramane exact floor(0.70*N), iar val si test incep fiecare cu
%     `embargo` esantioane mai tarziu. Nu se insereaza goluri suplimentare.
%   - Segmentele trebuie sa fie disjuncte si ordonate (test_w3 verifica).
todo('3.2', 'temporal_split');

split.train = trainIdx(:);
split.val   = valIdx(:);
split.test  = testIdx(:);
split.embargo = embargo;
end

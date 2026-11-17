function [cleanMatrix, stats] = w2_clean_and_stats(input)
% W2_CLEAN_AND_STATS Saptamana 2: Curatare semnal radar si statistici fizice.
%
% Semnatura:
%   [cleanMatrix, stats] = w2_clean_and_stats(rawMatrix)   % mod compatibil
%   [cleanMatrix, stats] = w2_clean_and_stats(frame)       % mod fizic (recomandat)
%
% Unde `frame` este structura returnata de RADAR_READ_FRAME.
%
% CE AVETI DE FACUT (Saptamana 2) - cautati apelurile todo(...)
% ---------------------------------------------------------------------
%   2.1  stats.echoFraction - fractiunea de ARIE cu ecou
%   2.2  statisticile de semnal, DOAR pe pixelii cu ecou, PONDERATE CU ARIA
%   2.3  marimile de precipitatii: arealRainRate, maxRainRate, rainAreaFraction
% Verificare: run_all_tests('Week', 2)
%
% DE CE "DOAR PE ECOU" SI "PONDERAT CU ARIA"
% Pe datele reale ~59% din grila nu are ecou. O medie pe TOTI pixelii masoara
% cat de goala e grila, nu vremea (corelatie -0.99 cu fractiunea de umplutura).
% Intr-o grila polara o celula departata acopera o arie mult mai mare decat una
% de langa radar, deci o medie neponderata supraevalueaza zona din jurul radarului.
%
% CAMPURI stats
% ---------------------------------------------------------------------
% Clasice (calculate doar pe ecou):
%   mean, median, p95, maximum, std, mad, validFraction, numPixels
% Fizice noi:
%   coverageFraction  fractiunea de PIXELI aflati in acoperirea radarului
%                     (identica cu validFraction; nu este ponderata cu aria,
%                      spre deosebire de echoFraction si de restul marimilor)
%   echoFraction      fractiunea de arie cu ecou detectabil
%   fracAbove20/35    fractiunea de arie cu dBZ peste prag
%   arealRainRate     intensitatea medie pe suprafata (mm/h), Z-R pe pixel
%   maxRainRate       intensitatea maxima punctuala (mm/h)
%   rainAreaFraction  fractiunea de arie cu R >= 0.1 mm/h
%   validMask         masca de acoperire, pentru afisare corecta in w7

minDbz = -10;
maxDbz = 75;
HAIL_CAP_DBZ = 53;      % acelasi plafon Z-R ca in radar_read_frame
CLUTTER_DBZ  = 60;      % implicit; se preia din cadru daca exista

if isstruct(input)
    % ---------------- Mod fizic: struct de la radar_read_frame -------------
    F = input;
    % noEchoDbz este in lista: se citeste neconditionat mai jos, deci absenta lui
    % producea o eroare bruta "Reference to non-existent field", exact ce
    % incearca sa evite acest bloc de validare.
    reqFields = {'dbz', 'validMask', 'echoMask', 'areaWeight', 'rainRate', 'noEchoDbz'};
    for i = 1:numel(reqFields)
        if ~isfield(F, reqFields{i})
            error('TIMRadar:InvalidInput', ...
                'Structura de cadru nu contine campul "%s". Foloseste radar_read_frame.', reqFields{i});
        end
    end
    dbz       = F.dbz;
    validMask = F.validMask;
    echoMask  = F.echoMask;
    W         = F.areaWeight;
    rainRate  = F.rainRate;
    noEchoVal = F.noEchoDbz;
    % Pragul de clutter se ia din cadru (radar_read_frame), nu se rescrie aici:
    % o constanta definita in doua locuri ajunge sa difere.
    if isfield(F, 'clutterDbz') && ~isempty(F.clutterDbz)
        CLUTTER_DBZ = F.clutterDbz;
    end
else
    % ---------------- Mod compatibil: matrice bruta ------------------------
    rawMatrix = input;
    if ~isnumeric(rawMatrix) || ~ismatrix(rawMatrix)
        error('TIMRadar:InvalidInput', 'Intrarea trebuie sa fie o matrice numerica 2D.');
    end
    if isempty(rawMatrix)
        error('TIMRadar:EmptySignal', 'Matricea radar este goala.');
    end

    finiteMask = isfinite(rawMatrix);
    if ~any(finiteMask(:))
        error('TIMRadar:EmptySignal', 'Matricea radar nu contine nicio valoare numerica valida.');
    end

    dbz = rawMatrix;
    dbz(~finiteMask) = minDbz;
    dbz = min(max(dbz, minDbz), maxDbz);

    validMask = true(size(dbz));
    noEchoVal = minDbz;
    echoMask  = dbz > minDbz;
    W = ones(size(dbz));
    W = W / numel(W);
    % Acelasi plafon de grindina ca in radar_read_frame. Fara el, calea
    % "matrice bruta" producea pana la ~1780 mm/h la 75 dBZ, in timp ce calea
    % "struct de cadru" plafona la ~75 mm/h: aceeasi functie raporta fizici
    % diferite in functie de tipul intrarii.
    dbzForRain = min(dbz, HAIL_CAP_DBZ);
    rainRate = zeros(size(dbz));
    rainRate(echoMask) = (10 .^ (dbzForRain(echoMask) / 10) / 200) .^ (1 / 1.6);
end

if ~any(validMask(:))
    error('TIMRadar:EmptySignal', 'Cadrul radar nu contine niciun pixel in acoperire.');
end

% ---------------------------------------------------------------------
% Acoperire si suprafata cu ecou (ponderate cu aria)
% ---------------------------------------------------------------------
Wv = W;
Wv(~validMask) = 0;
totalW = sum(Wv(:));
if totalW <= 0
    error('TIMRadar:EmptySignal', 'Ponderile de arie sunt nule pe intreg cadrul.');
end
Wv = Wv / totalW;

stats.coverageFraction = mean(validMask(:));
% TODO 2.1: fractiunea de ARIE cu ecou detectabil.
%   Wv contine deja ponderile de arie, normalizate sa insumeze 1 pe acoperire;
%   echoMask spune unde exista ecou. Rezultatul este un numar intre 0 si 1.
todo('2.1', 'stats.echoFraction');
stats.numPixels        = numel(dbz);
stats.validFraction    = mean(validMask(:));
stats.validMask        = validMask;

% ---------------------------------------------------------------------
% Statistici de semnal, DOAR pe ecou, ponderate cu aria
% ---------------------------------------------------------------------
if any(echoMask(:))
    v  = dbz(echoMask);
    wv = Wv(echoMask);
    wv = wv / sum(wv);

    % TODO 2.2: statisticile de semnal pe ecou, ponderate cu aria.
    %   v  = valorile dBZ ale pixelilor cu ecou
    %   wv = ponderile lor de arie, normalizate sa insumeze 1
    %   Campuri cerute:
    %     stats.mean, stats.std     - media si abaterea standard PONDERATE
    %     stats.median, stats.p95, stats.p99
    %                               - percentile ponderate: weighted_prctile(v, wv, pct),
    %                                 functia de la sfarsitul fisierului
    %     stats.maximum             - maximul simplu
    %     stats.mad                 - mediana ponderata a lui |v - mediana|
    %     stats.fracAbove20/35      - fractiunea din ARIA TOTALA (Wv, nu wv) cu ecou > 20 / > 35 dBZ
    %     stats.clutterFraction     - la fel, pentru dBZ > CLUTTER_DBZ
    %   Mediana lui max(dBZ) pe arhiva reala este ~76 dBZ, peste maximul fizic al
    %   ploii: clutter de sol si interferente. De aceea `maximum` NU va fi folosit
    %   ca trasatura, ci doar ca diagnostic de calitate.
    todo('2.2', 'statisticile ponderate pe ecou');
else
    % Cer complet senin: nu este o eroare, este o observatie valida.
    stats.mean    = noEchoVal;
    stats.median  = noEchoVal;
    stats.p95     = noEchoVal;
    stats.maximum = noEchoVal;
    stats.std     = 0;
    stats.mad     = 0;
    stats.p99     = noEchoVal;
    stats.fracAbove20 = 0;
    stats.fracAbove35 = 0;
    stats.clutterFraction = 0;
end

% ---------------------------------------------------------------------
% Marimi de precipitatii (Marshall-Palmer deja aplicat pe pixel)
% ---------------------------------------------------------------------
R = rainRate;
R(~validMask) = 0;
% TODO 2.3: marimile de precipitatii. R este deja in mm/h, pe fiecare pixel.
%   stats.arealRainRate    - intensitatea medie pe SUPRAFATA (medie ponderata cu Wv)
%   stats.maxRainRate      - intensitatea maxima punctuala
%   stats.rainAreaFraction - fractiunea de arie cu ploaie masurabila, R >= 0.1 mm/h
%   Ordinul de marime real al lui arealRainRate este de sutimi de mm/h.
todo('2.3', 'arealRainRate, maxRainRate, rainAreaFraction');

% ---------------------------------------------------------------------
% Matricea curatata: fara NaN/Inf, in limite fizice (contract stabil)
% ---------------------------------------------------------------------
cleanMatrix = dbz;
cleanMatrix(~isfinite(cleanMatrix)) = noEchoVal;
cleanMatrix = min(max(cleanMatrix, min(minDbz, noEchoVal)), maxDbz);
end

% =====================================================================
function q = weighted_prctile(v, w, pct)
% Percentila ponderata prin functia de repartitie empirica ponderata.
v = v(:);
w = w(:);
[v, idx] = sort(v);
w = w(idx);
cw = cumsum(w);
if cw(end) <= 0
    q = median(v);
    return;
end
cw = cw / cw(end);
k = find(cw >= pct / 100, 1, 'first');
if isempty(k), k = numel(v); end
q = v(k);
end

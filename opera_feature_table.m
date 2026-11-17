function [T, M, meta] = opera_feature_table(varargin)
% OPERA_FEATURE_TABLE Statisticile pe cadru si miscarea, din compozitul OPERA.
%
% Echivalentul lui radar_feature_table + radar_motion_table pentru setul din
% data_opera/ (vezi opera_fetch_timisoara si data_opera/README.md). Produce
% ACELEASI coloane, cu ACELEASI definitii, pe ACELASI domeniu: discul de 230 km
% din jurul radarului TIM. Astfel w3_extract_features poate construi variantele
% A/B/C direct pe OPERA ('Source', 'OPERA') fara alte modificari.
%
% Semnatura:
%   [T, M, meta] = opera_feature_table(Name, Value, ...)
%
% Optiuni:
%   'DataDir'        folderul cu OPERA_TIM_*.mat   (implicit <proiect>/data_opera)
%   'HorizonMinutes' orizontul advectiei           (implicit 30)
%   'RadiusKm'       raza domeniului                (implicit 230, ca sweep-ul TIM)
%   'UseGPU'         'auto' | true | false          (implicit 'auto')
%   'UseCache'       (implicit true)  'Verbose' (implicit true)
%
% Iesire:
%   T  timestamp, product ("OPERA"), file ("OPERA_TIM_<zi>.mat#<cadru>"),
%      echoFraction, mean, p95, p99, std, fracAbove20, fracAbove35,
%      arealRainRate, rainAreaFraction, validFraction, clutterFraction
%   M  aceleasi coloane ca radar_motion_table (miscare, advectie, inflow/outflow)
%   meta  stepMinutes, nUsed, dateRange, clutter, cadre excluse ...
%
% CURATARE (vezi data_opera/README.md, verificarea din 2026-10-18)
%   - cadrele lipsa si cele prezente dar integral nodata nu intra in tabel;
%     golurile raman goluri, w3 nu construieste esantioane peste ele;
%   - pixelii nodata (255) nu intra la numitor, ca validMask la TIM;
%   - CLUTTER: pixelii care ating >= 65 dBZ in peste 0.1% din cadre (36 de
%     pixeli in disc, puncte fixe, ex. 5 km E si 18 km N de radar) sunt scosi
%     din domeniu. Ploaia reala nu atinge 65 dBZ de ~80 de ori in acelasi punct;
%   - cadrele cu mai putin de 90% din disc acoperit se exclud.
%   Reflectivitatea ramane altfel neatinsa; rata de ploaie foloseste acelasi
%   plafon Z-R de 53 dBZ ca radar_read_frame.
%
% STATISTICILE SE CALCULEAZA PRIN HISTOGRAMA
%   q este pe 8 biti, deci histograma pe 256 de valori pe cadru da EXACT media,
%   abaterea, percentilele (aceeasi definitie ca weighted_prctile din w2, cu
%   ponderi egale - grila LAEA este echi-arie) si toate fractiunile.

p = inputParser;
p.addParameter('DataDir', fullfile(fileparts(mfilename('fullpath')), 'data_opera'), ...
    @(x) ischar(x) || isstring(x));
p.addParameter('HorizonMinutes', 30, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('RadiusKm', 230, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('UseGPU', 'auto', @(x) ischar(x) || isstring(x) || islogical(x));
p.addParameter('UseCache', true, @(x) islogical(x) || isnumeric(x));
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;
dataDir = char(o.DataDir);
verbose = logical(o.Verbose);
if (ischar(o.UseGPU) || isstring(o.UseGPU)) && strcmpi(o.UseGPU, 'auto')
    useGPU = canUseGPU();
else
    useGPU = logical(o.UseGPU) && canUseGPU();
end

HAIL_CAP_DBZ = 53;                 % acelasi plafon Z-R ca radar_read_frame
RAIN_MIN = 0.1;
CLUTTER_Q = 194;                   % q >= 194  <=>  dBZ >= 65
CLUTTER_FREQ = 0.001;
MIN_VALID = 0.90;
CELL_KM = 2; LAG = 2; QMAX = 80;
VERSION = 1;

d = dir(fullfile(dataDir, 'OPERA_TIM_*.mat'));
if isempty(d)
    error('TIMRadar:NoOpera', 'Niciun fisier OPERA_TIM_*.mat in %s. Ruleaza opera_fetch_timisoara.', dataDir);
end
[~, ord] = sort({d.name});
d = d(ord);
names = {d.name};
sig = struct('names', {names}, 'bytes', [d.bytes], 'horizon', o.HorizonMinutes, ...
    'radius', o.RadiusKm, 'version', VERSION);
cacheFile = fullfile(dataDir, 'opera_feature_cache.mat');
if logical(o.UseCache) && isfile(cacheFile)
    try
        L = load(cacheFile, 'sig', 'T', 'M', 'meta');
        if isequal(L.sig, sig)
            T = L.T; M = L.M; meta = L.meta;
            if verbose, report(meta); end
            return;
        end
    catch
        warning('TIMRadar:BadOperaCache', 'Cache OPERA invalid, se reconstruieste.');
    end
end

% ---------------------------------------------------------------------
% Geometria: pixelii de 1 km din disc si maparea lor pe grila de 2 km
% ---------------------------------------------------------------------
G0 = load(fullfile(dataDir, names{1}), 'georef');
g = G0.georef;
xKm = (g.xCenters(:).' - g.centerXY(1)) / 1000;      % [1 x nx], est
yKm = (g.yCenters(:) - g.centerXY(2)) / 1000;        % [ny x 1], nord (randul 1 = nord)
[X1, Y1] = meshgrid(xKm, yKm);
disc1 = hypot(X1, Y1) <= o.RadiusKm;
ny = numel(yKm); nx = numel(xKm);

n = 2 * ceil(o.RadiusKm / CELL_KM);
cc = ((1:n) - 0.5) * CELL_KM - n * CELL_KM / 2;
[Xkm, Ykm] = meshgrid(cc, cc);                       % randul 1 = SUD, ca la TIM
disc2 = hypot(Xkm, Ykm) <= o.RadiusKm;

% LUT q -> dBZ, q -> R (mm/h)
qv = (0:255)';
dbzLUT = qv * 0.5 - 32;
rLUT = (10 .^ (min(dbzLUT, HAIL_CAP_DBZ) / 10) / 200) .^ (1 / 1.6);
rLUT([1 256]) = 0;                                  % fara ecou, fara date
dz = dbzLUT(2:255);                                 % valorile cu ecou, q = 1..254
rz = rLUT(2:255);

% ---------------------------------------------------------------------
% Trecerea 1: harta de clutter pe 1 km
% ---------------------------------------------------------------------
% Punct de reluare dupa trecerea 2 (statistici): o intrerupere in trecerea 3
% nu mai reia cele ~15 minute de citire. Se sterge cand cache-ul final exista.
stageFile = fullfile(dataDir, 'opera_feature_stage.mat');
haveStage = false;
if logical(o.UseCache) && isfile(stageFile)
    try
        St = load(stageFile);
        haveStage = isequal(St.sig, sig);
    catch
    end
end

t0 = tic;
pix = find(disc1);
if haveStage
    clut1 = St.clut1;
else
    hi = zeros(numel(pix), 1);
    nFr = 0;
    for k = 1:numel(names)
        [Qd, ~] = load_day(fullfile(dataDir, names{k}), pix);
        hi = hi + sum(Qd >= CLUTTER_Q & Qd < 255, 2);
        nFr = nFr + size(Qd, 2);
    end
    clut1 = hi / max(1, nFr) > CLUTTER_FREQ;
end
pix = pix(~clut1);                                  % domeniul efectiv
nPix = numel(pix);
if verbose
    fprintf('   [opera] clutter: %d pixeli scosi din disc (%.0f s)\n', sum(clut1), toc(t0));
end

% matricea de mediere 1 km -> 2 km (doar pixelii din domeniu)
col = floor((X1(pix) + n * CELL_KM / 2) / CELL_KM) + 1;
row = floor((Y1(pix) + n * CELL_KM / 2) / CELL_KM) + 1;
in = row >= 1 & row <= n & col >= 1 & col <= n;
cellIdx = sub2ind([n n], row(in), col(in));
A = sparse(cellIdx, find(in), 1, n * n, nPix);
A(~disc2(:), :) = 0;

% ---------------------------------------------------------------------
% Trecerea 2: statistici pe cadru + frecventa de ploaie pe grila de 2 km
% ---------------------------------------------------------------------
t0 = tic;
if haveStage
    T = St.T; clut2 = St.clut2; nAll = St.nAll; nNodata = St.nNodata; nPartial = St.nPartial;
else
statNames = {'echoFraction', 'mean', 'p95', 'p99', 'std', 'fracAbove20', 'fracAbove35', ...
             'arealRainRate', 'rainAreaFraction', 'validFraction', 'clutterFraction'};
Sall = cell(numel(names), 1); TSall = cell(numel(names), 1); Fall = cell(numel(names), 1);
cnt2 = zeros(n * n, 1);
nGrid = 0;
q05 = uint8(round(255 * log1p(0.5) / log1p(QMAX)));
nAll = 0; nNodata = 0; nPartial = 0;
for k = 1:numel(names)
    [Qd, ts, fr, nMiss, nEmpty] = load_day(fullfile(dataDir, names{k}), pix);
    nAll = nAll + nMiss; nNodata = nNodata + nEmpty;
    m = size(Qd, 2);
    S = zeros(m, numel(statNames));
    for j = 1:m
        c = accumarray(double(Qd(:, j)) + 1, 1, [256 1]);
        S(j, :) = frame_stats(c, dz, rz, nPix, RAIN_MIN);
    end
    ok = S(:, 10) >= MIN_VALID;
    nPartial = nPartial + sum(~ok);
    Q2 = to_grid(Qd(:, ok), A, rLUT, n, QMAX);
    cnt2 = cnt2 + sum(reshape(Q2, n * n, []) > q05, 2);
    nGrid = nGrid + sum(ok);
    Sall{k} = S(ok, :); TSall{k} = ts(ok);
    Fall{k} = string(names{k}) + "#" + compose('%03d', fr(ok));
end
clut2 = reshape(cnt2 / max(1, nGrid) > 0.25, n, n) & disc2;   % aceeasi regula ca TIM
S = vertcat(Sall{:});
ts = vertcat(TSall{:});
files = vertcat(Fall{:});
T = table(ts, repmat("OPERA", numel(ts), 1), files, 'VariableNames', {'timestamp', 'product', 'file'});
for j = 1:numel(statNames)
    T.(statNames{j}) = S(:, j);
end
if logical(o.UseCache)
    save(stageFile, 'sig', 'clut1', 'T', 'clut2', 'nAll', 'nNodata', 'nPartial');
end
end
if verbose
    fprintf('   [opera] statistici: %d cadre (%.0f s)\n', height(T), toc(t0));
end

% ---------------------------------------------------------------------
% Trecerea 3: miscarea si advectia, zi cu zi, pe nucleul comun cu TIM.
% Fiecare zi primeste in fata ultimele LAG cadre ale zilei precedente, ca
% primele cadre ale zilei sa aiba pereche; continuitatea o verifica nucleul.
% ---------------------------------------------------------------------
t0 = tic;
co = struct('HorizonMinutes', o.HorizonMinutes, 'LagFrames', LAG, 'CellKm', CELL_KM, ...
    'MinRainForMotion', 1.0, 'MinRainCells', 50, 'useGPU', useGPU, 'stepMin', 5, ...
    'QMAX', QMAX, 'clutter', clut2);
Mall = cell(numel(names), 1);
tailQ = zeros(n, n, 0, 'uint8'); tailT = NaT(0, 1);
for k = 1:numel(names)
    [Qd, tsd] = load_day(fullfile(dataDir, names{k}), pix);
    S = zeros(size(Qd, 2), 1);
    for j = 1:size(Qd, 2)
        S(j) = sum(Qd(:, j) ~= 255) / nPix;
    end
    ok = S >= MIN_VALID;
    Q2 = to_grid(Qd(:, ok), A, rLUT, n, QMAX);
    tsd = tsd(ok);
    Qc = cat(3, tailQ, Q2); tc = [tailT; tsd];
    Mo = radar_motion_core(Qc, tc, true(numel(tc), 1), disc2, Xkm, Ykm, o.RadiusKm, co);
    Mall{k} = Mo(numel(tailT) + 1:end, :);
    keepTail = max(1, numel(tsd) - LAG + 1):numel(tsd);
    tailQ = Q2(:, :, keepTail); tailT = tsd(keepTail);
    if verbose && mod(k, 30) == 0
        fprintf('   [opera] miscare: %d/%d zile (%.0f s)\n', k, numel(names), toc(t0));
    end
end
Mo = vertcat(Mall{:});
M = table(T.timestamp, T.file, Mo(:, 1), Mo(:, 2), hypot(Mo(:, 1), Mo(:, 2)), Mo(:, 3), ...
    Mo(:, 4), Mo(:, 5), Mo(:, 6), Mo(:, 7), Mo(:, 8), ...
    'VariableNames', {'timestamp', 'file', 'motionU', 'motionV', 'motionSpeed', ...
    'motionQuality', 'advArealDelta', 'advRainFracDelta', 'inflowRain', 'outflowRain', ...
    'cartArealRain'});
if verbose
    fprintf('   [opera] miscare: %.0f s (%s)\n', toc(t0), ternary(useGPU, 'GPU', 'CPU'));
end

dts = minutes(diff(T.timestamp));
meta = struct('stepMinutes', 5, 'nFiles', numel(names), 'nUsed', height(T), ...
    'product', 'OPERA', 'dataDir', dataDir, ...
    'dateRange', [min(T.timestamp), max(T.timestamp)], ...
    'gapsOverStep', sum(dts > 7.5), ...
    'framesMissing', nAll, 'framesAllNodata', nNodata, 'framesPartial', nPartial, ...
    'clutterPixels1km', sum(clut1), 'clutterCells2km', sum(clut2(:)), ...
    'radiusKm', o.RadiusKm, 'horizonMinutes', o.HorizonMinutes, ...
    'nWithMotion', sum(M.motionQuality > 0), 'usedGPU', useGPU);
if verbose, report(meta); end
if logical(o.UseCache)
    try
        save(cacheFile, 'sig', 'T', 'M', 'meta');
        if isfile(stageFile), delete(stageFile); end
    catch ME
        warning('TIMRadar:OperaCacheWrite', 'Cache-ul OPERA nu s-a salvat: %s', ME.message);
    end
end
end

% =====================================================================
function [Qd, ts, fr, nMiss, nEmpty] = load_day(file, pix)
% Cadrele utilizabile ale unei zile, doar pixelii din domeniu: [nPix x m].
S = load(file, 'q', 'present', 'timestamps');
q = reshape(S.q, [], size(S.q, 3));
q = q(pix, :);
empty = all(q == 255, 1).';
use = S.present(:) & ~empty;
Qd = q(:, use);
ts = S.timestamps(use);
fr = find(use);
nMiss = sum(~S.present(:));
nEmpty = sum(S.present(:) & empty);
end

% =====================================================================
function s = frame_stats(c, dz, rz, nPix, rainMin)
% c: histograma pe q = 0..255. Aceleasi definitii ca w2_clean_and_stats.
nValid = sum(c(1:255));
ce = c(2:255);
nEcho = sum(ce);
s = zeros(1, 11);
s(10) = nValid / nPix;
if nValid == 0, s(:) = 0; s([2 3 4]) = -32; return; end
s(1) = nEcho / nValid;
if nEcho > 0
    w = ce / nEcho;
    cw = cumsum(w);
    s(2) = sum(w .* dz);
    s(3) = dz(find(cw >= 0.95, 1, 'first'));
    s(4) = dz(find(cw >= 0.99, 1, 'first'));
    s(5) = sqrt(max(0, sum(w .* (dz - s(2)).^2)));
    s(6) = sum(ce(dz > 20)) / nValid;
    s(7) = sum(ce(dz > 35)) / nValid;
    s(11) = sum(ce(dz > 60)) / nValid;
else
    s([2 3 4]) = -32;                       % cer senin: cel mai mic dBZ al scalei
end
s(8) = sum(ce .* rz) / nValid;
s(9) = sum(ce(rz >= rainMin)) / nValid;
end

% =====================================================================
function Q2 = to_grid(Qd, A, rLUT, n, QMAX)
% Pixelii de 1 km -> grila de 2 km: media ratei de ploaie pe pixelii cu date.
m = size(Qd, 2);
Q2 = zeros(n, n, m, 'uint8');
for b0 = 1:96:m
    j = b0:min(m, b0 + 95);
    q = Qd(:, j);
    R = rLUT(double(q) + 1);
    num = A * R;
    den = A * double(q ~= 255);
    G = num ./ max(den, 1);
    Q2(:, :, j) = reshape(uint8(round(255 * log1p(max(G, 0)) / log1p(QMAX))), n, n, []);
end
end

% =====================================================================
function report(meta)
fprintf(['   [opera] %d cadre, %s -> %s | lipsa %d, nodata %d, partiale %d | ' ...
         'clutter %d px (1 km) / %d celule (2 km) | miscare pe %d cadre\n'], ...
    meta.nUsed, string(meta.dateRange(1)), string(meta.dateRange(2)), meta.framesMissing, ...
    meta.framesAllNodata, meta.framesPartial, meta.clutterPixels1km, meta.clutterCells2km, ...
    meta.nWithMotion);
end

% =====================================================================
function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end

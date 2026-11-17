function [M, meta] = radar_motion_table(dataDir, varargin)
% RADAR_MOTION_TABLE Miscarea ecourilor si advectia lor, pe fiecare cadru PVOL.
%
% Trasaturile din radar_feature_table sunt MEDII PE DOMENIU: spun cat ploua,
% dar nu si incotro se misca ploaia. La 30 de minute, schimbarea intensitatii
% medii vine in buna parte din ploaia care INTRA sau IESE din cercul de 230 km,
% iar un model care vede doar medii nu are cum sa o anticipeze. Nicio schimbare
% de algoritm (boosting, model liniar, istoric mai lung, LSTM) nu bate Random
% Forest-ul pe trasaturile de suprafata: limita este informatia, nu modelul.
%
% Aceasta functie adauga informatia lipsa, prin metoda standard de nowcasting
% radar - extrapolarea lagrangiana:
%   1. fiecare sweep polar devine o grila carteziana de 2 km (matrice rara de
%      ponderi de arie, calculata o singura data);
%   2. vectorul de miscare dintre t-10 min si t se estimeaza prin CORELATIE
%      DE FAZA (FFT), pe GPU, in loturi de sute de cadre;
%   3. ploaia mobila se deplaseaza cu acel vector pe orizontul cerut (FFT cu
%      rampa de faza, pe o grila dublata cu zerouri - ploaia care iese din
%      domeniu dispare, nu reapare pe partea opusa);
%   4. din campul deplasat se calculeaza ce schimbare de ploaie prezice advectia.
%
% Semnatura:
%   [M, meta] = radar_motion_table(dataDir, Name, Value, ...)
%
% Optiuni:
%   'HorizonMinutes' orizontul advectiei                   (implicit 30)
%   'LagFrames'      distanta dintre cadrele comparate     (implicit 2 = 10 min)
%   'CellKm'         latura celulei carteziene             (implicit 2)
%   'MinRainForMotion' doar ploaia peste acest prag (mm/h) intra in estimarea
%                    miscarii; ~23 dBZ, peste ecoul de aer clar (implicit 1)
%   'MinRainCells'   celule de ploaie necesare in AMBELE cadre (implicit 50 = 200 km2)
%   'MaxFrames'      doar ultimele N cadre (teste rapide)  (implicit Inf)
%   'UseGPU'         'auto' | true | false                 (implicit 'auto')
%   'UseParallel'    citire paralela cu parfor             (implicit true)
%   'CacheFile'      grilele carteziene, regenerabile      (implicit data/cart_grid_cache.mat)
%   'Verbose'        (implicit true)
%
% Iesire M (table, cronologic, aceleasi cadre PVOL ca radar_feature_table):
%   timestamp, file
%   motionU, motionV     viteza ecourilor spre est / nord (km/h)
%   motionSpeed          modulul vitezei (km/h)
%   motionQuality        inaltimea varfului de corelatie (0 = miscare necunoscuta)
%   advArealDelta        schimbarea intensitatii medii prezisa de advectie (mm/h)
%   advRainFracDelta     schimbarea fractiunii cu ploaie (>= 0.1 mm/h) prezisa
%   inflowRain           ploaia medie pe inelul exterior de 40 km, in AMONTE (mm/h)
%   outflowRain          aceeasi marime, in AVAL (mm/h)
% Cand miscarea nu se poate estima (cadru precedent lipsa sau prea putin ecou),
% vitezele si deltele sunt 0, iar motionQuality = 0 - modelul o poate folosi.
%
% DE CE CORELATIE DE FAZA SI NU opticalFlowFarneback
% ---------------------------------------------------------------------
% Pentru un singur vector pe domeniu, corelatia de faza este metoda robusta
% standard si se reduce la FFT-uri, care pe gpuArray ruleaza pe sute de cadre
% deodata. Obiectele de flux optic din Computer Vision Toolbox nu accepta
% gpuArray si lucreaza cadru cu cadru.
%
% CLUTTER
% ---------------------------------------------------------------------
% Elevatia de 0.5 grade are ecouri de sol fixe. Ele nu se misca, deci ar trage
% estimarea vitezei spre zero. Celulele care "ploua" in peste 25% din toate
% cadrele sunt tratate ca ecou static: excluse din estimarea miscarii si
% lasate pe loc la advectie (tinta le contine in continuare).

if nargin < 1 || isempty(dataDir), dataDir = fullfile(pwd, 'data'); end
dataDir = char(dataDir);

p = inputParser;
p.addParameter('HorizonMinutes', 30, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('LagFrames', 2, @(x) isnumeric(x) && isscalar(x) && x >= 1);
p.addParameter('CellKm', 2, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('MaxFrames', Inf, @(x) isnumeric(x) && isscalar(x));
p.addParameter('UseGPU', 'auto', @(x) ischar(x) || isstring(x) || islogical(x));
p.addParameter('UseParallel', true, @(x) islogical(x) || isnumeric(x));
p.addParameter('CacheFile', '', @(x) ischar(x) || isstring(x));
p.addParameter('MinRainForMotion', 1.0, @(x) isnumeric(x) && isscalar(x) && x >= 0);
p.addParameter('MinRainCells', 50, @(x) isnumeric(x) && isscalar(x) && x >= 1);
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;
verbose = logical(o.Verbose);
cacheFile = char(o.CacheFile);
if isempty(cacheFile), cacheFile = fullfile(dataDir, 'cart_grid_cache.mat'); end

if (ischar(o.UseGPU) || isstring(o.UseGPU)) && strcmpi(o.UseGPU, 'auto')
    useGPU = canUseGPU();
else
    useGPU = logical(o.UseGPU) && canUseGPU();
end

QMAX = 80;                          % mm/h; plafonul Z-R da ~75, deci incape

% ---------------------------------------------------------------------
% 1. Lista cadrelor PVOL, in ordine cronologica (aceeasi ca pentru trasaturi)
% ---------------------------------------------------------------------
T = radar_feature_table(dataDir, 'Product', 'PVOL', 'MaxFrames', o.MaxFrames, 'Verbose', false);
files = cellstr(T.file);
ts = T.timestamp;
nF = numel(files);
stepMin = mode(minutes(diff(ts)));
if isempty(stepMin) || ~(stepMin > 0), stepMin = 5; end

% ---------------------------------------------------------------------
% 2. Geometria: matricea rara polar -> cartezian, din primul cadru
% ---------------------------------------------------------------------
F0 = radar_read_frame(fullfile(dataDir, files{end}));
g = F0.geometry;
if ~strcmp(g.type, 'polar')
    error('TIMRadar:NotPolar', 'radar_motion_table asteapta cadre PVOL polare.');
end
[A, disc, Xkm, Ykm, n] = polar_to_cart_matrix(g, o.CellKm);

% ---------------------------------------------------------------------
% 3. Grilele carteziene (uint8, scara logaritmica), cu cache incremental
% ---------------------------------------------------------------------
C = struct('names', {{}}, 'bytes', [], 'Q', zeros(n, n, 0, 'uint8'), 'cellKm', o.CellKm, ...
           'nbins', g.nbins, 'nrays', g.nrays, 'rscale', g.rscale);
if isfile(cacheFile)
    try
        L = load(cacheFile, 'C');
        if L.C.cellKm == o.CellKm && L.C.nbins == g.nbins && L.C.nrays == g.nrays ...
                && L.C.rscale == g.rscale
            C = L.C;
        end
    catch
        warning('TIMRadar:BadCartCache', 'Cache cartezian invalid, se reconstruieste.');
    end
end
d = cellfun(@(f) dir(fullfile(dataDir, f)), files);
bytes = [d.bytes];
[isCached, loc] = ismember(files(:).', C.names);
if any(isCached)                    % un fisier cu alta dimensiune se reconverteste
    isCached(isCached) = C.bytes(loc(isCached)) == bytes(isCached);
end
todo = find(~isCached);

Qnew = zeros(n, n, numel(todo), 'uint8');
okNew = false(1, numel(todo));
if ~isempty(todo)
    if verbose
        fprintf('   [motion] %d cadre de convertit in grila carteziana (%d in cache)...\n', ...
            numel(todo), nF - numel(todo));
    end
    t0 = tic;
    todoFiles = fullfile(dataDir, files(todo));
    nb = g.nbins; nr = g.nrays;
    usePar = logical(o.UseParallel) && numel(todo) > 50 && ...
             license('test', 'Distrib_Computing_Toolbox');
    if usePar
        parfor k = 1:numel(todo)
            [Qnew(:, :, k), okNew(k)] = frame_to_grid(todoFiles{k}, A, n, nb, nr, QMAX);
        end
    else
        for k = 1:numel(todo)
            [Qnew(:, :, k), okNew(k)] = frame_to_grid(todoFiles{k}, A, n, nb, nr, QMAX);
        end
    end
    if verbose
        fprintf('   [motion] conversie: %.0f s (%s)\n', toc(t0), ...
            ternary(usePar, 'parfor', 'serial'));
    end
    if any(okNew)
        keepOld = ~ismember(C.names, files(todo));
        C.names = [C.names(keepOld), files(todo(okNew)).'];
        C.bytes = [C.bytes(keepOld), bytes(todo(okNew))];
        C.Q = cat(3, C.Q(:, :, keepOld), Qnew(:, :, okNew));
        try
            save(cacheFile, 'C', '-v7.3', '-nocompression');
        catch ME
            warning('TIMRadar:CartCacheWrite', 'Cache-ul cartezian nu s-a salvat: %s', ME.message);
        end
    end
end
[have, loc] = ismember(files, C.names);
Q = zeros(n, n, nF, 'uint8');
Q(:, :, have) = C.Q(:, :, loc(have));

% ---------------------------------------------------------------------
% 4. GPU: clutter, miscare, advectie - nucleul comun cu OPERA
% ---------------------------------------------------------------------
co = struct('HorizonMinutes', o.HorizonMinutes, 'LagFrames', o.LagFrames, ...
    'CellKm', o.CellKm, 'MinRainForMotion', o.MinRainForMotion, ...
    'MinRainCells', o.MinRainCells, 'useGPU', useGPU, 'stepMin', stepMin, 'QMAX', QMAX);
[Mo, ci] = radar_motion_core(Q, ts, have(:), disc, Xkm, Ykm, g.maxRangeKm, co);
U = Mo(:, 1); V = Mo(:, 2); QL = Mo(:, 3); advA = Mo(:, 4); advF = Mo(:, 5);
inflow = Mo(:, 6); outflow = Mo(:, 7); cartA = Mo(:, 8);
gpuSec = ci.gpuSeconds;
lagMin = ci.lagMinutes;

M = table(ts, string(files(:)), U, V, hypot(U, V), QL, advA, advF, inflow, outflow, cartA, ...
    'VariableNames', {'timestamp', 'file', 'motionU', 'motionV', 'motionSpeed', ...
    'motionQuality', 'advArealDelta', 'advRainFracDelta', 'inflowRain', 'outflowRain', ...
    'cartArealRain'});

meta = struct('nFrames', nF, 'nWithMotion', sum(QL > 0), 'lagMinutes', lagMin, ...
    'horizonMinutes', o.HorizonMinutes, 'cellKm', o.CellKm, 'gridSize', n, ...
    'clutterFraction', ci.clutterFraction, 'usedGPU', useGPU, ...
    'gpuSeconds', gpuSec, 'cacheFile', cacheFile);
if verbose
    fprintf(['   [motion] %d cadre, miscare estimata pe %d (%.0f%%) | clutter static %.1f%% ' ...
             'din disc | %s %.1f s\n'], nF, meta.nWithMotion, 100 * meta.nWithMotion / nF, ...
             100 * meta.clutterFraction, ternary(useGPU, 'GPU', 'CPU'), gpuSec);
    ok = QL > 0;
    if any(ok)
        dirFrom = mod(atan2d(-U(ok), -V(ok)), 360);     % de unde VINE ecoul, ca la vant
        fprintf('   [motion] viteza mediana %.0f km/h, directia de provenienta mediana %.0f grade\n', ...
            median(hypot(U(ok), V(ok))), median(dirFrom));
    end
end
end

% =====================================================================
function [q, ok] = frame_to_grid(file, A, n, nb, nr, QMAX)
q = zeros(n, n, 'uint8');
ok = false;
try
    F = radar_read_frame(file);
    if ~isequal(size(F.rainRate), [nb nr]), return; end
    R = F.rainRate;
    R(~isfinite(R)) = 0;
    G = reshape(A * R(:), n, n);
    q = uint8(round(255 * log1p(max(G, 0)) / log1p(QMAX)));
    ok = true;
catch
end
end

% =====================================================================
function [A, disc, Xkm, Ykm, n] = polar_to_cart_matrix(g, cellKm)
% Media ponderata cu aria a pixelilor polari care cad in fiecare celula.
% Departe de radar (arc de 4 km la 230 km) unele celule de 2 km nu primesc
% niciun centru de pixel: acestea iau valoarea celui mai apropiat pixel.
nb = g.nbins; nr = g.nrays;
Rmax = g.maxRangeKm;
n = 2 * ceil(Rmax / cellKm);
rC = (g.rstart + ((1:nb)' - 0.5) * g.rscale) / 1000;         % km
az = ((1:nr) - 0.5) * 2 * pi / nr;                           % de la nord, orar
[AZ, RR] = meshgrid(az, rC);
x = RR .* sin(AZ); y = RR .* cos(AZ);
col = floor((x + n * cellKm / 2) / cellKm) + 1;
row = floor((y + n * cellKm / 2) / cellKm) + 1;              % randul 1 = sud
in = row >= 1 & row <= n & col >= 1 & col <= n;
cellIdx = sub2ind([n n], row(in), col(in));
polIdx = find(in);
w = RR(in);                                                  % aria inelului ~ r
A = sparse(cellIdx, polIdx, w, n * n, nb * nr);

cc = ((1:n) - 0.5) * cellKm - n * cellKm / 2;
[Xkm, Ykm] = meshgrid(cc, cc);
rCell = hypot(Xkm, Ykm);
disc = rCell <= Rmax;
empty = full(sum(A, 2)) == 0 & disc(:);
if any(empty)
    e = find(empty);
    bi = min(nb, floor(rCell(e) * 1000 / g.rscale) + 1);
    ai = mod(floor(mod(atan2(Xkm(e), Ykm(e)), 2 * pi) / (2 * pi) * nr), nr) + 1;
    A = A + sparse(e, sub2ind([nb nr], bi, ai), 1, n * n, nb * nr);
end
rs = full(sum(A, 2));
rs(rs == 0) = 1;
A = spdiags(1 ./ rs, 0, n * n, n * n) * A;
A(~disc(:), :) = 0;
end

% =====================================================================
function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end

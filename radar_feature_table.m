function [T, meta] = radar_feature_table(dataDir, varargin)
% RADAR_FEATURE_TABLE Statistici pe cadru pentru toata arhiva locala, cu cache.
%
% O trecere completa peste 975 de cadre dureaza ~6 minute, aproape integral in
% h5info/h5read. Rezultatul se pastreaza intr-un cache pe disc, indexat dupa
% numele si dimensiunea fisierului, astfel incat rularile urmatoare sa
% proceseze doar cadrele noi aduse de w1_sync_archive.
%
% Semnatura:
%   [T, meta] = radar_feature_table(dataDir, Name, Value, ...)
%
% Optiuni:
%   'Product'   'PVOL' | 'IMAGE' | 'all'   (implicit 'PVOL')
%   'MaxFrames' numar maxim de cadre       (implicit Inf)
%   'UseCache'  logical                    (implicit true)
%   'CacheFile' cale catre cache           (implicit <dataDir>/feature_cache.mat)
%
% Iesiri:
%   T     table sortat cronologic: timestamp, product, fisier + coloane statistici
%   meta  struct: stepMinutes, nFiles, nUsed, excludedByProduct, dateRange
%
% DE CE FILTRAREA DUPA PRODUS
% ---------------------------------------------------------------------
% Arhiva contine doua produse diferite sub acelasi tipar de nume:
%   PVOL  - volum polar, 12 elevatii, [920 x 360]   (965 cadre)
%   IMAGE - PCAPPI cartezian la 500 m, [700 x 700]  (10 cadre, tipic la 23:55)
% Statisticile lor difera sistematic (mediana intensitatii pe suprafata:
% 0.0344 mm/h pe PVOL fata de 0.0165 mm/h pe IMAGE), deci amestecarea lor
% introduce un salt artificial in serie. Implicit se pastreaza produsul
% dominant; 'all' le combina, iar coloana `product` ramane disponibila.

if nargin < 1 || isempty(dataDir), dataDir = fullfile(pwd, 'data'); end
dataDir = char(dataDir);

p = inputParser;
p.addParameter('Product', 'PVOL', @(x) ischar(x) || isstring(x));
p.addParameter('MaxFrames', Inf, @(x) isnumeric(x) && isscalar(x));
p.addParameter('UseCache', true, @(x) islogical(x) || isnumeric(x));
p.addParameter('CacheFile', '', @(x) ischar(x) || isstring(x));
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;
wantProduct = upper(char(o.Product));
verbose = logical(o.Verbose);

cacheFile = char(o.CacheFile);
if isempty(cacheFile), cacheFile = fullfile(dataDir, 'feature_cache.mat'); end

if ~isfolder(dataDir)
    error('TIMRadar:NoDataDir', 'Folderul de date nu exista: %s', dataDir);
end
d = dir(fullfile(dataDir, 'TIM_*dBZ.hdf'));
if isempty(d)
    error('TIMRadar:NoFiles', ...
        ['Niciun fisier TIM_*dBZ.hdf in %s. Ruleaza w1_sync_archive() pentru a ' ...
         'descarca arhiva.'], dataDir);
end
[~, ord] = sort({d.name});
d = d(ord);
if isfinite(o.MaxFrames) && numel(d) > o.MaxFrames
    d = d(end - round(o.MaxFrames) + 1:end);     % cele mai recente cadre
end

% ---------------------------------------------------------------------
% Cache
% ---------------------------------------------------------------------
cache = struct('name', {{}}, 'bytes', [], 'stats', struct([]), ...
               'timestamp', datetime.empty(0, 1), 'product', {{}});
if logical(o.UseCache) && isfile(cacheFile)
    try
        L = load(cacheFile, 'cache');
        if isfield(L, 'cache') && isfield(L.cache, 'name')
            cache = L.cache;
        end
    catch
        warning('TIMRadar:BadCache', 'Cache invalid (%s), se reconstruieste.', cacheFile);
    end
end

nFiles = numel(d);
statsAll = cell(nFiles, 1);
tsAll = NaT(nFiles, 1);
prodAll = strings(nFiles, 1);
okAll = false(nFiles, 1);

nHit = 0;
nNew = 0;
nTried = 0;
isNew = false(nFiles, 1);
t0 = tic;
for k = 1:nFiles
    name = d(k).name;
    hit = find(strcmp(cache.name(:).', name) & cache.bytes(:).' == d(k).bytes, 1);
    if ~isempty(hit)
        statsAll{k} = cache.stats(hit);
        tsAll(k)    = cache.timestamp(hit);
        prodAll(k)  = string(cache.product{hit});
        okAll(k)    = true;
        nHit = nHit + 1;
        continue;
    end
    try
        [statsAll{k}, tsAll(k), prodAll(k)] = frame_stats(fullfile(dataDir, name));
        okAll(k)    = true;
        isNew(k)    = true;                      % de adaugat in cache
        nNew = nNew + 1;
    catch ME
        % Un TODO neterminat in w2 nu este un cadru stricat: se opreste imediat,
        % altfel fiecare cadru ar fi ignorat cu un avertisment si eroarea finala
        % ar spune doar ca nu exista niciun cadru utilizabil.
        if strcmp(ME.identifier, 'TIMRadar:TODO'), rethrow(ME); end
        warning('TIMRadar:FrameFailed', 'Cadrul %s a fost ignorat: %s', name, ME.message);
    end
    nTried = nTried + 1;
    if verbose && mod(nTried, 100) == 0
        fprintf('   [cache] %d cadre noi procesate (%.0fs)...\n', nTried, toc(t0));
    end
end

% Un cache scris cu alt set de statistici (w2 modificat intre timp) nu se poate
% combina cu cadrele noi: intrarile lui se recalculeaza chiar in aceasta rulare,
% altfel concatenarea structurilor de mai jos ar esua.
firstNew = find(isNew, 1);
if ~isempty(firstNew) && nHit > 0 && ...
        ~isequal(sort(fieldnames(statsAll{firstNew})), sort(fieldnames(cache.stats)))
    warning('TIMRadar:CacheSchema', ...
        'Setul de statistici s-a schimbat; %d cadre din cache se recalculeaza.', nHit);
    for k = find(okAll & ~isNew).'
        try
            [statsAll{k}, tsAll(k), prodAll(k)] = frame_stats(fullfile(dataDir, d(k).name));
            isNew(k) = true;
        catch ME
            okAll(k) = false;
            warning('TIMRadar:FrameFailed', 'Cadrul %s a fost ignorat: %s', d(k).name, ME.message);
        end
    end
    nNew = nNew + nHit;
    nTried = nTried + nHit;
    nHit = 0;
end

if verbose && nTried > 0
    fprintf('   [cache] %d din cache, %d procesate acum (%.0fs)\n', nHit, nTried, toc(t0));
elseif verbose
    fprintf('   [cache] %d cadre citite din cache\n', nHit);
end

% ---------------------------------------------------------------------
% Rescrierea cache-ului ADAUGA cadrele noi peste cele deja memorate.
%
% Cu 'MaxFrames' (teste, rulari rapide) `d` contine doar ultimele N cadre;
% un cache reconstruit doar din `d` ar sterge statisticile restului arhivei,
% iar recalcularea dureaza ~6 minute. Se face deci o reuniune: intrarile
% existente raman, cele noi se adauga, iar un fisier al carui numar de octeti
% s-a schimbat este inlocuit.
% ---------------------------------------------------------------------
if logical(o.UseCache) && nNew > 0
    newIdx = find(isNew);
    newNames = {d(newIdx).name};
    newStats = [statsAll{newIdx}];

    if isempty(cache.name)
        oldKeep = [];
    else
        oldKeep = find(~ismember(cache.name(:).', newNames));
        % Daca setul de statistici s-a schimbat intre timp (de ex. s-a adaugat
        % p99), intrarile vechi nu se mai pot concatena cu cele noi: se lasa
        % deoparte si vor fi recalculate la urmatoarea rulare.
        if ~isempty(oldKeep) && ~isequal(sort(fieldnames(cache.stats)), sort(fieldnames(newStats)))
            warning('TIMRadar:CacheSchema', ...
                'Setul de statistici s-a schimbat; intrarile vechi din cache se recalculeaza.');
            oldKeep = [];
        end
    end

    if isempty(oldKeep)
        mergedNames = reshape(newNames, 1, []);
        mergedBytes = reshape([d(newIdx).bytes], 1, []);
        mergedStats = reshape(newStats, 1, []);
        mergedTs    = reshape(tsAll(newIdx), [], 1);
        mergedProd  = reshape(cellstr(prodAll(newIdx)), 1, []);
    else
        % orderfields peste ambele parti: aceeasi ordine de campuri, altfel
        % concatenarea structurilor esueaza.
        oldStats    = orderfields(cache.stats(oldKeep));
        mergedNames = [reshape(cache.name(oldKeep), 1, []), reshape(newNames, 1, [])];
        mergedBytes = [reshape(cache.bytes(oldKeep), 1, []), reshape([d(newIdx).bytes], 1, [])];
        mergedStats = [reshape(oldStats, 1, []), reshape(orderfields(newStats), 1, [])];
        mergedTs    = [reshape(cache.timestamp(oldKeep), [], 1); reshape(tsAll(newIdx), [], 1)];
        mergedProd  = [reshape(cellstr(string(cache.product(oldKeep))), 1, []), ...
                       reshape(cellstr(prodAll(newIdx)), 1, [])];
    end

    cache = struct( ...
        'name',      {mergedNames}, ...
        'bytes',     mergedBytes, ...
        'stats',     mergedStats, ...
        'timestamp', mergedTs, ...
        'product',   {mergedProd});
    try
        save(cacheFile, 'cache');
    catch ME
        warning('TIMRadar:CacheWrite', 'Cache-ul nu a putut fi salvat: %s', ME.message);
    end
end

% ---------------------------------------------------------------------
% Filtrare pe produs, sortare cronologica, construirea tabelului
% ---------------------------------------------------------------------
sel = okAll;
excluded = 0;
if ~strcmpi(wantProduct, 'ALL')
    isWanted = sel & (prodAll == string(wantProduct));
    excluded = sum(sel & ~isWanted);
    sel = isWanted;
end
if ~any(sel)
    error('TIMRadar:NoUsableFrames', ...
        'Niciun cadru de tip %s in %s.', wantProduct, dataDir);
end

selCell = statsAll(sel);
statsSel = [selCell{:}]';
tsSel = tsAll(sel);
prodSel = prodAll(sel);
namesSel = {d(sel).name}';

[tsSel, ord] = sort(tsSel);
statsSel = statsSel(ord);
prodSel = prodSel(ord);
namesSel = namesSel(ord);

fn = fieldnames(statsSel);
T = table(tsSel, prodSel, string(namesSel), 'VariableNames', {'timestamp', 'product', 'file'});
for i = 1:numel(fn)
    T.(fn{i}) = arrayfun(@(s) double(s.(fn{i})), statsSel);
end

dts = minutes(diff(tsSel));
if isempty(dts)
    stepMin = 5;
else
    stepMin = mode(dts);
    if stepMin <= 0, stepMin = 5; end
end

meta = struct( ...
    'stepMinutes', stepMin, ...
    'nFiles', nFiles, ...
    'nUsed', height(T), ...
    'excludedByProduct', excluded, ...
    'product', wantProduct, ...
    'dataDir', dataDir, ...
    'dateRange', [min(tsSel), max(tsSel)], ...
    'gapsOverStep', sum(dts > stepMin * 1.5));

if verbose
    fprintf('   [w3] %d cadre %s, %s -> %s, pas %g min', meta.nUsed, wantProduct, ...
        string(meta.dateRange(1)), string(meta.dateRange(2)), stepMin);
    if excluded > 0
        fprintf(' (%d cadre de alt produs excluse)', excluded);
    end
    fprintf('\n');
end
end


% =====================================================================
function [st, ts, prod] = frame_stats(path)
% Statisticile unui cadru, in forma in care se pastreaza in cache.
F = radar_read_frame(path);
[~, st] = w2_clean_and_stats(F);
st = orderfields(rmfield(st, 'validMask'));  % masca nu se pastreaza in cache
ts = F.timestamp;
prod = string(F.product);
end

function F = radar_read_frame(filePath, varargin)
% RADAR_READ_FRAME Citire corecta a unui fisier ODIM HDF5 de la MeteoRomania (ANM).
%
% Sursa unica de adevar pentru citirea datelor radar.
%
% Reguli:
%   1. Calibrarea (gain/offset/nodata/undetect) este cautata in locul CORECT.
%      ODIM pune atributele in /datasetN/dataM/what pentru PVOL si in
%      /datasetN/what pentru produsele IMAGE.
%   2. Calibrarea citita din fisier se aplica intotdeauna; nu se ghiceste din
%      valori daca datele sunt brute.
%   3. Sweep-ul de elevatie este ales EXPLICIT dupa unghi (elangle), nu prin
%      accidentul ordonarii lexicografice a grupurilor HDF5
%      (/dataset1, /dataset10, /dataset11, /dataset12, /dataset2, ...).
%   4. Arhiva contine DOUA produse sub acelasi tipar de nume:
%        - PVOL  : volum polar, 12 elevatii, [920 x 360]  (majoritatea)
%        - IMAGE : PCAPPI cartezian 500 m, [700 x 700]    (cate unul la 23:55)
%      Ambele sunt citite corect si etichetate in F.product.
%   5. Pixelii polari NU au arie egala. F.areaWeight contine ponderea de arie
%      a fiecarui pixel, astfel incat mediile pe suprafata sa fie fizice.
%
% Semnatura:
%   F = radar_read_frame(filePath)
%   F = radar_read_frame(filePath, 'Elevation', 0.5, 'Quantity', 'DBZH')
%
% Optiuni (nume-valoare):
%   'Elevation' : unghi de elevatie dorit in grade (implicit: cel mai mic).
%                 Se alege sweep-ul cu elangle cel mai apropiat.
%   'Quantity'  : marimea ODIM asteptata (implicit 'DBZH').
%
% Iesire F (struct):
%   .dbz         [m x n] reflectivitate in dBZ. NaN unde nodata.
%   .validMask   [m x n] logical, true unde pixelul este in acoperirea radar
%   .echoMask    [m x n] logical, true unde s-a masurat ecou real
%   .areaWeight  [m x n] pondere de arie normalizata (suma = 1 pe validMask)
%   .rainRate    [m x n] mm/h prin Marshall-Palmer aplicat PE PIXEL
%   .timestamp   datetime cu valoarea in UTC a scanarii. NU are proprietatea
%                TimeZone setata (este un datetime "naiv"), pentru ca restul
%                lantului - radar_feature_table, w3 - lucreaza cu datetime fara
%                fus; amestecarea celor doua tipuri arunca eroare la comparatie.
%   .product     'PVOL' | 'IMAGE'
%   .quantity    marimea citita, ex. 'DBZH'
%   .geometry    struct cu descrierea geometriei (polara sau carteziana)
%   .calibration struct cu gain/offset/nodata/undetect si sursa lor

HAIL_CAP_DBZ = 53;      % plafon Z-R pentru ploaie (peste = grindina/clutter)
CLUTTER_DBZ  = 60;      % peste acest prag ecoul este aproape sigur nemeteo

p = inputParser;
p.addParameter('Elevation', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
p.addParameter('Quantity', 'DBZH', @(x) ischar(x) || isstring(x));
p.parse(varargin{:});
wantElev = p.Results.Elevation;
wantQty  = char(p.Results.Quantity);

if ~isfile(filePath)
    error('TIMRadar:FileNotFound', 'Fisierul nu exista: %s', filePath);
end

info = h5info(filePath);

% ---------------------------------------------------------------------
% 1. Tipul produsului si timestamp-ul, din /what
% ---------------------------------------------------------------------
rootWhat = attr_struct(filePath, '/what');
product = 'UNKNOWN';
if isfield(rootWhat, 'object'), product = upper(char(string(rootWhat.object))); end

F.timestamp = timestamp_from_name(filePath);
if isnat(F.timestamp) && isfield(rootWhat, 'date') && isfield(rootWhat, 'time')
    % Parsarea de rezerva nu are voie sa arunce. Un fisier al carui nume nu
    % respecta tiparul TIM_<12 cifre> SI ale carui atribute /what/date,time nu
    % sunt exact yyyyMMdd + HHmmss primeste NaT, cu avertisment, ca un singur
    % fisier ciudat sa nu opreasca toata descarcarea din w1_download_radar.
    try
        F.timestamp = datetime([char(string(rootWhat.date)) char(string(rootWhat.time))], ...
            'InputFormat', 'yyyyMMddHHmmss');
    catch
        warning('TIMRadar:BadTimestamp', ...
            ['Nu s-a putut interpreta data/ora din %s (nici din nume, nici din ' ...
             '/what). Cadrul primeste timestamp NaT.'], filePath);
        F.timestamp = NaT;
    end
end

% ---------------------------------------------------------------------
% 2. Alegerea sweep-ului: EXPLICIT dupa elangle, nu dupa ordinea grupurilor
% ---------------------------------------------------------------------
dsNames = {};
for i = 1:numel(info.Groups)
    nm = info.Groups(i).Name;
    if ~isempty(regexp(nm, '^/dataset\d+$', 'once'))
        dsNames{end+1} = nm; %#ok<AGROW>
    end
end
if isempty(dsNames)
    error('TIMRadar:NoDataset', 'Niciun grup /datasetN in %s', filePath);
end

% Sortare NUMERICA (dataset2 inaintea lui dataset10), nu lexicografica
dsIdx = zeros(1, numel(dsNames));
for i = 1:numel(dsNames)
    dsIdx(i) = sscanf(dsNames{i}, '/dataset%d');
end
[~, ord] = sort(dsIdx);
dsNames = dsNames(ord);

elangles = nan(1, numel(dsNames));
for i = 1:numel(dsNames)
    w = attr_struct(filePath, [dsNames{i} '/where']);
    if isfield(w, 'elangle'), elangles(i) = double(w.elangle); end
end

if all(isnan(elangles))
    pick = 1;                                  % produs IMAGE: un singur strat
elseif isempty(wantElev)
    [~, pick] = min(elangles);                 % implicit: cea mai joasa elevatie
else
    [~, pick] = min(abs(elangles - wantElev));
end
dsRoot = dsNames{pick};

% ---------------------------------------------------------------------
% 3. Stratul de date si calibrarea, cautate in ordinea corecta ODIM
% ---------------------------------------------------------------------
[dataPath, calWhatPath] = locate_data_layer(filePath, dsRoot, wantQty);

cal = attr_struct(filePath, calWhatPath);
calSource = calWhatPath;
if ~isfield(cal, 'gain') || ~isfield(cal, 'offset')
    % ODIM permite atributele si la nivelul dataset-ului (produse IMAGE)
    calAlt = attr_struct(filePath, [dsRoot '/what']);
    if isfield(calAlt, 'gain') && isfield(calAlt, 'offset')
        cal = calAlt;
        calSource = [dsRoot '/what'];
    end
end

if isfield(cal, 'gain') && isfield(cal, 'offset')
    gain = double(cal.gain);
    offset = double(cal.offset);
else
    % Nu se ghiceste in tacere: se anunta explicit.
    gain = 0.5;
    offset = -32;
    calSource = 'implicit ODIM (NEGASIT IN FISIER)';
    warning('TIMRadar:MissingCalibration', ...
        ['Fisierul %s nu contine gain/offset. Se folosesc valorile ODIM implicite ' ...
         '(gain=0.5, offset=-32). Valorile fizice pot fi incorecte.'], filePath);
end
nodata   = double(getfield_default(cal, 'nodata', 255));
undetect = double(getfield_default(cal, 'undetect', 0));

quantity = char(string(getfield_default(cal, 'quantity', wantQty)));
if ~strcmpi(quantity, wantQty)
    warning('TIMRadar:UnexpectedQuantity', ...
        'Fisierul %s contine marimea %s, nu %s.', filePath, quantity, wantQty);
end

% ---------------------------------------------------------------------
% 4. Citire si conversie fizica (fara euristici)
% ---------------------------------------------------------------------
raw = double(h5read(filePath, dataPath));
raw = squeeze(raw);
if ~ismatrix(raw)
    error('TIMRadar:NotMatrix', 'Dataset-ul %s din %s nu este 2D.', dataPath, filePath);
end

nodataMask   = (raw == nodata);
undetectMask = (raw == undetect);
validMask    = ~nodataMask;
echoMask     = validMask & ~undetectMask;

dbz = raw * gain + offset;
noEchoDbz = offset;                 % cel mai mic dBZ reprezentabil de scala
dbz(undetectMask) = noEchoDbz;
dbz(nodataMask)   = NaN;

% Marshall-Palmer aplicat PE PIXEL (Z = 200 R^1.6), nu pe o percentila de dBZ.
%
% PLAFON DE GRINDINA: relatia Z-R este valabila pentru ploaie. Peste ~53 dBZ
% ecoul provine din grindina sau din tinte nemeteorologice, iar Z-R produce
% valori absurde (mediana lui max(R) pe arhiva reala ar fi ~2050 mm/h).
% Plafonarea la 53 dBZ (practica operationala standard pentru QPE) limiteaza
% intensitatea punctuala la ~75 mm/h.
dbzForRain = min(dbz, HAIL_CAP_DBZ);
rainRate = zeros(size(dbz));
rainRate(echoMask) = (10 .^ (dbzForRain(echoMask) / 10) / 200) .^ (1 / 1.6);
rainRate(nodataMask) = NaN;

% ---------------------------------------------------------------------
% 5. Geometrie si ponderi de arie
% ---------------------------------------------------------------------
[areaWeight, geometry] = area_weights(filePath, dsRoot, product, size(raw), validMask);

F.dbz         = dbz;
F.noEchoDbz   = noEchoDbz;
F.validMask   = validMask;
F.echoMask    = echoMask;
F.areaWeight  = areaWeight;
F.rainRate    = rainRate;
F.product     = product;
F.quantity    = quantity;
F.geometry    = geometry;
F.calibration = struct('gain', gain, 'offset', offset, 'nodata', nodata, ...
                       'undetect', undetect, 'source', calSource);
F.hailCapDbz  = HAIL_CAP_DBZ;
F.clutterDbz  = CLUTTER_DBZ;
F.clutterMask = echoMask & (dbz > CLUTTER_DBZ);
F.filePath    = filePath;
F.dataPath    = dataPath;
F.elevation   = elangles(pick);
end

% =====================================================================
function [dataPath, whatPath] = locate_data_layer(filePath, dsRoot, wantQty)
% Alege /datasetN/dataM care contine marimea ceruta; implicit primul strat.
di = h5info(filePath, dsRoot);
dataGroups = {};
for i = 1:numel(di.Groups)
    nm = di.Groups(i).Name;
    if ~isempty(regexp(nm, '/data\d+$', 'once'))
        dataGroups{end+1} = nm; %#ok<AGROW>
    end
end

if isempty(dataGroups)
    % Produs IMAGE fara subgrup dataM: dataset-ul este direct sub /datasetN
    if ~isempty(di.Datasets)
        dataPath = [dsRoot '/' di.Datasets(1).Name];
        whatPath = [dsRoot '/what'];
        return;
    end
    error('TIMRadar:NoDataLayer', 'Niciun strat de date in %s din %s', dsRoot, filePath);
end

gi = zeros(1, numel(dataGroups));
for i = 1:numel(dataGroups)
    tok = regexp(dataGroups{i}, '/data(\d+)$', 'tokens', 'once');
    gi(i) = str2double(tok{1});
end
[~, ord] = sort(gi);
dataGroups = dataGroups(ord);

chosen = dataGroups{1};
for i = 1:numel(dataGroups)
    a = attr_struct(filePath, [dataGroups{i} '/what']);
    if isfield(a, 'quantity') && strcmpi(char(string(a.quantity)), wantQty)
        chosen = dataGroups{i};
        break;
    end
end
dataPath = [chosen '/data'];
whatPath = [chosen '/what'];
end

% =====================================================================
function [W, geom] = area_weights(filePath, dsRoot, product, sz, validMask)
% Ponderi de arie normalizate. Pixelii polari cresc in arie cu distanta.
wh = attr_struct(filePath, [dsRoot '/where']);
rootWhere = attr_struct(filePath, '/where');

if isfield(wh, 'rscale') && isfield(wh, 'nbins')
    % --- Geometrie POLARA: [nbins x nrays] ---
    rscale = double(wh.rscale);
    % ATENTIE LA UNITATI: in ODIM_H5, `rscale` este in METRI, dar `rstart` este
    % in KILOMETRI. Standardul chiar este inconsecvent aici. Adunate direct, ar
    % muta inelele cu rstart*999 m spre radar si ar strica `areaWeight` si
    % `maxRangeKm` pentru orice statie cu zona oarba (rstart != 0). Pe TIM
    % rstart = 0, dar conversia ramane corecta si la o schimbare de configuratie.
    rstart = double(getfield_default(wh, 'rstart', 0)) * 1000;   % km -> m
    nbins  = sz(1);
    nrays  = sz(2);

    % Ponderile de arie depind de faptul ca randurile sunt bin-uri de distanta
    % si coloanele azimuturi. Daca vreodata h5read returneaza matricea
    % transpusa, mediile ponderate ies gresite fara niciun semn vizibil:
    % inelele departate (arie mare) ar fi tratate drept azimuturi. Se verifica
    % explicit fata de atributele din fisier.
    declBins = double(getfield_default(wh, 'nbins', nbins));
    declRays = double(getfield_default(wh, 'nrays', nrays));
    if nbins ~= declBins || nrays ~= declRays
        warning('TIMRadar:PolarOrientation', ...
            ['Dimensiunea datelor [%d x %d] nu se potriveste cu nbins=%g, nrays=%g ' ...
             'din %s/where. Ponderile de arie pot fi calculate pe axa gresita.'], ...
            nbins, nrays, declBins, declRays, dsRoot);
    end
    i = (1:nbins)';
    rIn  = rstart + (i - 1) * rscale;
    rOut = rstart + i * rscale;
    ringArea = rOut.^2 - rIn.^2;            % proportional cu aria segmentului
    W = repmat(ringArea, 1, nrays);
    geom = struct('type', 'polar', 'rscale', rscale, 'rstart', rstart, ...
                  'nbins', nbins, 'nrays', nrays, ...
                  'elangle', double(getfield_default(wh, 'elangle', NaN)), ...
                  'lat', double(getfield_default(rootWhere, 'lat', NaN)), ...
                  'lon', double(getfield_default(rootWhere, 'lon', NaN)), ...
                  'maxRangeKm', rOut(end) / 1000);
elseif isfield(rootWhere, 'xscale') && isfield(rootWhere, 'yscale')
    % --- Geometrie CARTEZIANA (PCAPPI): pixeli de arie egala ---
    W = ones(sz);
    geom = struct('type', 'cartesian', ...
                  'xscale', double(rootWhere.xscale), ...
                  'yscale', double(rootWhere.yscale), ...
                  'xsize', sz(2), 'ysize', sz(1), ...
                  'projdef', char(string(getfield_default(rootWhere, 'projdef', ''))), ...
                  'lat', double(getfield_default(rootWhere, 'lat', NaN)), ...
                  'lon', double(getfield_default(rootWhere, 'lon', NaN)));
else
    W = ones(sz);
    geom = struct('type', 'unknown');
end
geom.product = product;

W(~validMask) = 0;
s = sum(W(:));
if s > 0, W = W / s; end
end

% =====================================================================
function s = attr_struct(filePath, loc)
s = struct();
try
    info = h5info(filePath, loc);
catch
    return;
end
for a = 1:numel(info.Attributes)
    at = info.Attributes(a);
    v = at.Value;
    if iscell(v) && ~isempty(v), v = v{1}; end
    s.(matlab.lang.makeValidName(at.Name)) = v;
end
end

% =====================================================================
function v = getfield_default(s, name, dflt)
if isstruct(s) && isfield(s, name), v = s.(name); else, v = dflt; end
end

% =====================================================================
function ts = timestamp_from_name(filePath)
[~, base] = fileparts(filePath);
t = regexp(base, 'TIM_(\d{12})', 'tokens', 'once');
if isempty(t)
    ts = NaT;
else
    ts = datetime(t{1}, 'InputFormat', 'yyyyMMddHHmm');
end
end

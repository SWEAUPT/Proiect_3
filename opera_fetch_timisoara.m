function report = opera_fetch_timisoara(varargin)
% OPERA_FETCH_TIMISOARA Arhiva compozitului radar european OPERA, decupata pe Timisoara.
%
% Arhiva TIM de la ANM are o fereastra rulanta de ~3.5 zile si goluri
% permanente. EUMETNET OPERA publica deschis compozitul radar european
% (inclusiv zona Timisoarei) din 2012 incoace. De la 1 iulie 2024 formatul
% este OMOGEN - verificat luna de luna pana in octombrie 2026: ODIM 2.4,
% grila 3800 x 4400 la 1 km, aceeasi proiectie LAEA, aceeasi calibrare,
% 288 de cadre DBZH pe zi. Inainte de iulie 2024 grila era de 2 km, deci
% perioada implicita incepe acolo.
%
% ESTE UN ALT PRODUS decat radarul TIM: compozit multi-radar, cu control de
% calitate (clutter eliminat), pe grila carteziana. La 2026-09-12 12:00, in
% 160 km in jurul Timisoarei, OPERA arata ecou pe 5% (max 43 dBZ), iar
% sweep-ul TIM de 0.5 grade 9% (max 59.5 dBZ). Nu se amesteca cadru cu cadru
% cu arhiva din data/; este un set de date separat si coerent cu sine.
%
% Se citeste DOAR decupajul, direct de pe server (h5read pe HTTPS cu start/
% count): fisierul este stocat in blocuri de 880 x 760 comprimate, deci un
% decupaj de 600 x 600 atinge cel mult 4 din 25. Verificat: decupajul citit de
% la distanta este identic bit cu bit cu decupajul fisierului descarcat
% complet. Viteza masurata: ~4.4 cadre/s cu 24 de procese (limitata de retea).
%
% Utilizare:
%   opera_fetch_timisoara()                                 % 2024-07-01 -> azi
%   opera_fetch_timisoara('Start', datetime(2026,8,26), 'End', datetime(2026,8,29))
%
% Optiuni:
%   'Start', 'End'   zile (implicit 2024-07-01 si ziua de ieri)
%   'OutDir'         implicit <proiect>/data_opera
%   'HalfWidthKm'    jumatate din latura decupajului (implicit 300 -> 600 x 600 km)
%   'Workers'        procese paralele (implicit 24)
%
% RELUARE: ziua care are deja fisier complet se sare. Oprirea (Ctrl+C sau
% inchiderea MATLAB) pierde cel mult ziua in lucru. Fiecare zi adauga o
% linie in <OutDir>/fetch_log.txt.
%
% Fisier pe zi: OPERA_TIM_<yyyyMMdd>.mat cu
%   q          uint8 [ny x nx x 288]: 0 = fara ecou (undetect), 255 = fara date
%              (nodata, inclusiv cadru lipsa), altfel dBZ = q * 0.5 - 32
%              randul 1 = nord, coloana 1 = vest
%   timestamps datetime [288 x 1], UTC (naiv, ca in restul proiectului)
%   present    logical [288 x 1], false = cadrul nu exista pe server
%   georef     struct: proiectia, indicii decupajului in grila OPERA, coordonatele
%              LAEA ale centrelor de celule, centrul (Timisoara)

p = inputParser;
p.addParameter('Start', datetime(2024, 7, 1), @(x) isdatetime(x));
p.addParameter('End', dateshift(datetime('now'), 'start', 'day') - days(1), @(x) isdatetime(x));
p.addParameter('OutDir', fullfile(fileparts(mfilename('fullpath')), 'data_opera'), @(x) ischar(x) || isstring(x));
p.addParameter('HalfWidthKm', 300, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('Workers', 24, @(x) isnumeric(x) && isscalar(x) && x >= 1);
p.parse(varargin{:});
o = p.Results;
outDir = char(o.OutDir);
if ~isfolder(outDir), mkdir(outDir); end

BASE = 'https://s3.waw3-1.cloudferro.com/openradar-archive/';
TIM_LAT = 45.7717; TIM_LON = 21.2577;          % radarul TIM (din /where)
FORMAT_SINCE = datetime(2024, 7, 1);
if o.Start < FORMAT_SINCE
    warning('TIMRadar:OperaFormat', ['Inainte de 2024-07-01 grila OPERA este de 2 km si ' ...
        'alt format ODIM; decupajul de mai jos presupune grila de 1 km.']);
end

% ---------------------------------------------------------------------
% Georeferinta decupajului, din atributele unui cadru real
% ---------------------------------------------------------------------
ref = sprintf('%s%s/OPERA/COMP/OPERA@%s@0@DBZH.h5', BASE, ...
    char(o.Start, 'yyyy/MM/dd'), char(o.Start + hours(12), 'yyyyMMdd''T''HHmm'));
w = h5attrs(ref, '/where');
q0 = h5attrs(ref, '/dataset1/data1/what');
[xT, yT] = laea_wgs84(TIM_LAT, TIM_LON, char(w.projdef));
[xUL, yUL] = laea_wgs84(double(w.UL_lat), double(w.UL_lon), char(w.projdef));
s = double(w.xscale);
ix = floor((xT - xUL) / s) + 1;                  % coloana (vest -> est) a Timisoarei
iy = floor((yUL - yT) / s) + 1;                  % randul (nord -> sud)
hw = round(o.HalfWidthKm * 1000 / s);
start = [ix - hw, iy - hw];                      % ordinea dimensiunilor din h5read: [x y]
count = [2 * hw, 2 * hw];
georef = struct('projdef', char(w.projdef), 'gridSize', [double(w.xsize) double(w.ysize)], ...
    'cellMeters', s, 'startXY', start, 'countXY', count, ...
    'xCenters', xUL + ((start(1):start(1) + count(1) - 1) - 0.5) * s, ...
    'yCenters', yUL - ((start(2):start(2) + count(2) - 1) - 0.5) * s, ...
    'centerLatLon', [TIM_LAT TIM_LON], 'centerXY', [xT yT], ...
    'nodata', double(q0.nodata), 'undetect', double(q0.undetect), ...
    'source', 'EUMETNET OPERA composite DBZH, openradar-archive (CloudFerro S3)', ...
    'quantization', 'dBZ = q*0.5 - 32; 0 = undetect; 255 = nodata/missing');

% ---------------------------------------------------------------------
% Pool paralel
% ---------------------------------------------------------------------
pool = gcp('nocreate');
if isempty(pool) || pool.NumWorkers ~= o.Workers
    delete(pool);
    c = parcluster('local');
    c.NumWorkers = max(c.NumWorkers, o.Workers);
    parpool(c, o.Workers);
end

logFile = fullfile(outDir, 'fetch_log.txt');
daysList = dateshift(o.Start, 'start', 'day'):caldays(1):dateshift(o.End, 'start', 'day');
report = struct('days', numel(daysList), 'skipped', 0, 'fetched', 0, 'framesMissing', 0);
nodataV = georef.nodata; undetV = georef.undetect;

for d = daysList
    outFile = fullfile(outDir, sprintf('OPERA_TIM_%s.mat', char(d, 'yyyyMMdd')));
    if isfile(outFile)
        report.skipped = report.skipped + 1;
        continue;
    end
    t0 = tic;
    timestamps = (d + minutes(5 * (0:287)))';
    urls = arrayfun(@(t) sprintf('%s%s/OPERA/COMP/OPERA@%s@0@DBZH.h5', BASE, ...
        char(t, 'yyyy/MM/dd'), char(t, 'yyyyMMdd''T''HHmm')), timestamps, 'UniformOutput', false);
    q = repmat(uint8(255), count(2), count(1), numel(urls));
    present = false(numel(urls), 1);
    parfor k = 1:numel(urls)
        [q(:, :, k), present(k)] = fetch_one(urls{k}, start, count, nodataV, undetV);
    end
    tmp = [outFile '.part'];
    save(tmp, 'q', 'timestamps', 'present', 'georef', '-v7.3');
    movefile(tmp, outFile, 'f');                 % fisierul apare doar complet
    nMiss = sum(~present);
    report.fetched = report.fetched + 1;
    report.framesMissing = report.framesMissing + nMiss;
    line = sprintf('%s  %s  frames=%3d  missing=%3d  %.0fs', ...
        char(datetime('now'), 'yyyy-MM-dd HH:mm:ss'), char(d, 'yyyy-MM-dd'), ...
        sum(present), nMiss, toc(t0));
    fprintf('%s\n', line);
    fid = fopen(logFile, 'a');
    if fid > 0, fprintf(fid, '%s\n', line); fclose(fid); end
end
end

% =====================================================================
function [qq, ok] = fetch_one(url, start, count, nodataV, undetV)
% Un cadru: citire partiala de la distanta, cu doua reincercari.
qq = repmat(uint8(255), count(2), count(1));
ok = false;
for attempt = 1:3
    try
        x = h5read(url, '/dataset1/data1/data', start, count);   % [x y]
        x = double(x.');                                          % [y x], randul 1 = nord
        v = uint8(min(254, max(1, round((x + 32) / 0.5))));
        v(x == undetV) = 0;
        v(x == nodataV | ~isfinite(x)) = 255;
        qq = v;
        ok = true;
        return;
    catch ME
        if contains(ME.message, {'not found', 'Unable to open'}) && attempt >= 2
            return;                              % cadrul lipseste de pe server
        end
        pause(2 * attempt);
    end
end
end

% =====================================================================
function s = h5attrs(file, loc)
s = struct();
i = h5info(file, loc);
for a = i.Attributes'
    v = a.Value; if iscell(v), v = v{1}; end
    s.(matlab.lang.makeValidName(a.Name)) = v;
end
end

% =====================================================================
function [x, y] = laea_wgs84(lat, lon, projdef)
% Lambert Azimuthal Equal-Area pe elipsoidul WGS84 (Snyder 1987, ec. 3-12,
% 24-27). projcrs din Mapping Toolbox nu accepta un sir PROJ, deci formulele
% sunt scrise explicit. Fara false easting: grila se calculeaza relativ la
% coltul UL, proiectat cu aceeasi functie.
lat0 = str2double(regexp(projdef, 'lat_0=([-\d.]+)', 'tokens', 'once'));
lon0 = str2double(regexp(projdef, 'lon_0=([-\d.]+)', 'tokens', 'once'));
a = 6378137; f = 1 / 298.257223563; e = sqrt(2 * f - f^2);
qf = @(ph) (1 - e^2) * (sind(ph) ./ (1 - e^2 * sind(ph).^2) - ...
     1 / (2 * e) * log((1 - e * sind(ph)) ./ (1 + e * sind(ph))));
qp = qf(90);
Rq = a * sqrt(qp / 2);
b1 = asin(qf(lat0) / qp);
b  = asin(qf(lat) / qp);
D = a * (cosd(lat0) / sqrt(1 - e^2 * sind(lat0)^2)) / (Rq * cos(b1));
B = Rq * sqrt(2 ./ (1 + sin(b1) * sin(b) + cos(b1) * cos(b) .* cosd(lon - lon0)));
x = B * D .* cos(b) .* sind(lon - lon0);
y = (B / D) .* (cos(b1) * sin(b) - sin(b1) * cos(b) .* cosd(lon - lon0));
end

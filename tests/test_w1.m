function tests = test_w1
% Teste Saptamana 1: citirea corecta a fisierelor ODIM HDF5.
%
% Testele nu ating reteaua. Testul de descarcare este marcat ca netrecut doar
% daca serverul chiar raspunde gresit; daca nu exista conexiune, este sarit,
% ca suita sa ruleze si pe o masina offline.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
testCase.TestData.root = fileparts(fileparts(mfilename('fullpath')));
addpath(testCase.TestData.root);
d = dir(fullfile(testCase.TestData.root, 'data', 'TIM_*dBZ.hdf'));
assumeNotEmpty(testCase, d, 'Nu exista cadre locale in data/ pentru testare.');
[~, ord] = sort({d.name});
d = d(ord);
testCase.TestData.file = fullfile(testCase.TestData.root, 'data', d(end).name);

% Cel mai recent cadru PVOL, ales EXPLICIT dupa produs.
%
% Arhiva contine si cadre IMAGE (unul zilnic la 23:55, plus serii ocazionale
% in timpul zilei), deci "ultimul fisier" nu este mereu PVOL. Se cauta cate un
% cadru din fiecare produs, de la coada spre inceput, iar testele care au
% nevoie de unul anume il cer explicit - altfel un test conditionat de produs
% ar putea trece VERDE fara nicio asertiune.
pvol = '';
image = '';
for i = numel(d):-1:1
    f = fullfile(testCase.TestData.root, 'data', d(i).name);
    try
        prod = h5readatt(f, '/what', 'object');
    catch
        continue;
    end
    % ATENTIE: h5readatt pastreaza terminatorul NUL al sirului din HDF5
    % ('PVOL' vine ca [80 86 79 76 0]), in timp ce h5info - pe care il
    % foloseste radar_read_frame - il elimina. strtrim NU scoate NUL-ul, deci o
    % comparatie directa cu 'PVOL' eșuează silentios si nu se gaseste niciun
    % cadru. Se pastreaza doar caracterele alfanumerice.
    if iscell(prod), prod = prod{1}; end
    prod = upper(regexprep(char(prod(:).'), '[^A-Za-z0-9]', ''));
    if isempty(pvol) && strcmp(prod, 'PVOL')
        pvol = f;
    elseif isempty(image) && strcmp(prod, 'IMAGE')
        image = f;
    end
    if ~isempty(pvol) && ~isempty(image), break; end
end
testCase.TestData.pvolFile = pvol;
testCase.TestData.imageFile = image;
end

function testReadFrameContract(testCase)
F = radar_read_frame(testCase.TestData.file);

verifyTrue(testCase, ismatrix(F.dbz), 'dbz trebuie sa fie 2D.');
verifyTrue(testCase, isdatetime(F.timestamp), 'timestamp trebuie sa fie datetime.');
verifySize(testCase, F.validMask, size(F.dbz));
verifySize(testCase, F.echoMask, size(F.dbz));
verifySize(testCase, F.areaWeight, size(F.dbz));
verifySize(testCase, F.rainRate, size(F.dbz));
verifyGreaterThan(testCase, numel(F.dbz), 1000);

% Ponderile de arie trebuie sa insumeze 1 pe zona acoperita
verifyEqual(testCase, sum(F.areaWeight(:)), 1, 'AbsTol', 1e-9, ...
    'Ponderile de arie trebuie normalizate.');
verifyTrue(testCase, all(F.areaWeight(~F.validMask) == 0), ...
    'Pixelii din afara acoperirii trebuie sa aiba pondere zero.');
end

function testCalibrationComesFromFile(testCase)
% Calibrarea trebuie citita din fisier, nu ghicita. Pentru PVOL gain/offset
% stau in /datasetN/dataM/what, nu in /dataset1/what.
F = radar_read_frame(testCase.TestData.file);
verifyTrue(testCase, isfield(F.calibration, 'source'));
verifyFalse(testCase, contains(F.calibration.source, 'NEGASIT'), ...
    sprintf('Calibrarea nu a fost gasita in fisier (sursa: %s).', F.calibration.source));
verifyGreaterThan(testCase, F.calibration.gain, 0);
end

function testRainRateIsPhysicallyCapped(testCase)
% Fara plafon de grindina, Z-R producea mediane de ~2050 mm/h din ecouri
% nemeteorologice de 76+ dBZ.
F = radar_read_frame(testCase.TestData.file);
mx = max(F.rainRate(F.validMask));
verifyLessThan(testCase, mx, 100, ...
    'Intensitatea punctuala trebuie plafonata fizic (Z-R limitat la 53 dBZ).');
end

function testLowestElevationIsChosen(testCase)
% Sweep-ul trebuie ales dupa unghi, nu dupa ordinea lexicografica a grupurilor
% (/dataset1, /dataset10, /dataset11, /dataset12, /dataset2, ...).
assumeNotEmpty(testCase, testCase.TestData.pvolFile, 'Niciun cadru PVOL local.');
F = radar_read_frame(testCase.TestData.pvolFile);
verifyEqual(testCase, F.product, 'PVOL');
verifyEqual(testCase, F.elevation, 0.5, 'AbsTol', 0.01);

F2 = radar_read_frame(testCase.TestData.pvolFile, 'Elevation', 19.5);
verifyEqual(testCase, F2.elevation, 19.5, 'AbsTol', 0.01);
% Elevatiile diferite trebuie sa dea CAMPURI diferite; altfel s-ar putea citi
% mereu acelasi sweep si testul de unghi ar fi decorativ.
verifyFalse(testCase, isequal(F.dbz, F2.dbz), ...
    'Doua elevatii diferite nu pot produce exact acelasi camp.');
end

function testPolarGeometryMatchesTheFile(testCase)
% Ponderile de arie depind de faptul ca randurile sunt bin-uri de distanta si
% coloanele azimuturi. Nimic nu verifica asta fata de atributele din fisier.
assumeNotEmpty(testCase, testCase.TestData.pvolFile, 'Niciun cadru PVOL local.');
f = testCase.TestData.pvolFile;
F = radar_read_frame(f);

nbins = double(h5readatt(f, '/dataset1/where', 'nbins'));
nrays = double(h5readatt(f, '/dataset1/where', 'nrays'));
verifyEqual(testCase, size(F.dbz, 1), nbins, ...
    'Randurile trebuie sa fie bin-uri de distanta.');
verifyEqual(testCase, size(F.dbz, 2), nrays, ...
    'Coloanele trebuie sa fie azimuturi.');
verifyEqual(testCase, F.geometry.type, 'polar');

% Aria creste cu distanta: ponderea unui bin departat trebuie sa fie strict mai
% mare decat a unuia apropiat, pe acelasi azimut.
w = F.areaWeight;
az = find(any(F.validMask, 1), 1);
assumeNotEmpty(testCase, az);
verifyGreaterThan(testCase, w(end, az), w(1, az), ...
    'Pixelii polari departati acopera o arie mai mare, deci pondere mai mare.');
% ODIM: rscale in METRI, rstart in KILOMETRI. Testul include explicit rstart,
% ca sa nu ramana corect doar din cauza ca statia TIM are rstart = 0 - altfel
% o schimbare de configuratie a radarului ar trece nedetectata.
rscale = double(h5readatt(f, '/dataset1/where', 'rscale'));
try
    rstartKm = double(h5readatt(f, '/dataset1/where', 'rstart'));
catch
    rstartKm = 0;
end
verifyEqual(testCase, F.geometry.maxRangeKm, ...
    (rstartKm * 1000 + nbins * rscale) / 1000, 'RelTol', 1e-9);
verifyEqual(testCase, F.geometry.rstart, rstartKm * 1000, 'AbsTol', 1e-9, ...
    'geometry.rstart trebuie exprimat in metri, ca rscale.');
end

function testImageProductIsReadCorrectly(testCase)
% Produsul IMAGE (PCAPPI cartezian) are alta geometrie, alta dimensiune si
% calibrarea in alt loc (/datasetN/what in loc de /datasetN/dataM/what).
assumeNotEmpty(testCase, testCase.TestData.imageFile, ...
    'Niciun cadru IMAGE local (unul pe zi, la 23:55).');
F = radar_read_frame(testCase.TestData.imageFile);

verifyEqual(testCase, F.product, 'IMAGE');
verifyEqual(testCase, F.geometry.type, 'cartesian');
verifyTrue(testCase, isfield(F.geometry, 'xscale') && F.geometry.xscale > 0);
% Calibrarea trebuie citita din fisier, nu ghicita.
verifyFalse(testCase, contains(F.calibration.source, 'NEGASIT'), ...
    sprintf('Calibrare negasita pentru IMAGE (sursa: %s).', F.calibration.source));
verifyGreaterThan(testCase, F.calibration.gain, 0);

% Grila carteziana are pixeli de arie egala: ponderile trebuie sa fie constante
% pe zona acoperita si zero in afara ei.
wv = F.areaWeight(F.validMask);
verifyEqual(testCase, std(wv), 0, 'AbsTol', 1e-15, ...
    'Pixelii cartezieni au arie egala, deci pondere identica.');
verifyEqual(testCase, sum(F.areaWeight(:)), 1, 'AbsTol', 1e-9);
verifyTrue(testCase, all(F.areaWeight(~F.validMask) == 0));
% Statisticile pe acest produs se verifica in test_w2 (testImageProductStats),
% ca saptamana 1 sa poata trece inainte de a scrie w2_clean_and_stats.
end

function testLocalOnlyDownload(testCase)
root = testCase.TestData.root;
[frames, ts, paths] = w1_download_radar(2, 'LocalOnly', true, ...
    'DataDir', fullfile(root, 'data'));
verifyEqual(testCase, numel(frames), 2);
verifyEqual(testCase, numel(ts), 2);
verifyEqual(testCase, numel(paths), 2);
verifyTrue(testCase, all(isfile(paths)));
% Strict, nu >=: doua cadre distincte nu pot avea acelasi timestamp, iar cu >=
% testul ar trece si daca acelasi fisier ar fi returnat de doua ori.
verifyGreaterThan(testCase, ts(1), ts(2), ...
    'Cadrele trebuie returnate cu cel mai recent primul, si sa fie distincte.');
end

function testSingleFrameShape(testCase)
root = testCase.TestData.root;
[m, ts, fpath] = w1_download_radar(1, 'LocalOnly', true, 'DataDir', fullfile(root, 'data'));
verifyTrue(testCase, isnumeric(m) && ismatrix(m), 'Pentru un cadru se returneaza o matrice.');
verifyTrue(testCase, isdatetime(ts));
verifyTrue(testCase, ischar(fpath) || isstring(fpath));
end

function tests = test_w3
% Teste Saptamana 3: setul de date de prognoza.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
testCase.TestData.root = root;
testCase.TestData.dataDir = fullfile(root, 'data');
assumeNotEmpty(testCase, dir(fullfile(testCase.TestData.dataDir, 'TIM_*dBZ.hdf')));
testCase.TestData.args = {'DataDir', testCase.TestData.dataDir, ...
    'MaxFrames', 260, 'HistoryFrames', 6, 'Verbose', false};
end

function testVariantBContract(testCase)
[X, y, fn, ti] = w3_extract_features('B', testCase.TestData.args{:});
verifyEqual(testCase, size(X, 1), numel(y));
verifyEqual(testCase, numel(fn), size(X, 2));
verifyEqual(testCase, ti.type, 'regression');
verifyEqual(testCase, ti.unit, 'mm/h');
verifyTrue(testCase, all(y >= 0), 'Intensitatea ploii nu poate fi negativa.');
end

function testVariantAClasses(testCase)
[~, y, ~, ti] = w3_extract_features('A', testCase.TestData.args{:});
verifyEqual(testCase, ti.type, 'classification');
verifyTrue(testCase, all(ismember(y, [1 2 3 4])));
verifyEqual(testCase, numel(ti.classNames), 4);
% all(ismember(...)) trece si daca TOATE esantioanele sunt clasa 1, deci se
% cere explicit mai mult de o clasa.
assumeGreaterThan(testCase, numel(y), 40);
verifyGreaterThanOrEqual(testCase, numel(unique(y)), 2, ...
    'Un set cu o singura clasa nu este utilizabil pentru varianta A.');
end

function testVariantCIsBinaryProbabilistic(testCase)
[~, y, ~, ti] = w3_extract_features('C', testCase.TestData.args{:});
verifyEqual(testCase, ti.type, 'classification');
verifyTrue(testCase, all(ismember(y, [0 1])), 'PoP este un eveniment binar.');
verifyEqual(testCase, ti.unit, '%');
% ismember(y,[0 1]) trece si pentru un set integral 0. Rata de baza trebuie sa
% fie una pe care se poate invata ceva.
assumeGreaterThan(testCase, numel(y), 40);
br = mean(y);
verifyGreaterThan(testCase, br, 0.02, 'Set fara evenimente pozitive utilizabile.');
verifyLessThan(testCase, br, 0.98, 'Set fara evenimente negative utilizabile.');
end

function testTargetIsInTheFuture(testCase)
% Contractul central: eticheta trebuie sa provina dintr-un cadru VIITOR.
[~, ~, ~, ti] = w3_extract_features('B', testCase.TestData.args{:});
lead = ti.targetTimestamps - ti.timestamps;
verifyTrue(testCase, all(lead == minutes(ti.horizonMinutes)), ...
    'Fiecare eticheta trebuie sa fie la exact orizontul cerut in viitor.');
verifyGreaterThan(testCase, ti.horizonMinutes, 0);
end

function testNoTargetLeakage(testCase)
% Eticheta nu are voie sa fie o functie inchisa de propriile trasaturi
% (reconstructibila exact din ele): ar fi scurgere totala, nu prognoza.
[X, y, ~, ~] = w3_extract_features('B', testCase.TestData.args{:});
b = [ones(size(X, 1), 1) X] \ y;
resid = y - [ones(size(X, 1), 1) X] * b;
verifyGreaterThan(testCase, sum(resid.^2), 1e-12, ...
    'Eticheta nu trebuie sa fie o functie determinista a trasaturilor.');
end

function testNoSyntheticSamples(testCase)
[X, ~, ~, ti] = w3_extract_features('B', testCase.TestData.args{:});
verifyEqual(testCase, ti.augmentedSamples, 0, 'Nu se mai fabrica esantioane.');
verifyEqual(testCase, ti.realSamples, size(X, 1));
end

function testSequencesHaveRealTimeDepth(testCase)
% Secventele LSTM trebuie sa aiba mai mult de un pas de timp.
[~, ~, ~, ti] = w3_extract_features('B', testCase.TestData.args{:});
s = ti.sequences{1};
verifyEqual(testCase, size(s, 2), ti.historyFrames);
verifyGreaterThan(testCase, size(s, 2), 1, ...
    'O secventa de un singur pas face LSTM-ul echivalent cu un perceptron.');
verifyEqual(testCase, size(s, 1), numel(ti.baseFeatureNames));
end

function testTemporalSplitIsOrderedAndDisjoint(testCase)
[~, ~, ~, ti] = w3_extract_features('B', testCase.TestData.args{:});
s = ti.split;
verifyEmpty(testCase, intersect(s.train, s.val));
verifyEmpty(testCase, intersect(s.train, s.test));
verifyEmpty(testCase, intersect(s.val, s.test));
verifyTrue(testCase, max(ti.timestamps(s.train)) < min(ti.timestamps(s.val)), ...
    'Validarea trebuie sa fie strict dupa antrenament.');
verifyTrue(testCase, max(ti.timestamps(s.val)) < min(ti.timestamps(s.test)), ...
    'Testul trebuie sa fie strict dupa validare.');

% EMBARGOUL este afirmatia centrala din flowchart.md si din roadmap. Amprenta
% unui esantion in serie este fereastra de intrare plus orizontul, deci
% separarea dintre segmente trebuie sa acopere cel putin orizontul.
assumeNotEmpty(testCase, s.val);
assumeNotEmpty(testCase, s.test);
verifyGreaterThanOrEqual(testCase, ...
    min(ti.timestamps(s.val)) - max(ti.timestamps(s.train)), ...
    minutes(ti.horizonMinutes), ...
    'Intre train si val trebuie sa existe cel putin orizontul de prognoza.');
verifyGreaterThanOrEqual(testCase, ...
    min(ti.timestamps(s.test)) - max(ti.timestamps(s.val)), ...
    minutes(ti.horizonMinutes), ...
    'Intre val si test trebuie sa existe cel putin orizontul de prognoza.');
% Embargoul trebuie sa acopere si fereastra de istoric, nu doar orizontul.
verifyGreaterThanOrEqual(testCase, s.embargo, ti.horizonFrames + ti.historyFrames, ...
    'Embargoul trebuie sa acopere fereastra de intrare plus orizontul.');
end

function testDiurnalFeaturesAreGatedOnRealCoverage(testCase)
% Pe o arhiva scurta, ora zilei devine un identificator de episod meteo, deci
% trasaturile diurne trebuie excluse sub prag.
%
% Pragul se aplica pe ACOPERIREA REALA, nu pe intervalul calendaristic: arhiva
% are goluri de zile intregi, iar max(ts)-min(ts) le-ar numara ca date.
d = testCase.TestData;
[~, ~, fnOff, ~] = w3_extract_features('B', d.args{:});
verifyFalse(testCase, any(strcmp(fnOff, 'hourSin')), ...
    'Pe o fereastra scurta trasaturile diurne trebuie excluse.');
verifyFalse(testCase, any(strcmp(fnOff, 'hourCos')));

[X, ~, fnOn, tiOn] = w3_extract_features('B', d.args{:}, 'MinDaysForDiurnal', 0.1);
verifyTrue(testCase, any(strcmp(fnOn, 'hourSin')), ...
    'Sub un prag coborat, trasaturile diurne trebuie incluse.');
verifyTrue(testCase, any(strcmp(fnOn, 'hourCos')));
% live.X trebuie sa aiba exact aceleasi coloane ca X, altfel predictia live
% cade abia in main.m, dupa tot antrenamentul.
assumeTrue(testCase, tiOn.live.available);
verifyEqual(testCase, numel(tiOn.live.X), size(X, 2), ...
    'live.X trebuie sa aiba acelasi numar de coloane ca X.');
end

function testPersistenceBaselineIsProvided(testCase)
[X, y, ~, ti] = w3_extract_features('B', testCase.TestData.args{:});
verifyEqual(testCase, numel(ti.persistence), size(X, 1));
r2 = 1 - sum((y - ti.persistence).^2) / sum((y - mean(y)).^2);
verifyGreaterThan(testCase, r2, 0, ...
    'Persistenta trebuie sa fie o referinta utila la acest orizont.');
end

function testBadVariantRejected(testCase)
verifyError(testCase, @() w3_extract_features('Z', testCase.TestData.args{:}), ...
    'TIMRadar:BadVariant');
end

function testShortHistoryDoesNotUnderflowIndices(testCase)
% Tendinta pe 30 de minute priveste 6 cadre in urma, chiar daca HistoryFrames
% este mai mic (aici 3): fereastra de esantionare trebuie sa tina cont de ea.
d = testCase.TestData;
[X, y, ~, ti] = w3_extract_features('B', 'DataDir', d.dataDir, ...
    'MaxFrames', 200, 'HistoryFrames', 3, 'Verbose', false);
verifyGreaterThan(testCase, numel(y), 0);
verifyTrue(testCase, all(isfinite(X(:))), 'Trasaturile nu pot contine NaN/Inf.');
verifyEqual(testCase, size(ti.sequences{1}, 2), 3);
end

function testLivePersistenceIsOnTheTargetScale(testCase)
% live.persistence trebuie sa fie pe scara tintei: clasa la A, 0/1 la C,
% mm/h la B.
d = testCase.TestData;
[~, ~, ~, tiA] = w3_extract_features('A', d.args{:});
[~, ~, ~, tiB] = w3_extract_features('B', d.args{:});
[~, ~, ~, tiC] = w3_extract_features('C', d.args{:});
assumeTrue(testCase, tiA.live.available && tiB.live.available && tiC.live.available);
verifyTrue(testCase, ismember(tiA.live.persistence, [1 2 3 4]), ...
    'Varianta A: persistenta trebuie sa fie o clasa.');
verifyTrue(testCase, ismember(tiC.live.persistence, [0 1]), ...
    'Varianta C: persistenta trebuie sa fie evenimentul binar.');
verifyGreaterThanOrEqual(testCase, tiB.live.persistence, 0);
end

function testFeatureCacheIsMergedNotTruncated(testCase)
% O rulare cu 'MaxFrames' mic (testele, rularile rapide) nu are voie sa stearga
% din cache statisticile restului arhivei (~6 minute de recalculat).
d = testCase.TestData;
cf = [tempname '.mat'];

radar_feature_table(d.dataDir, 'Product', 'all', 'MaxFrames', 40, ...
    'CacheFile', cf, 'Verbose', false);
L = load(cf, 'cache');
nBefore = numel(L.cache.name);
verifyEqual(testCase, nBefore, 40);

% Ultimele 5 intrari se scot din cache, ca sa devina "cadre noi" la reluare.
cache = L.cache;
k = 1:(nBefore - 5);
cache.name      = cache.name(k);
cache.bytes     = cache.bytes(k);
cache.stats     = cache.stats(k);
cache.timestamp = cache.timestamp(k);
cache.product   = cache.product(k);
save(cf, 'cache');

radar_feature_table(d.dataDir, 'Product', 'all', 'MaxFrames', 5, ...
    'CacheFile', cf, 'Verbose', false);
L2 = load(cf, 'cache');
nAfter = numel(L2.cache.name);
if isfile(cf), delete(cf); end

verifyEqual(testCase, nAfter, nBefore, ...
    'Cadrele noi trebuie ADAUGATE peste cache, nu sa il inlocuiasca.');
end


function tests = test_w2
% Teste Saptamana 2: curatare si statistici fizice.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
testCase.TestData.root = fileparts(fileparts(mfilename('fullpath')));
addpath(testCase.TestData.root);
end

function testLegacyMatrixContract(testCase)
raw = [NaN, 10, Inf; -20, 45, 80; 0, 5, 25];
[cleanMat, stats] = w2_clean_and_stats(raw);

verifyTrue(testCase, all(isfinite(cleanMat(:))), 'Matricea curatata nu poate contine NaN/Inf.');
verifyTrue(testCase, all(cleanMat(:) >= -10 & cleanMat(:) <= 75), ...
    'Valorile trebuie limitate la [-10, 75] dBZ.');

for f = {'mean', 'median', 'p95', 'maximum', 'std', 'mad', 'validFraction', 'numPixels'}
    verifyTrue(testCase, isfield(stats, f{1}), sprintf('Lipseste campul %s.', f{1}));
end
verifyGreaterThan(testCase, stats.validFraction, 0);
verifyLessThanOrEqual(testCase, stats.validFraction, 1);
end

function testEmptySignalError(testCase)
verifyError(testCase, @() w2_clean_and_stats([NaN NaN; Inf -Inf]), 'TIMRadar:EmptySignal');
end

function testInvalidInputError(testCase)
verifyError(testCase, @() w2_clean_and_stats(ones(2, 2, 2)), 'TIMRadar:InvalidInput');
end

function testStatsUseEchoPixelsOnly(testCase)
% Media se calculeaza doar pe ecou: o medie pe toti pixelii, inclusiv
% umplutura, ar masura cat de goala e grila, nu vremea.
%
% Aici doar 1 din 100 de pixeli are ecou, la 40 dBZ. Media pe ecou trebuie sa
% fie 40, nu ~-9.5 cat ar da media pe toata grila.
m = -10 * ones(10, 10);
m(5, 5) = 40;
[~, stats] = w2_clean_and_stats(m);
verifyEqual(testCase, stats.mean, 40, 'AbsTol', 1e-9, ...
    'Statisticile de semnal trebuie calculate doar pe pixelii cu ecou.');
verifyEqual(testCase, stats.echoFraction, 0.01, 'AbsTol', 1e-9);
end

function testFrameInputIsAreaWeighted(testCase)
d = dir(fullfile(testCase.TestData.root, 'data', 'TIM_*dBZ.hdf'));
assumeNotEmpty(testCase, d);
[~, ord] = sort({d.name});
F = radar_read_frame(fullfile(testCase.TestData.root, 'data', d(ord(end)).name));
[cleanMat, stats] = w2_clean_and_stats(F);

verifySize(testCase, cleanMat, size(F.dbz));
for f = {'coverageFraction', 'echoFraction', 'arealRainRate', 'rainAreaFraction', ...
         'clutterFraction', 'validMask'}
    verifyTrue(testCase, isfield(stats, f{1}), sprintf('Lipseste campul fizic %s.', f{1}));
end
verifyGreaterThanOrEqual(testCase, stats.echoFraction, 0);
verifyLessThanOrEqual(testCase, stats.echoFraction, 1);
verifyGreaterThanOrEqual(testCase, stats.arealRainRate, 0);
verifyLessThan(testCase, stats.arealRainRate, 50, ...
    'Intensitatea medie pe suprafata trebuie sa fie fizic plauzibila.');
end

function testImageProductStats(testCase)
% Statisticile trebuie sa fie fizic plauzibile si pe produsul IMAGE (PCAPPI),
% de regula un cadru pe zi, la 23:55.
d = dir(fullfile(testCase.TestData.root, 'data', 'TIM_*dBZ.hdf'));
assumeNotEmpty(testCase, d);
[~, ord] = sort({d.name});
d = d(ord);
image = '';
for i = numel(d):-1:1
    f = fullfile(d(i).folder, d(i).name);
    try
        prod = h5readatt(f, '/what', 'object');
    catch
        continue;
    end
    % h5readatt pastreaza terminatorul NUL al sirului; se pastreaza doar
    % caracterele alfanumerice (vezi test_w1).
    if iscell(prod), prod = prod{1}; end
    if strcmp(upper(regexprep(char(prod(:).'), '[^A-Za-z0-9]', '')), 'IMAGE')
        image = f;
        break;
    end
end
assumeNotEmpty(testCase, image, 'Niciun cadru IMAGE local (unul pe zi, la 23:55).');
F = radar_read_frame(image);
[~, st] = w2_clean_and_stats(F);
verifyGreaterThanOrEqual(testCase, st.echoFraction, 0);
verifyLessThanOrEqual(testCase, st.echoFraction, 1);
verifyLessThan(testCase, st.maxRainRate, 100, ...
    'Plafonul Z-R trebuie sa se aplice si pe produsul IMAGE.');
end

function testNoEchoFrameIsNotAnError(testCase)
% Cer complet senin este o observatie valida, nu o eroare.
F = struct('dbz', -32 * ones(4, 4), 'validMask', true(4, 4), ...
           'echoMask', false(4, 4), 'areaWeight', ones(4, 4) / 16, ...
           'rainRate', zeros(4, 4), 'noEchoDbz', -32);
[~, stats] = w2_clean_and_stats(F);
verifyEqual(testCase, stats.echoFraction, 0);
verifyEqual(testCase, stats.arealRainRate, 0);
end

function testHailCapAppliesToMatrixInputToo(testCase)
% Plafonul Z-R de 53 dBZ se aplica pe AMBELE cai de intrare ("struct de cadru"
% si "matrice bruta"); fizica nu are voie sa depinda de tipul intrarii.
m = -10 * ones(20);
m(10, 10) = 75;
[~, stats] = w2_clean_and_stats(m);
verifyLessThan(testCase, stats.maxRainRate, 100, ...
    'Plafonul de grindina trebuie aplicat pe ambele cai de intrare.');
end

function testStatsAreAreaWeightedNotPixelCounted(testCase)
% PONDERAREA CU ARIA. Pe calea "matrice bruta" ponderile sunt uniforme, deci
% acolo o medie ponderata nu se poate distinge de una simpla; testul construieste
% ponderi de inel polar care cresc cu distanta.
%
% Aici doua celule au ecou: una in inelul apropiat, una in cel indepartat, cu
% arie mult mai mare. Media ponderata trebuie atrasa de cea indepartata.
n = 10;
dbz = -32 * ones(n, 4);
dbz(2, 1) = 10;      % aproape de radar, arie mica
dbz(9, 2) = 40;      % departe de radar, arie mare

ringArea = ((1:n)' .^ 2 - (0:n-1)' .^ 2);    % creste cu distanta
W = repmat(ringArea, 1, 4);
W = W / sum(W(:));

F = struct('dbz', dbz, 'validMask', true(n, 4), 'echoMask', dbz > -32, ...
           'areaWeight', W, 'rainRate', zeros(n, 4), 'noEchoDbz', -32);
[~, st] = w2_clean_and_stats(F);

wNear = W(2, 1);
wFar  = W(9, 2);
expected = (wNear * 10 + wFar * 40) / (wNear + wFar);
verifyEqual(testCase, st.mean, expected, 'AbsTol', 1e-9, ...
    'Media trebuie ponderata cu aria pixelilor, nu cu numarul lor.');
verifyGreaterThan(testCase, st.mean, 25, ...
    'Media nepoderata ar da 25; ponderarea cu aria trebuie sa o tragem spre 40.');
verifyEqual(testCase, st.median, 40, 'AbsTol', 1e-9, ...
    'Mediana ponderata este determinata de arie, nu de numarul de pixeli.');
end

function testPhysicalStatsAreMutuallyConsistent(testCase)
% Pe un cadru real marimile au relatii de ordine obligatorii, care prind erori
% de unitati sau de masca.
d = dir(fullfile(testCase.TestData.root, 'data', 'TIM_*dBZ.hdf'));
assumeNotEmpty(testCase, d);
[~, ord] = sort({d.name});
F = radar_read_frame(fullfile(testCase.TestData.root, 'data', d(ord(end)).name));
[~, st] = w2_clean_and_stats(F);

verifyEqual(testCase, st.coverageFraction, st.validFraction, 'AbsTol', 0);
verifyLessThanOrEqual(testCase, st.fracAbove35, st.fracAbove20);
verifyLessThanOrEqual(testCase, st.fracAbove20, st.echoFraction);
verifyLessThanOrEqual(testCase, st.rainAreaFraction, st.echoFraction);
verifyGreaterThanOrEqual(testCase, st.p99, st.p95);
verifyGreaterThanOrEqual(testCase, st.p95, st.median);
verifyGreaterThanOrEqual(testCase, st.maximum, st.p99);
% Ordinul de marime real este ~0.03 mm/h; un prag mult mai larg ar trece si
% fara ponderare cu aria.
verifyLessThan(testCase, st.arealRainRate, 5, ...
    'Intensitatea medie pe suprafata trebuie sa fie de ordinul zecimilor de mm/h.');
end

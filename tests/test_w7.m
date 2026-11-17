function tests = test_w7
% Teste Saptamana 7: dashboard.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
testCase.TestData.root = root;

% Un cadru IMAGE (PCAPPI cartezian), cautat de la coada spre inceput, pentru
% calea carteziana din w7 (ultimul fisier este aproape intotdeauna PVOL).
d = dir(fullfile(root, 'data', 'TIM_*dBZ.hdf'));
[~, ord] = sort({d.name});
d = d(ord);
testCase.TestData.imageFile = '';
for i = numel(d):-1:max(1, numel(d) - 400)
    f = fullfile(root, 'data', d(i).name);
    try
        prod = h5readatt(f, '/what', 'object');
    catch
        continue;
    end
    % h5readatt pastreaza terminatorul NUL; h5info il elimina. Vezi test_w1.
    if iscell(prod), prod = prod{1}; end
    if strcmp(upper(regexprep(char(prod(:).'), '[^A-Za-z0-9]', '')), 'IMAGE')
        testCase.TestData.imageFile = f;
        break;
    end
end
end

function testCartesianMapIsNotFlippedNorthSouth(testCase)
% Harta PCAPPI nu are voie sa fie oglindita nord-sud.
%
% In ODIM, primul RAND al unei imagini carteziene este cel mai de NORD
% (colturile din /where sunt date de sus in jos). Cu imagesc(..., [-halfY halfY])
% si 'YDir','normal', randul 1 ar ajunge in partea de JOS a axei, deci o celula
% aflata fizic la nord de Timisoara s-ar desena la sud.
assumeNotEmpty(testCase, testCase.TestData.imageFile, ...
    'Niciun cadru IMAGE local in ultimele ~400 de fisiere.');
F = radar_read_frame(testCase.TestData.imageFile);
assumeEqual(testCase, F.geometry.type, 'cartesian');
[~, stats] = w2_clean_and_stats(F);

fig = w7_main_dashboard(F, stats, 'Visible', 'off');
im = findobj(fig, 'Type', 'image');
verifyNotEmpty(testCase, im, 'Calea carteziana trebuie sa deseneze cu imagesc.');
yd = im(1).YData;
close(fig);

% YData(1) corespunde primului rand al matricei si trebuie sa fie la NORD,
% adica la Y pozitiv.
verifyGreaterThan(testCase, yd(1), yd(2), ...
    'Primul rand al imaginii ODIM este cel mai nordic, deci Y descreste.');
verifyGreaterThan(testCase, yd(1), 0, 'Marginea de nord trebuie sa fie la Y > 0.');
end

function testMatrixInputContract(testCase)
cleanMat = rand(60, 60) * 40 - 5;
[~, stats] = w2_clean_and_stats(cleanMat);
fig = w7_main_dashboard(cleanMat, stats, 'Visible', 'off');
verifyTrue(testCase, isgraphics(fig, 'figure'));
verifyEqual(testCase, numel(findobj(fig, 'Type', 'axes')), 4, ...
    'Dashboard-ul are 4 panouri.');
close(fig);
end

function testFrameInputPlotsInKilometres(testCase)
% Matricea polara [920 raze x 360 azimuturi] se deseneaza in km fata de radar,
% nu direct ca "Pixel X / Pixel Y".
d = dir(fullfile(testCase.TestData.root, 'data', 'TIM_*dBZ.hdf'));
assumeNotEmpty(testCase, d);
[~, ord] = sort({d.name});
F = radar_read_frame(fullfile(testCase.TestData.root, 'data', d(ord(end)).name));
[~, stats] = w2_clean_and_stats(F);

fig = w7_main_dashboard(F, stats, 'Visible', 'off');
verifyTrue(testCase, isgraphics(fig, 'figure'));
ax = findobj(fig, 'Type', 'axes');
labels = arrayfun(@(a) string(a.XLabel.String), ax);
verifyTrue(testCase, any(contains(labels, 'km')), ...
    'Hartile trebuie desenate in kilometri fata de radar.');
close(fig);
end

function testVariantDrivesTheCard(testCase)
% Varianta vine din taskInfo, nu se ghiceste din valoare: 40 mm/h si 40% PoP
% sunt acelasi numar.
%
% ATENTIE la formularea asertiunilor: w7 tipareste pe FIECARE card linia de
% context "Ecou pe %.1f%% din suprafata | P95 ... | %.3f mm/h acum", deci
% contains(txt,'%') sau contains(txt,'mm/h') sunt adevarate pentru orice
% varianta. Se verifica textul specific fiecarei variante, in ambele sensuri.
cleanMat = rand(40, 40) * 30;
[~, stats] = w2_clean_and_stats(cleanMat);

% Helper anonim, nu functie locala: functiontests(localfunctions) transforma
% ORICE functie locala in caz de test si o apeleaza cu un TestCase.
grab = @(f) strjoin(string(get(findobj(f, 'Type', 'text'), 'String')), ' ');

figC = w7_main_dashboard(cleanMat, stats, 'Prediction', 40, ...
    'TaskInfo', struct('variant', 'C', 'horizonMinutes', 30, ...
                       'popThresholdC', 0.10, 'classNames', {{}}), 'Visible', 'off');
txtC = grab(figC); close(figC);
verifyTrue(testCase, contains(txtC, 'SANSE DE PLOAIE EXTINSA'), ...
    'Varianta C trebuie sa anunte o probabilitate.');
verifyFalse(testCase, contains(txtC, 'medie pe suprafata'), ...
    'Varianta C nu trebuie sa afiseze formularea de intensitate a variantei B.');

figB = w7_main_dashboard(cleanMat, stats, 'Prediction', 40, ...
    'TaskInfo', struct('variant', 'B', 'horizonMinutes', 30, 'classNames', {{}}), ...
    'Visible', 'off');
txtB = grab(figB); close(figB);
verifyTrue(testCase, contains(txtB, 'medie pe suprafata'), ...
    'Varianta B trebuie afisata ca intensitate medie pe suprafata.');
verifyFalse(testCase, contains(txtB, 'SANSE DE PLOAIE'), ...
    'Varianta B nu trebuie prezentata drept probabilitate.');

names = {'Fara precipitatii semnificative (<5% din domeniu)', ...
         'Precipitatii izolate (5-15%)', 'Precipitatii extinse (15-30%)', ...
         'Precipitatii generalizate (>30%)'};
figA = w7_main_dashboard(cleanMat, stats, 'Prediction', 3, ...
    'TaskInfo', struct('variant', 'A', 'horizonMinutes', 30, 'classNames', {names}), ...
    'Visible', 'off');
txtA = grab(figA); close(figA);
verifyTrue(testCase, contains(txtA, 'PRECIPITATII EXTINSE'), ...
    'Varianta A trebuie sa afiseze numele clasei prognozate.');
verifyFalse(testCase, contains(txtA, 'SANSE DE PLOAIE'), ...
    'Varianta A nu trebuie prezentata drept probabilitate.');
% Titlul se taie de paranteza, ca sa nu depaseasca cardul.
verifyFalse(testCase, contains(txtA, 'EXTINSE (15-30%)'), ...
    'Titlul variantei A trebuie sa fie fara paranteza explicativa.');
end

function testSpokenForecastTextMatchesTheNumbers(testCase)
% speak_forecast este livrabil de saptamana 7 si este apelat din main.m. Se
% verifica acordul numeralului, zecimala cu virgula si faptul ca scara
% variantei C nu se ghiceste.
infoB = speak_forecast('B', 0.082, 'Play', false);
verifyTrue(testCase, contains(infoB.text, '30 de minute'), ...
    'In romana, peste 19 numeralul cere "de": "30 de minute".');
verifyTrue(testCase, contains(infoB.text, '0,082'), ...
    'Zecimala se scrie cu virgula intr-un text romanesc.');
verifyEqual(testCase, infoB.alertType, 'ploaie_moderata');

infoC = speak_forecast('C', 62, 'TaskInfo', struct('unit', '%'), 'Play', false);
verifyTrue(testCase, contains(infoC.text, '62 la suta'));
verifyEqual(testCase, infoC.alertType, 'ploaie_extinsa');

% Fara TaskInfo si cu o valoare > 1 scara este ambigua: eroare explicita, nu
% "100 la suta" pentru orice intrare.
verifyError(testCase, @() speak_forecast('C', 62, 'Play', false), ...
    'TIMRadar:AmbiguousScale');

% 15 minute NU ia "de".
info15 = speak_forecast('B', 0.01, 'TaskInfo', struct('horizonMinutes', 15), 'Play', false);
verifyTrue(testCase, contains(info15.text, '15 minute'));
verifyFalse(testCase, contains(info15.text, '15 de minute'));

infoT = speak_forecast('B', 0.03, 'Client', 'TextOnly', 'Play', false);
verifyFalse(testCase, infoT.synthesized);
end


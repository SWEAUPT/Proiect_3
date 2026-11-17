function tests = test_w6
% Teste Saptamana 6: evaluare pe date nevazute, cu referinte.
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

function testRegressionTableHasBaselines(testCase)
d = testCase.TestData;
[X, y, fn, ti] = w3_extract_features('B', d.args{:});
tr = ti.split.train;
rf = w4_train_random_forest(X(tr, :), y(tr), fn, 'TaskInfo', ti, ...
    'NumTrees', 25, 'Verbose', false);

[tbl, detail] = w6_evaluate_models(rf, [], X, y, ti);
verifyTrue(testCase, istable(tbl));
verifyTrue(testCase, ismember('SkillVsPersistenta', tbl.Properties.VariableNames), ...
    'Tabelul trebuie sa raporteze abilitatea fata de persistenta.');
verifyTrue(testCase, any(contains(tbl.Model, 'Persistenta')), ...
    'Persistenta trebuie sa apara ca referinta.');
verifyTrue(testCase, any(contains(tbl.Model, 'Climatologie')));
verifyEqual(testCase, detail.metric, 'regression');
end

function testEvaluatesOnTestSplitByDefault(testCase)
% Implicit se evalueaza pe test, nu pe datele de antrenament.
d = testCase.TestData;
[X, y, fn, ti] = w3_extract_features('B', d.args{:});
tr = ti.split.train;
rf = w4_train_random_forest(X(tr, :), y(tr), fn, 'TaskInfo', ti, ...
    'NumTrees', 25, 'Verbose', false);
[~, detail] = w6_evaluate_models(rf, [], X, y, ti);
verifyEqual(testCase, detail.idx, ti.split.test, ...
    'Implicit se evalueaza pe segmentul de test.');
verifyEmpty(testCase, intersect(detail.idx, ti.split.train));
end

function testBinaryClassificationReportsBrier(testCase)
% Varianta C se evalueaza cu scorul Brier.
d = testCase.TestData;
% FEREASTRA MAI MARE SI SAMANTA FIXA, doar pentru acest test.
% Cu o fereastra mica (ex. 'MaxFrames', 260) segmentul de test are ~22 de
% esantioane, iar rezultatul depinde de vremea din ultimele ore - care se
% schimba la fiecare sincronizare - nu de cod. Pe 1200 de cadre (157 esantioane
% de test) padurea bate rata de baza pentru orice samanta (0.13-0.14 fata de
% 0.33).
rng(1);
argsC = d.args;
argsC{find(strcmp(argsC, 'MaxFrames')) + 1} = 1200;
[X, y, fn, ti] = w3_extract_features('C', argsC{:});
tr = ti.split.train;
rf = w4_train_random_forest(X(tr, :), y(tr), fn, 'TaskInfo', ti, ...
    'NumTrees', 50, 'Verbose', false);
[tbl, detail] = w6_evaluate_models(rf, [], X, y, ti);
verifyTrue(testCase, ismember('Brier', tbl.Properties.VariableNames));
verifyTrue(testCase, ismember('AUC', tbl.Properties.VariableNames));
b = tbl.Brier(strcmp(tbl.Model, 'Random Forest'));
verifyTrue(testCase, isfield(detail, 'baseRateBrier'));

% 0 <= Brier <= 1 este adevarat pentru ORICE iesire de probabilitate, deci nu
% verifica nimic. Scorul Brier este livrabilul variantei C: cerinta reala este
% sa bata referinta climatologica.
verifyLessThan(testCase, b, detail.baseRateBrier, ...
    'Modelul trebuie sa bata scorul Brier al ratei de baza, altfel strica prognoza.');

% Persistenta si clasa majoritara sunt prognoze deterministe, dar au Brier si
% AUC bine definite, deci referinta obligatorie apare si in coloana pe care se
% raporteaza varianta C.
bp = tbl.Brier(strcmp(tbl.Model, 'Persistenta (referinta)'));
verifyFalse(testCase, isnan(bp), 'Persistenta trebuie sa aiba un scor Brier.');
verifyGreaterThanOrEqual(testCase, bp, 0);
verifyLessThanOrEqual(testCase, bp, 1);
au = tbl.AUC(~isnan(tbl.AUC));
verifyTrue(testCase, all(au >= 0 & au <= 1));
end

function testPersistenceRowHasExactlyZeroSkill(testCase)
% Randul de persistenta este definitia pragului, deci abilitatea lui fata de
% sine trebuie sa fie exact 0. O eroare de semn sau de numitor in scorul de
% abilitate se vede imediat aici si nicaieri altundeva.
d = testCase.TestData;
[X, y, fn, ti] = w3_extract_features('B', d.args{:});
tr = ti.split.train;
rf = w4_train_random_forest(X(tr, :), y(tr), fn, 'TaskInfo', ti, ...
    'NumTrees', 15, 'Verbose', false);
tbl = w6_evaluate_models(rf, [], X, y, ti);
k = strcmp(tbl.Model, 'Persistenta (referinta)');
verifyEqual(testCase, tbl.SkillVsPersistenta(k), 0, 'AbsTol', 1e-12);
verifyEqual(testCase, tbl.R2(k), 1 - tbl.RMSE(k)^2 / var(y(ti.split.test), 1), ...
    'RelTol', 1e-6, 'R2 si RMSE trebuie sa fie consistente intre ele.');
end

function testMulticlassConfusion(testCase)
d = testCase.TestData;
[X, y, fn, ti] = w3_extract_features('A', d.args{:});
tr = ti.split.train;
rf = w4_train_random_forest(X(tr, :), y(tr), fn, 'TaskInfo', ti, ...
    'NumTrees', 25, 'Verbose', false);
[tbl, detail] = w6_evaluate_models(rf, [], X, y, ti);
verifyTrue(testCase, ismember('MacroF1', tbl.Properties.VariableNames));
verifyEqual(testCase, detail.metric, 'classification');
verifyNotEmpty(testCase, detail.confusion);
cm = detail.confusion{1};
verifyEqual(testCase, sum(cm(:)), numel(detail.idx));
end

function testRequiresTaskInfo(testCase)
% taskInfo poarta tipul problemei, splitul si referinta de persistenta, deci
% lipsa lui trebuie semnalata explicit, nu printr-o eroare generica MATLAB.
verifyError(testCase, @() w6_evaluate_models([], [], zeros(3, 2), zeros(3, 1)), ...
    'TIMRadar:MissingTaskInfo');
verifyError(testCase, @() w6_evaluate_models([], [], zeros(3, 2), zeros(3, 1), struct()), ...
    'TIMRadar:MissingTaskInfo');
end

function testBaselinesAreEstimatedOnTrainOnly(testCase)
% Climatologia si clasa majoritara se estimeaza pe TRAIN, nu pe etichetele
% evaluate (altfel R2-ul climatologiei ar iesi 0 prin constructie, iar
% "referinta" ar vedea raspunsurile).
d = testCase.TestData;
[X, y, fn, ti] = w3_extract_features('B', d.args{:});
tr = ti.split.train;
rf = w4_train_random_forest(X(tr, :), y(tr), fn, 'TaskInfo', ti, ...
    'NumTrees', 15, 'Verbose', false);
[tbl, detail] = w6_evaluate_models(rf, [], X, y, ti);
k = find(strcmp(tbl.Model, 'Climatologie (medie)'), 1);
verifyNotEmpty(testCase, k, 'Climatologia trebuie sa apara ca referinta.');
verifyEqual(testCase, detail.predictions{k}(1), mean(y(tr)), 'AbsTol', 1e-12, ...
    'Climatologia trebuie estimata pe segmentul de antrenament, nu pe cel evaluat.');
verifyEqual(testCase, detail.baselineFrom, 'train');
end


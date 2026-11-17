function tests = test_w4
% Teste Saptamana 4: Random Forest.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
testCase.TestData.root = root;
tmp = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
testCase.TestData.outDir = tmp.Folder;
rng(10);
testCase.TestData.X = randn(80, 8);
testCase.TestData.yReg = abs(randn(80, 1));
testCase.TestData.yCls = double(testCase.TestData.X(:, 1) > 0);
testCase.TestData.names = arrayfun(@(i) sprintf('f%d', i), 1:8, 'UniformOutput', false);
end

function testRegressionContract(testCase)
d = testCase.TestData;
[model, importance] = w4_train_random_forest(d.X, d.yReg, d.names, ...
    'TaskType', 'regression', 'NumTrees', 30, 'Verbose', false);
verifyEqual(testCase, model.taskType, 'regression');
verifyTrue(testCase, isfield(model, 'modelObj'));
verifyTrue(testCase, isfield(model, 'trainR2'));
verifyTrue(testCase, isfield(model, 'oobRMSE'));
verifyEqual(testCase, numel(importance.sortedValues), 8);
verifyEqual(testCase, sum(importance.values), 100, 'AbsTol', 1e-6);
% sum(...) == 100 este o tautologie de normalizare, dar aici NU se poate cere
% un prag de calitate: d.yReg = abs(randn(...)) nu are nicio legatura cu d.X,
% deci nu exista semnal de invatat. Un R2 in-sample de ~0.49 pe zgomot pur este
% comportamentul normal al unui ansamblu bagged, nu un defect. Pragul de
% calitate se verifica pe o tinta invatabila, in
% testAnchoredRegressionIsOnTheTargetScale.
verifyEqual(testCase, importance.method, 'oobPermuted', ...
    'Importanta trebuie sa vina din permutare OOB, nu din castigul la ramificatii.');
% Pe zgomot pur, eroarea out-of-bag nu are voie sa fie mai buna decat imprastierea
% tintei: daca ar fi, ar insemna ca modelul "invata" ceva ce nu exista.
verifyGreaterThan(testCase, model.oobRMSE, 0.5 * std(d.yReg), ...
    'Pe o tinta fara semnal, eroarea OOB nu poate fi mult sub abaterea tintei.');
end

function testClassificationContract(testCase)
d = testCase.TestData;
model = w4_train_random_forest(d.X, d.yCls, d.names, ...
    'TaskType', 'classification', 'NumTrees', 30, 'Verbose', false);
verifyEqual(testCase, model.taskType, 'classification');
verifyTrue(testCase, isfield(model, 'oobAccuracy'));
verifyNotEmpty(testCase, model.classOrder);

% PRAG DE CALITATE. Verificarile de mai sus sunt doar isfield/isempty, pe care
% le-ar trece si un model constant. yCls este exact X(:,1) > 0, adica separabil
% perfect de o singura taietura, deci un Random Forest care functioneaza
% trebuie sa il invete aproape perfect si sa numeasca f1 drept predictor
% dominant.
verifyGreaterThan(testCase, model.oobAccuracy, 0.85, ...
    'O tinta perfect separabila trebuie invatata; acuratetea OOB este prea mica.');
verifyEqual(testCase, model.importance.sortedNames{1}, 'f1', ...
    'Predictorul care defineste tinta trebuie sa iasa primul in importanta.');
% Breiman: sqrt(p) predictori pe ramificatie la clasificare.
verifyEqual(testCase, model.numVarsPerSplit, round(sqrt(size(d.X, 2))));
end

function testIsARealRandomForest(testCase)
% NumVariablesToSample = 'all' ar fi bagging, nu Random Forest.
d = testCase.TestData;
model = w4_train_random_forest(d.X, d.yReg, d.names, ...
    'TaskType', 'regression', 'NumTrees', 20, 'Verbose', false);
verifyLessThan(testCase, model.numVarsPerSplit, size(d.X, 2), ...
    'Un Random Forest esantioneaza un SUBSET de predictori la fiecare ramificatie.');
verifyGreaterThanOrEqual(testCase, model.numVarsPerSplit, 1);
% Valoarea exacta ceruta de Breiman pentru regresie: p/3.
verifyEqual(testCase, model.numVarsPerSplit, max(1, floor(size(d.X, 2) / 3)));
end

function testAnchoredRegressionIsOnTheTargetScale(testCase)
% Ancorarea pe persistenta a fost adaugata la w4 ca sa fie simetrica cu w5.
% Se verifica aici ca predictia iese pe SCARA TINTEI, nu pe scara diferentei,
% si ca w4_predict este drumul care adauga ancora inapoi.
d = testCase.TestData;
names = d.names;
names{3} = 'arealRainRate';          % coloana 3 devine ancora
X = d.X;
y = 5 + X(:, 3) + 0.01 * randn(size(X, 1), 1);   % nivel mare, delta mic

model = w4_train_random_forest(X, y, names, 'TaskType', 'regression', ...
    'NumTrees', 40, 'Verbose', false);
verifyEqual(testCase, model.anchorColumn, 3);
verifyEqual(testCase, model.anchorFeature, 'arealRainRate');

preds = w4_predict(model, X);
verifyLessThan(testCase, abs(mean(preds) - mean(y)), 0.1 * std(y) + 0.05, ...
    'Predictiile ancorate trebuie sa revina pe scara tintei.');
% PRAG DE CALITATE, pe o tinta chiar invatabila (y depinde determinist de
% coloana 3, plus zgomot mic). Un model care prezice o constanta pica aici.
r2 = 1 - sum((y - preds).^2) / sum((y - mean(y)).^2);
verifyGreaterThan(testCase, r2, 0.9, ...
    'Pe o tinta invatabila, ancorarea trebuie sa dea o potrivire foarte buna.');

% Fara ancorare, acelasi apel trebuie sa mearga tot pe scara tintei, dar prin
% alt drum - iar campul trebuie sa spuna clar ca nu exista ancora.
plain = w4_train_random_forest(X, y, names, 'TaskType', 'regression', ...
    'NumTrees', 40, 'Verbose', false, 'AnchorFeature', '');
verifyEmpty(testCase, plain.anchorColumn);
verifyLessThan(testCase, abs(mean(w4_predict(plain, X)) - mean(y)), 0.5);
end

function testTaskTypeMustBeExplicit(testCase)
% Tipul problemei vine din TaskType/TaskInfo, nu din valorile etichetelor
% (etichetele 0/1 ale variantei C nu trebuie sa comute tipul).
d = testCase.TestData;
verifyError(testCase, @() w4_train_random_forest(d.X, d.yReg, d.names, 'Verbose', false), ...
    'TIMRadar:MissingTaskType');
end

function testDoesNotSaveUnlessAsked(testCase)
% Antrenarea fara 'SaveDir' nu scrie nimic pe disc, deci rularea testelor nu
% poate distruge modelele reale din models/rf_variant_*.mat (santinela).
d = testCase.TestData;
snap = @(p) arrayfun(@(f) sprintf('%s|%d|%.6f', f.name, f.bytes, f.datenum), ...
    dir(fullfile(p, '*.mat')), 'UniformOutput', false);
before = snap(fullfile(d.root, 'models'));

model = w4_train_random_forest(d.X, d.yReg, d.names, ...
    'TaskType', 'regression', 'NumTrees', 10, 'Verbose', false);
verifyEmpty(testCase, model.savedTo, 'Fara SaveDir nu trebuie sa se scrie nimic.');

verifyEqual(testCase, snap(fullfile(d.root, 'models')), before, ...
    'Testele nu au voie sa atinga modelele reale din models/.');
end

function testSavesWhenAsked(testCase)
d = testCase.TestData;
model = w4_train_random_forest(d.X, d.yReg, d.names, ...
    'TaskType', 'regression', 'NumTrees', 10, 'Verbose', false, ...
    'SaveDir', d.outDir, 'FileName', 'unit_test_rf.mat');
verifyTrue(testCase, isfile(model.savedTo));
delete(model.savedTo);
end

function testSavedFileRecordsItsOwnPath(testCase)
% model.savedTo se completeaza INAINTE de save(), ca modelul de pe disc sa stie
% de unde a fost incarcat.
d = testCase.TestData;
model = w4_train_random_forest(d.X, d.yReg, d.names, ...
    'TaskType', 'regression', 'NumTrees', 8, 'Verbose', false, ...
    'SaveDir', d.outDir, 'FileName', 'unit_test_rf_path.mat');
S = load(model.savedTo, 'model');
verifyEqual(testCase, S.model.savedTo, model.savedTo, ...
    'Modelul salvat trebuie sa stie unde a fost salvat.');
delete(model.savedTo);
end


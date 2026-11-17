function tests = test_w5
% Teste Saptamana 5: LSTM pe secvente reale.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
testCase.TestData.root = root;
tmp = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
testCase.TestData.outDir = tmp.Folder;
rng(20);
n = 60; nCh = 4; nStep = 8;
seqs = cell(n, 1);
y = zeros(n, 1);
for i = 1:n
    s = cumsum(randn(nCh, nStep), 2) / 10;
    seqs{i} = s;
    y(i) = s(1, end) + 0.05 * randn;
end
testCase.TestData.seqs = seqs;
testCase.TestData.y = y;
testCase.TestData.yCls = double(y > median(y));
end

function testRegressionContract(testCase)
d = testCase.TestData;
[model, history] = w5_train_lstm(d.seqs, d.y, 'TaskType', 'regression', ...
    'MaxEpochs', 8, 'Verbose', false);
verifyEqual(testCase, model.taskType, 'regression');
verifyTrue(testCase, isfield(model, 'modelObj'));
verifyTrue(testCase, isfield(model, 'trainR2'));
verifyEqual(testCase, model.numSteps, 8);
verifyNotEmpty(testCase, history);
% Prag de calitate: y este s(1,end) plus zgomot mic, deci invatabil. O retea
% care prezice media ar trece toate verificarile de tip isfield.
verifyGreaterThan(testCase, model.trainR2, 0.3, ...
    'O retea care prezice o constanta nu trebuie sa treaca acest test.');

preds = w5_predict(model, d.seqs);
verifyEqual(testCase, numel(preds), numel(d.y));
verifyTrue(testCase, all(isfinite(preds)));
end

function testClassificationContract(testCase)
d = testCase.TestData;
model = w5_train_lstm(d.seqs, d.yCls, 'TaskType', 'classification', ...
    'MaxEpochs', 8, 'Verbose', false);
verifyEqual(testCase, model.taskType, 'classification');
[lab, sc] = w5_predict(model, d.seqs);
verifyTrue(testCase, all(ismember(lab, [0 1])), ...
    'Etichetele trebuie sa fie valorile claselor, nu indecsii categoriilor.');
verifyEqual(testCase, size(sc, 2), 2);
verifyEqual(testCase, sum(sc, 2), ones(numel(lab), 1), 'AbsTol', 1e-4);
end

function testRejectsSingleStepSequences(testCase)
% Antrenarea foloseste secvente de mai multi pasi; cu UN pas LSTM-ul ar fi un
% simplu perceptron.
d = testCase.TestData;
flat = cellfun(@(s) s(:, end), d.seqs, 'UniformOutput', false);
verifyError(testCase, @() w5_train_lstm(flat, d.y, 'TaskType', 'regression', ...
    'MaxEpochs', 2, 'Verbose', false), 'TIMRadar:DegenerateSequence');
end

function testTaskTypeMustBeExplicit(testCase)
d = testCase.TestData;
verifyError(testCase, @() w5_train_lstm(d.seqs, d.y, 'MaxEpochs', 2, 'Verbose', false), ...
    'TIMRadar:MissingTaskType');
end

function testDoesNotSaveUnlessAsked(testCase)
% Aceeasi sentinela mutata ca la test_w4: se vegheaza models/, unde stau
% modelele reale, nu data/model_lstm.mat, care nu mai poate fi creat.
d = testCase.TestData;
snap = @(p) arrayfun(@(f) sprintf('%s|%d|%.6f', f.name, f.bytes, f.datenum), ...
    dir(fullfile(p, '*.mat')), 'UniformOutput', false);
before = snap(fullfile(d.root, 'models'));

model = w5_train_lstm(d.seqs, d.y, 'TaskType', 'regression', ...
    'MaxEpochs', 3, 'Verbose', false);
verifyEmpty(testCase, model.savedTo);

verifyEqual(testCase, snap(fullfile(d.root, 'models')), before, ...
    'Testele nu au voie sa atinga modelele reale din models/.');
end

function testNormalisationIsEstimatedOnTrainSequencesOnly(testCase)
% w5_train_lstm estimeaza mu/sigma DOAR pe secventele de antrenament.
% Aici validarea este deplasata cu o constanta mare; daca normalizarea ar privi
% si validarea, mu s-ar muta vizibil.
d = testCase.TestData;
shifted = cellfun(@(s) s + 100, d.seqs, 'UniformOutput', false);

m0 = w5_train_lstm(d.seqs, d.y, 'TaskType', 'regression', ...
    'MaxEpochs', 2, 'Verbose', false);
m1 = w5_train_lstm(d.seqs, d.y, 'TaskType', 'regression', ...
    'MaxEpochs', 2, 'Verbose', false, 'ValidationData', {shifted, d.y});

verifyEqual(testCase, m1.normParams.mu, m0.normParams.mu, 'AbsTol', 1e-12, ...
    'mu nu trebuie sa depinda de datele de validare.');
verifyEqual(testCase, m1.normParams.sigma, m0.normParams.sigma, 'AbsTol', 1e-12, ...
    'sigma nu trebuie sa depinda de datele de validare.');
end

function testAnchoredRegressionRecoversLevel(testCase)
% Cu ancorare pe persistenta, predictia trebuie sa fie pe scara tintei, nu
% pe scara diferentei.
d = testCase.TestData;
model = w5_train_lstm(d.seqs, d.y, 'TaskType', 'regression', ...
    'AnchorChannel', 1, 'MaxEpochs', 8, 'Verbose', false);
verifyEqual(testCase, model.anchorChannel, 1);
preds = w5_predict(model, d.seqs);
verifyLessThan(testCase, abs(mean(preds) - mean(d.y)), 0.5, ...
    'Predictiile ancorate trebuie sa revina pe scara tintei.');
end

function testSavedFileRecordsItsOwnPath(testCase)
% Ca la w4: model.savedTo se completeaza INAINTE de save().
d = testCase.TestData;
model = w5_train_lstm(d.seqs, d.y, 'TaskType', 'regression', ...
    'MaxEpochs', 3, 'Verbose', false, ...
    'SaveDir', d.outDir, 'FileName', 'unit_test_lstm_path.mat');
S = load(model.savedTo, 'model');
verifyEqual(testCase, S.model.savedTo, model.savedTo);
delete(model.savedTo);
end

function testUnseenValidationClassIsExcluded(testCase)
% Splitul fiind cronologic, validarea poate contine o clasa absenta din
% antrenament. Ea nu are voie sa devina <undefined> (o linie de NaN dupa
% onehotencode), altfel pierderea pe validare devine NaN si oprirea timpurie
% ('best-validation') alege orbeste.
d = testCase.TestData;
yTrain = d.yCls;                       % doar clasele 0 si 1
yVal   = d.yCls;
yVal(1) = 7;                           % clasa care nu apare in antrenament
verifyWarning(testCase, @() w5_train_lstm(d.seqs, yTrain, ...
    'TaskType', 'classification', 'MaxEpochs', 3, 'Verbose', false, ...
    'ValidationData', {d.seqs, yVal}), 'TIMRadar:UnseenValidationClass');
end


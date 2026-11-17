function [model, importance] = w4_train_random_forest(X, y, featureNames, varargin)
% W4_TRAIN_RANDOM_FOREST Saptamana 4: Random Forest real (Breiman), nu bagging simplu.
%
% Semnatura:
%   [model, importance] = w4_train_random_forest(X, y, featureNames, Name, Value, ...)
%
% Optiuni:
%   'TaskType'   'regression' | 'classification'  (obligatoriu daca lipseste TaskInfo)
%   'TaskInfo'   structura returnata de w3_extract_features (recomandat)
%   'NumTrees'   numarul de arbori                (implicit 300)
%   'SaveDir'    folder pentru salvare            (implicit '' = NU se salveaza)
%   'FileName'   numele fisierului .mat           (implicit 'model_random_forest.mat')
%   'Verbose'    logical                          (implicit true)
%
% ---------------------------------------------------------------------
% CE AVETI DE FACUT (Saptamana 4) - cautati apelurile todo(...)
% ---------------------------------------------------------------------
%   4.1  ancorarea pe persistenta la regresie (padurea invata SCHIMBAREA)
%   4.2  Random Forest de regresie: p/3 predictori pe ramificatie
%   4.3  Random Forest de clasificare: sqrt(p) predictori pe ramificatie
%   4.4  importanta predictorilor prin permutare Out-of-Bag
% Verificare: run_all_tests('Week', 4)
%
% UN RANDOM FOREST NU ESTE BAGGING SIMPLU. Breiman esantioneaza un SUBSET de
% predictori la fiecare ramificatie; cu 'NumVariablesToSample', 'all' arborii
% ar fi puternic corelati si agregarea ar castiga mult mai putin.
% Predictia se face prin w4_predict, care adauga ancora inapoi - nu apelati
% predict() direct pe model.modelObj la regresie.

p = inputParser;
p.addParameter('TaskType', '', @(x) ischar(x) || isstring(x));
p.addParameter('TaskInfo', struct(), @isstruct);
p.addParameter('NumTrees', 300, @(x) isnumeric(x) && isscalar(x) && x >= 1);
p.addParameter('AnchorFeature', 'arealRainRate', @(x) ischar(x) || isstring(x) || isempty(x));
p.addParameter('SaveDir', '', @(x) ischar(x) || isstring(x));
p.addParameter('FileName', 'model_random_forest.mat', @(x) ischar(x) || isstring(x));
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;
verbose = logical(o.Verbose);

if nargin < 3 || isempty(featureNames)
    featureNames = arrayfun(@(i) sprintf('f%d', i), 1:size(X, 2), 'UniformOutput', false);
end
if numel(featureNames) ~= size(X, 2)
    error('TIMRadar:FeatureNameMismatch', ...
        'featureNames are %d elemente dar X are %d coloane.', numel(featureNames), size(X, 2));
end

taskType = char(o.TaskType);
targetUnit = '';
if isfield(o.TaskInfo, 'type') && ~isempty(o.TaskInfo.type)
    taskType = o.TaskInfo.type;
    if isfield(o.TaskInfo, 'unit'), targetUnit = o.TaskInfo.unit; end
end
if isempty(taskType)
    error('TIMRadar:MissingTaskType', ...
        ['Tipul problemei trebuie dat explicit prin ''TaskType'' sau ''TaskInfo''. ' ...
         'Nu se mai deduce din valorile etichetelor.']);
end
if ~ismember(taskType, {'regression', 'classification'})
    error('TIMRadar:BadTaskType', 'TaskType trebuie sa fie regression sau classification.');
end

nPred = size(X, 2);
nTrees = round(o.NumTrees);

if strcmp(taskType, 'regression')
    % ANCORARE PE PERSISTENTA, la fel ca in w5_train_lstm.
    %
    % Un arbore nu poate prezice in afara intervalului tintelor din antrenament,
    % deci prezicand nivelul absolut padurea satureaza pe orice segment mai
    % ploios decat antrenamentul. Invatand SCHIMBAREA fata de ultima valoare
    % observata, tinta devine stationara, iar comparatia cu LSTM-ul din w6
    % masoara arhitectura, nu parametrizarea tintei.
    % 'AnchorFeature', '' dezactiveaza ancorarea, pentru a compara cele doua
    % formulari.
    anchorCol = resolve_anchor_column(featureNames, o.AnchorFeature);
    % TODO 4.1: yFit = tinta pe care o invata padurea.
    %   Fara ancora (anchorCol gol): tinta insasi, ca vector coloana.
    %   Cu ancora: tinta MINUS valoarea actuala a coloanei anchorCol din X.
    todo('4.1', 'yFit (ancorare pe persistenta)');

    % TODO 4.2: Random Forest de regresie.
    %   numVars = p/3 rotunjit in jos, minim 1 (p = nPred)
    %   tmpl    = templateTree cu 'MinLeafSize' 5 si 'NumVariablesToSample' numVars
    %   ens     = fitrensemble pe (X, yFit), 'Method' 'Bag', nTrees cicluri,
    %             'Learners' tmpl
    todo('4.2', 'numVars, tmpl, ens (regresie)');

    model.anchorColumn = anchorCol;
    if isempty(anchorCol)
        model.anchorFeature = '';
    else
        model.anchorFeature = featureNames{anchorCol};
    end
    % Tintele fizic nenegative: prognoza livrata se plafoneaza la 0, iar
    % metricile de mai jos se calculeaza pe exact acea prognoza.
    model.clampNonNegative = all(y >= 0);

    % Metricile se raporteaza pe SCARA TINTEI, nu pe scara diferentei: se
    % adauga ancora inapoi prin acelasi drum pe care il vor folosi w6 si main.
    model.taskType   = 'regression';
    model.featureNames = featureNames;
    model.modelObj   = ens;      % necesar deja aici: w4_predict il foloseste
    preds = w4_predict(model, X);
    model.targetUnit = targetUnit;
    model.trainR2    = r_squared(y(:), preds);
    model.trainRMSE  = sqrt(mean((y(:) - preds).^2));
    model.trainMAE   = mean(abs(y(:) - preds));
    model.oobLoss    = oobLoss(ens);                  % MSE out-of-bag (pe delta)
    model.oobRMSE    = sqrt(model.oobLoss);
    model.classOrder = [];
else
    % Random Forest de clasificare: sqrt(p) predictori pe ramificatie
    yc = categorical(y);
    % TODO 4.3: Random Forest de clasificare.
    %   numVars = sqrt(p) rotunjit, minim 1
    %   tmpl    = templateTree cu 'MinLeafSize' 1 si 'NumVariablesToSample' numVars
    %   ens     = fitcensemble pe (X, yc), 'Method' 'Bag', nTrees cicluri,
    %             'Learners' tmpl
    todo('4.3', 'numVars, tmpl, ens (clasificare)');

    preds = predict(ens, X);
    model.anchorColumn     = [];
    model.anchorFeature    = '';
    model.clampNonNegative = false;
    model.taskType         = 'classification';
    model.targetUnit       = targetUnit;
    model.trainingAccuracy = mean(preds == yc);
    model.oobLoss          = oobLoss(ens);            % rata de eroare out-of-bag
    model.oobAccuracy      = 1 - model.oobLoss;
    model.classOrder       = ens.ClassNames;
end

% ---------------------------------------------------------------------
% Importanta prin permutare Out-of-Bag (nebiasata)
% ---------------------------------------------------------------------
% TODO 4.4: rawImp = importanta prin permutare Out-of-Bag a ansamblului ens
%   (o singura functie MATLAB; cautati "oobPermuted" in documentatie).
%   De ce nu predictorImportance: castigul de impuritate favorizeaza
%   predictorii cu multe valori distincte.
todo('4.4', 'rawImp (importanta OOB prin permutare)');
impMethod = 'oobPermuted';
rawImp = rawImp(:).';
pos = max(rawImp, 0);
if sum(pos) > 0
    impPercent = 100 * pos / sum(pos);
else
    impPercent = zeros(size(pos));
end
[sortedImp, sortIdx] = sort(impPercent, 'descend');

importance.method       = impMethod;
importance.featureNames = featureNames;
importance.raw          = rawImp;
importance.values       = impPercent;
importance.sortedNames  = featureNames(sortIdx);
importance.sortedValues = sortedImp;
importance.rankingTable = table(featureNames(sortIdx)', sortedImp', ...
    'VariableNames', {'Caracteristica', 'ImportantaProcentuala'});

model.modelObj     = ens;
model.modelType    = 'random_forest';
model.featureNames = featureNames;
model.numTrees     = nTrees;
model.numVarsPerSplit = numVars;
model.nTrainSamples   = size(X, 1);
model.importance      = importance;

% ---------------------------------------------------------------------
% Salvare doar la cerere
% ---------------------------------------------------------------------
model.savedTo = '';
saveDir = char(o.SaveDir);
if ~isempty(saveDir)
    if ~isfolder(saveDir), mkdir(saveDir); end
    outPath = fullfile(saveDir, char(o.FileName));
    % savedTo se completeaza INAINTE de save, altfel modelul de pe disc are
    % campul gol si nu se mai poate spune de unde a fost incarcat.
    model.savedTo = outPath;
    save(outPath, 'model');
end

if verbose
    fprintf('   [w4] Random Forest %s: %d arbori, %d/%d predictori pe ramificatie\n', ...
        taskType, nTrees, numVars, nPred);
    if strcmp(taskType, 'regression')
        fprintf('   [w4] Train R2=%.4f RMSE=%.4f | OOB RMSE=%.4f\n', ...
            model.trainR2, model.trainRMSE, model.oobRMSE);
    else
        fprintf('   [w4] Train acuratete=%.4f | OOB acuratete=%.4f\n', ...
            model.trainingAccuracy, model.oobAccuracy);
    end
    fprintf('   [w4] Predictor dominant (%s): %s (%.1f%%)\n', ...
        impMethod, importance.sortedNames{1}, importance.sortedValues(1));
end
end

% =====================================================================
function col = resolve_anchor_column(featureNames, wanted)
% Coloana folosita ca ancora de persistenta. Implicit intensitatea medie pe
% suprafata, adica exact marimea prezisa in varianta B. Daca nu exista in setul
% de trasaturi (a fost eliminata ca fiind constanta, sau se antreneaza pe alt
% set), ancorarea se dezactiveaza in liniste - modelul ramane valid, doar
% neancorat, iar w4_predict nu adauga nimic.
col = [];
if isempty(wanted), return; end
k = find(strcmp(featureNames, char(wanted)), 1);
if ~isempty(k), col = k; end
end

% =====================================================================
function r2 = r_squared(y, yhat)
ss = sum((y - mean(y)).^2);
if ss <= 0
    r2 = NaN;
else
    r2 = 1 - sum((y - yhat).^2) / ss;
end
end

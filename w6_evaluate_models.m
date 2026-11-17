function [resultsTable, detail] = w6_evaluate_models(treeModel, lstmModel, X, y, taskInfo, varargin)
% W6_EVALUATE_MODELS Saptamana 6: Evaluare comparativa pe date NEVAZUTE.
%
% Semnatura:
%   [resultsTable, detail] = w6_evaluate_models(treeModel, lstmModel, X, y, taskInfo, Name, Value, ...)
%
% Optiuni:
%   'Idx'   indicii pe care se evalueaza (implicit: taskInfo.split.test)
%   'Name'  eticheta setului evaluat     (implicit: 'Test')
%
% ---------------------------------------------------------------------
% CE AVETI DE FACUT (Saptamana 6) - cautati apelurile todo(...)
% ---------------------------------------------------------------------
%   6.1  referinta climatologica / clasa majoritara, estimata pe TRAIN
%   6.2  metricile de regresie si scorul de abilitate fata de persistenta
%   6.3  Macro-F1 si scorul Brier la clasificare
% Verificare: run_all_tests('Week', 6)
%
% Evaluarea se face implicit pe segmentul de TEST, niciodata vazut. Un R2 nu
% inseamna nimic fara o baza de comparatie: la 30 de minute PERSISTENTA
% ("vremea ramane neschimbata") atinge R2 de ordinul 0.8-0.95, deci un model
% cu R2 = 0.85 poate fi mai slab decat "nu se schimba nimic".

p = inputParser;
p.addParameter('Idx', [], @(x) isnumeric(x) || islogical(x));
p.addParameter('Name', 'Test', @(x) ischar(x) || isstring(x));
p.parse(varargin{:});
o = p.Results;

if nargin < 5 || ~isstruct(taskInfo) || ~isfield(taskInfo, 'type')
    error('TIMRadar:MissingTaskInfo', ...
        'w6_evaluate_models are nevoie de taskInfo de la w3_extract_features.');
end

idx = o.Idx;
if isempty(idx)
    if isfield(taskInfo, 'split') && isfield(taskInfo.split, 'test')
        idx = taskInfo.split.test;
    else
        idx = (1:numel(y))';
    end
end
idx = idx(:);
if isempty(idx)
    error('TIMRadar:EmptyEvalSet', 'Setul de evaluare este gol.');
end

setName = char(o.Name);
Xe = X(idx, :);
ye = y(idx);
seqE = {};
if isfield(taskInfo, 'sequences') && ~isempty(taskInfo.sequences)
    seqE = taskInfo.sequences(idx);
end
persist = [];
if isfield(taskInfo, 'persistence') && ~isempty(taskInfo.persistence)
    persist = taskInfo.persistence(idx);
end

isRegression = strcmp(taskInfo.type, 'regression');

% Tintele fizic nenegative (intensitatea ploii) se prognozeaza nenegativ.
% Se plafoneaza o singura data, aici, pentru toate randurile de model, astfel
% incat RMSE/MAE descriu exact estimatorul afisat de main.m (si iesirea LSTM,
% ancora + delta negativ, nu poate deveni o intensitate negativa).
clampNonNegative = isRegression && all(y >= 0);

detail = struct();
detail.setName = setName;
detail.idx = idx;
detail.nSamples = numel(idx);
if isfield(taskInfo, 'timestamps')
    detail.timeRange = [min(taskInfo.timestamps(idx)), max(taskInfo.timestamps(idx))];
end

% ---------------------------------------------------------------------
% Predictii
% ---------------------------------------------------------------------
names = {};
predsAll = {};
scoresAll = {};

if ~isempty(treeModel)
    % w4_predict, NU predict(model.modelObj, ...): padurea de regresie este
    % antrenata pe schimbarea fata de persistenta, deci iesirea bruta este un
    % increment, nu o prognoza.
    if isRegression
        pr = w4_predict(treeModel, Xe);
        if clampNonNegative, pr = max(0, pr); end
        predsAll{end+1} = pr(:);
        scoresAll{end+1} = [];
    else
        [lab, sc] = w4_predict(treeModel, Xe);
        predsAll{end+1} = lab(:);
        scoresAll{end+1} = sc;
    end
    names{end+1} = 'Random Forest';
end

if ~isempty(lstmModel)
    if isempty(seqE)
        error('TIMRadar:NoSequences', ...
            'Modelul LSTM necesita taskInfo.sequences pentru evaluare.');
    end
    if isRegression
        pr = w5_predict(lstmModel, seqE);
        if clampNonNegative, pr = max(0, pr); end
        predsAll{end+1} = pr(:);
        scoresAll{end+1} = [];
    else
        [lab, sc] = w5_predict(lstmModel, seqE);
        predsAll{end+1} = lab(:);
        scoresAll{end+1} = sc;
    end
    names{end+1} = 'LSTM';
end

% Referinta 1: persistenta
if ~isempty(persist)
    predsAll{end+1} = persist(:);
    scoresAll{end+1} = [];
    names{end+1} = 'Persistenta (referinta)';
end

% Referinta 2: climatologie / clasa majoritara
%
% ATENTIE: o referinta se estimeaza pe segmentul de ANTRENAMENT, nu pe cel
% evaluat. Media etichetelor evaluate ar da prin constructie R2 = 0 si ar
% lasa "referinta" sa vada raspunsurile; la fel clasa majoritara.
% TODO 6.1: referinta climatologica.
%   a) yFit = etichetele segmentului de TRAIN (y(taskInfo.split.train)) daca
%      taskInfo are un split nevid, altfel ye; detail.baselineFrom = 'train'
%      respectiv 'set evaluat (fara split de train)'.
%   b) Regresie: adaugati la predsAll o predictie constanta = media lui yFit,
%      cate una pentru fiecare esantion evaluat, cu numele 'Climatologie (medie)'.
%      Clasificare: clasa cea mai frecventa in yFit, numele 'Clasa majoritara'.
%   (Numele trebuie sa fie exact acestea - le cauta testele si main.)
todo('6.1', 'referinta climatologica pe train');
scoresAll{end+1} = [];

% ---------------------------------------------------------------------
% Metrici
% ---------------------------------------------------------------------
M = numel(names);
if isRegression
    r2 = zeros(M, 1); rmse = zeros(M, 1); mae = zeros(M, 1); mx = zeros(M, 1);
    % TODO 6.2: pentru fiecare model i (predictii predsAll{i}, adevar ye):
    %   r2(i)   - cu r_squared de la sfarsitul fisierului
    %   rmse(i), mae(i), mx(i) (eroarea absoluta maxima)
    % Apoi skill [M x 1] = 1 - MSE_model / MSE_persistenta
    %   (1 = perfect, 0 = la fel ca persistenta, < 0 = mai slab).
    %   Persistenta este randul cu numele 'Persistenta (referinta)'; daca
    %   lipseste, skill = NaN peste tot. Feriti-va de impartirea la zero (eps).
    todo('6.2', 'metricile de regresie si SkillVsPersistenta');

    resultsTable = table(names(:), r2, rmse, mae, mx, skill, ...
        'VariableNames', {'Model', 'R2', 'RMSE', 'MAE', 'MaxError', 'SkillVsPersistenta'});
    detail.metric = 'regression';
else
    classes = unique(y);
    % Matricea de confuzie cuprinde si clasele PREZISE: un model sau o referinta
    % poate emite o clasa absenta din y (ex. o clasa invatata doar din esantioanele
    % OPERA), iar confusionmat cu un 'Order' incomplet arunca eroare.
    cmClasses = unique([classes(:); vertcat(predsAll{:})]);
    acc = zeros(M, 1); f1 = zeros(M, 1); brier = nan(M, 1); auc = nan(M, 1);
    cms = cell(M, 1);
    isBinary = numel(classes) == 2;
    posClass = max(classes);

    for i = 1:M
        pr = predsAll{i};
        acc(i) = mean(pr == ye);
        cm = confusionmat(ye, pr, 'Order', cmClasses);
        cms{i} = cm;
        % Macro-F1 se mediaza doar peste clasele care APAR in setul evaluat sau
        % in predictii. `cmClasses` vine din tot y, deci pe un segment scurt poate
        % contine clase absente; media peste ele le-ar puncta cu 0 si ar taia scorul.
        % (Ex.: un segment de test cu doar clasele 1 si 2 ar da unui model
        % perfect MacroF1 = 0.5 in loc de 1.0.)
        f1(i) = macro_f1(cm, ismember(cmClasses, ye) | ismember(cmClasses, pr));
        if isBinary
            % Persistenta si clasa majoritara sunt prognoze deterministe, dar au
            % un scor Brier perfect definit: probabilitatea este 0 sau 1. Astfel
            % referinta obligatorie apare si in coloana Brier.
            prob = positive_probability(scoresAll{i}, treeModel, lstmModel, names{i}, posClass);
            if isempty(prob)
                prob = double(pr(:) == posClass);
            end
            % TODO 6.3a: scorul Brier = media patratelor diferentei dintre
            %   probabilitatea prezisa `prob` si rezultatul real (1 daca
            %   ye == posClass, altfel 0). 0 = perfect; mai mic = mai bine.
            todo('6.3a', 'brier(i)');
            auc(i) = auc_score(double(ye == posClass), prob);
        end
    end

    if isBinary
        % Referinta climatologica probabilistica: rata de baza din antrenament.
        % yFit este deja segmentul de train (sau setul evaluat daca nu exista
        % split); accesul direct la taskInfo.split.train arunca eroare pentru un
        % taskInfo fara split, desi contractul functiei accepta asa ceva.
        baseRate = mean(yFit == posClass);
        detail.baseRate = baseRate;
        detail.baseRateBrier = mean((baseRate - double(ye == posClass)).^2);
        resultsTable = table(names(:), acc, f1, brier, auc, ...
            'VariableNames', {'Model', 'Acuratete', 'MacroF1', 'Brier', 'AUC'});
    else
        resultsTable = table(names(:), acc, f1, ...
            'VariableNames', {'Model', 'Acuratete', 'MacroF1'});
    end
    detail.confusion = cms;
    detail.classes = cmClasses;              % ordinea randurilor din detail.confusion
    detail.metric = 'classification';
end

detail.modelNames = names;
detail.predictions = predsAll;
detail.scores = scoresAll;
detail.actual = ye;
end

% =====================================================================
% (labels_to_numeric a fost eliminata: conversia etichetei categorice in
% valoarea clasei se face acum in w4_predict / w5_predict, simetric, ca sa nu
% existe doua drumuri diferite pentru aceeasi conversie.)

% =====================================================================
function prob = positive_probability(scores, treeModel, lstmModel, modelName, posClass)
prob = [];
if isempty(scores), return; end
if strcmp(modelName, 'Random Forest') && ~isempty(treeModel) && ~isempty(treeModel.classOrder)
    order = str2double(string(treeModel.classOrder));
elseif strcmp(modelName, 'LSTM') && ~isempty(lstmModel) && isfield(lstmModel, 'classNames')
    order = str2double(string(lstmModel.classNames));
else
    return;
end
k = find(order == posClass, 1);
if isempty(k) || k > size(scores, 2), return; end
prob = scores(:, k);
prob = min(max(prob(:), 0), 1);
end

% =====================================================================
function f1 = macro_f1(cm, scoreMask)
% scoreMask (optional): ce clase intra in medie. Clasele care nu apar nici in
% adevar nici in predictii nu sunt "gresite", sunt inaplicabile - a le media cu
% F1 = 0 deformeaza scorul in jos.
n = size(cm, 1);
if nargin < 2 || isempty(scoreMask), scoreMask = true(n, 1); end
scoreMask = logical(scoreMask(:));
f = zeros(n, 1);
% TODO 6.3b: F1 pentru fiecare clasa c, din matricea de confuzie cm
%   (randuri = clasa reala, coloane = clasa prezisa):
%     tp = cm(c,c); fp = restul coloanei c; fn = restul randului c
%     precizie = tp/(tp+fp), recall = tp/(tp+fn), F1 = media lor armonica
%   O clasa fara nicio predictie sau fara niciun exemplu real primeste F1 = 0
%   (atentie la impartirea la zero).
todo('6.3b', 'F1 pe clasa (macro_f1)');
if ~any(scoreMask)
    f1 = NaN;
else
    f1 = mean(f(scoreMask));
end
end

% =====================================================================
function a = auc_score(yBin, score)
% AUC prin statistica Mann-Whitney, cu tratarea egalitatilor prin ranguri medii.
nPos = sum(yBin == 1);
nNeg = sum(yBin == 0);
if nPos == 0 || nNeg == 0
    a = NaN;
    return;
end
ranks = tiedrank_local(score);
a = (sum(ranks(yBin == 1)) - nPos * (nPos + 1) / 2) / (nPos * nNeg);
end

% =====================================================================
function r = tiedrank_local(x)
x = x(:);
[s, i] = sort(x);
r = zeros(size(x));
n = numel(x);
k = 1;
while k <= n
    j = k;
    while j < n && s(j + 1) == s(k), j = j + 1; end
    r(i(k:j)) = (k + j) / 2;
    k = j + 1;
end
end

% =====================================================================
function r2 = r_squared(y, yhat)
ss = sum((y - mean(y)).^2);
if ss <= 0, r2 = NaN; else, r2 = 1 - sum((y - yhat).^2) / ss; end
end

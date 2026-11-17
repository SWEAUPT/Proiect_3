function [model, history] = w5_train_lstm(sequences, y, varargin)
% W5_TRAIN_LSTM Saptamana 5: Retea recurenta LSTM pe secvente temporale REALE.
%
% Semnatura:
%   [model, history] = w5_train_lstm(sequences, y, Name, Value, ...)
%
% Intrari:
%   sequences : cell {N x 1}, fiecare element [nCanale x nPasi] in ordine
%               cronologica, asa cum le produce w3_extract_features
%   y         : [N x 1] etichete
%
% Optiuni:
%   'TaskInfo'       structura de la w3 (recomandat)
%   'TaskType'       'regression' | 'classification'
%   'ValidationData' {seqVal, yVal} pentru oprire timpurie
%   'HiddenSize'     unitati LSTM                (implicit 32)
%   'MaxEpochs'      epoci maxime                (implicit 200)
%   'InitialLearnRate' rata de invatare (implicit 0.005 regresie, 0.001 clasificare)
%   'SaveDir'        folder de salvare           (implicit '' = NU se salveaza)
%   'FileName'       nume fisier                 (implicit 'model_lstm.mat')
%
% ---------------------------------------------------------------------
% CE AVETI DE FACUT (Saptamana 5) - cautati apelurile todo(...)
% ---------------------------------------------------------------------
%   5.1  normalizarea Z-score pe canale, estimata DOAR pe train
%   5.2  ancorarea pe persistenta la regresie (reteaua invata SCHIMBAREA)
%   5.3  arhitectura: LSTM(32) + Dropout(0.2) + FC(16) + ReLU + FC(iesire)
%   5.4  oprirea timpurie pe validare si antrenarea cu trainnet
% Verificare: run_all_tests('Week', 5)
%
% Intrarea este [nCanale x 12 pasi] = o ora reala de evolutie. Reteaua este
% intentionat mica (~6k parametri): cu cateva mii de esantioane, o retea mare
% memoreaza in loc sa invete.

p = inputParser;
p.addParameter('TaskInfo', struct(), @isstruct);
p.addParameter('TaskType', '', @(x) ischar(x) || isstring(x));
p.addParameter('ValidationData', {}, @(x) iscell(x));
p.addParameter('AnchorChannel', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
p.addParameter('HiddenSize', 32, @(x) isnumeric(x) && isscalar(x));
p.addParameter('MaxEpochs', 200, @(x) isnumeric(x) && isscalar(x));
p.addParameter('MiniBatchSize', 32, @(x) isnumeric(x) && isscalar(x));
p.addParameter('InitialLearnRate', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
p.addParameter('SaveDir', '', @(x) ischar(x) || isstring(x));
p.addParameter('FileName', 'model_lstm.mat', @(x) ischar(x) || isstring(x));
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;
verbose = logical(o.Verbose);

if ~iscell(sequences)
    error('TIMRadar:BadSequences', ...
        ['w5_train_lstm asteapta un cell array de secvente [canale x pasi]. ' ...
         'Foloseste taskInfo.sequences de la w3_extract_features.']);
end
N = numel(sequences);
if N ~= numel(y)
    error('TIMRadar:SizeMismatch', '%d secvente dar %d etichete.', N, numel(y));
end

[nCh, nStep] = size(sequences{1});
% Conventia este [canale x pasi]. Normalizarea transpune spre [pasi x canale],
% iar o orientare greșita este de obicei prinsa zgomotos de sequenceInputLayer,
% care refuza un numar de canale nepotrivit - cu o singura excepție: cand cele
% doua dimensiuni sunt EGALE, transpunerea greșita trece nedetectata si reteaua
% invata peste trasaturi in loc de peste timp, adica exact "LSTM ca perceptron
% scump" din antetul acestui fisier.
if nCh == nStep
    warning('TIMRadar:SquareSequence', ...
        ['Secventele sunt patrate (%d canale x %d pasi), deci o eventuala ' ...
         'inversare a axelor nu ar mai fi detectata automat. Conventia cerută ' ...
         'este [canale x pasi], asa cum le produce w3_extract_features.'], nCh, nStep);
end
if nStep < 2
    error('TIMRadar:DegenerateSequence', ...
        ['Secventele au un singur pas de timp (%d canale x %d pas). Un LSTM nu ' ...
         'are ce invata. Creste HistoryFrames in w3_extract_features.'], nCh, nStep);
end

taskType = char(o.TaskType);
targetUnit = '';
if isfield(o.TaskInfo, 'type') && ~isempty(o.TaskInfo.type)
    taskType = o.TaskInfo.type;
    if isfield(o.TaskInfo, 'unit'), targetUnit = o.TaskInfo.unit; end
end
if isempty(taskType)
    error('TIMRadar:MissingTaskType', ...
        'Tipul problemei trebuie dat prin ''TaskType'' sau ''TaskInfo''.');
end

% ---------------------------------------------------------------------
% Normalizare Z-score pe canale, estimata DOAR pe secventele de antrenament
% ---------------------------------------------------------------------
% TODO 5.1: mu si sigma, vectori coloana [nCh x 1] - media si abaterea
%   standard a FIECARUI canal peste toate secventele de antrenament si toti
%   pasii lor. Indiciu: cat(2, sequences{:}) le alatura intr-o matrice
%   [nCh x (N*nStep)]. Un canal constant ar da sigma = 0: inlocuiti-l cu 1.
%   Validarea si testul se normalizeaza cu ACEIASI parametri (normalize_seq).
todo('5.1', 'mu, sigma (normalizare doar pe train)');
normParams = struct('mu', mu, 'sigma', sigma);

Xtrain = normalize_seq(sequences, normParams);

hasVal = numel(o.ValidationData) == 2 && ~isempty(o.ValidationData{1});
if hasVal
    Xval = normalize_seq(o.ValidationData{1}, normParams);
    yvalRaw = o.ValidationData{2};
end

% ---------------------------------------------------------------------
% Arhitectura, dimensionata pentru cateva sute de esantioane
% ---------------------------------------------------------------------
isRegression = strcmp(taskType, 'regression');

% RATA DE INVATARE IMPLICITA DEPINDE DE TIPUL PROBLEMEI.
% Cu 0.005 pentru toate cazurile, ramura de clasificare colapsa frecvent pe
% clasa majoritara.
%
% Valorile vin dintr-o baleiere pe SEGMENTUL DE VALIDARE, niciodata pe test
% (mediana pe 3 seminte, evaluata cu w6_evaluate_models pe split.val; arhiva
% 2026-09-08, train 1666 / val 339):
%
%   varianta B (regresie)          varianta C (clasificare binara)
%   LR       R2 val                LR       Brier val   Acuratete val
%   0.01     0.9312                0.01     0.0263      0.9558
%   0.005    0.9344                0.005    0.0255      0.9617   <- cel mai bun
%   0.002    0.9402  <- cel mai bun 0.002   0.0321      0.9617
%   0.001    0.9359                0.001    0.0311      0.9617
%
% Marjele sunt mici si sunt mediane pe 3 seminte, deci ordinea nu este puternic
% stabila. Nu tratati aceste valori ca optime; reluati baleierea pe validare
% cand se schimba arhiva - niciodata pe test.
if isempty(o.InitialLearnRate)
    if isRegression
        learnRate = 0.002;
    else
        learnRate = 0.005;
    end
else
    learnRate = o.InitialLearnRate;
end
if isRegression
    % ANCORARE PE PERSISTENTA. Reteaua invata SCHIMBAREA fata de ultima valoare
    % observata, nu nivelul absolut. Este formularea standard in nowcasting si
    % evita o problema reala: prezicand nivelul direct, reteaua generalizeaza
    % prost (R2 0.84 pe antrenament, -0.38 pe test), pentru ca nivelul
    % mediu se deplaseaza intre perioade, iar reteaua nu extrapoleaza. Diferenta
    % este stationara, deci invatabila. Ancora se recupereaza din secventa
    % insasi la momentul predictiei, deci nu apare nicio intrare suplimentara.
    anchorCh = resolve_anchor_channel(o.TaskInfo, o.AnchorChannel, nCh);
    % TODO 5.2: Ytrain [N x 1].
    %   Fara ancora (anchorCh gol): tinta y, ca vector coloana.
    %   Cu ancora: y minus valoarea canalului anchorCh la ULTIMUL pas al
    %   fiecarei secvente (nenormalizata - folositi `sequences`, nu Xtrain).
    %   Blocul pentru validare, mai jos (anchorVal), face exact acelasi lucru.
    todo('5.2', 'Ytrain (ancorare pe persistenta)');
    outSize = 1;
    lossFcn = 'mse';
    classValues = [];
else
    anchorCh = [];
    classValues = unique(y(:));
    Ytrain = onehotencode(categorical(y(:), classValues), 2);
    outSize = numel(classValues);
    lossFcn = 'crossentropy';
end

% TODO 5.3: vectorul coloana de straturi `layers`, in ordine:
%   sequenceInputLayer cu nCh canale
%   lstmLayer cu round(o.HiddenSize) unitati, 'OutputMode' 'last'
%       (ne intereseaza starea dupa ultimul pas, nu toata secventa)
%   dropoutLayer 0.2
%   fullyConnectedLayer 16, apoi reluLayer
%   fullyConnectedLayer cu outSize iesiri
%   (softmax-ul pentru clasificare se adauga mai jos, nu aici)
todo('5.3', 'layers (arhitectura LSTM)');

if ~isRegression
    layers = [layers; softmaxLayer('Name', 'softmax')];
end

net0 = dlnetwork(layers);

optArgs = { ...
    'MaxEpochs', round(o.MaxEpochs), ...
    'MiniBatchSize', min(round(o.MiniBatchSize), N), ...
    'InitialLearnRate', learnRate, ...
    'GradientThreshold', 1, ...
    'L2Regularization', 1e-4, ...
    'Shuffle', 'every-epoch', ...
    'Plots', 'none', ...
    'Verbose', false};

if hasVal
    if isRegression
        if ~isempty(anchorCh)
            anchorVal = cellfun(@(s) s(anchorCh, end), o.ValidationData{1}(:));
            Yval = yvalRaw(:) - anchorVal;
        else
            Yval = yvalRaw(:);
        end
    else
        % Splitul este CRONOLOGIC, deci segmentul de validare poate contine o
        % clasa care nu apare deloc in antrenament. categorical(...) o marcheaza
        % <undefined>, onehotencode produce o linie de NaN, pierderea pe validare
        % devine NaN si oprirea timpurie ('best-validation') alege orbeste.
        % Esantioanele fara corespondent se exclud explicit, cu avertisment.
        cval = categorical(yvalRaw(:), classValues);
        unseen = isundefined(cval);
        if any(unseen)
            warning('TIMRadar:UnseenValidationClass', ...
                ['%d din %d esantioane de validare au clase absente din antrenament ' ...
                 'si au fost excluse din validare.'], sum(unseen), numel(cval));
            Xval = Xval(~unseen);
            cval = cval(~unseen);
        end
        % categories(cval) ramane classValues, deci numarul de coloane nu se schimba.
        Yval = onehotencode(cval, 2);
        hasVal = ~isempty(Xval);
    end
end

% TODO 5.4: oprire timpurie si antrenare.
%   a) Daca hasVal, adaugati la optArgs perechile:
%        'ValidationData' {Xval, Yval}
%        'ValidationFrequency' - o data pe epoca: N / dimensiunea minibatch-ului
%        'ValidationPatience' 15
%        'OutputNetwork' 'best-validation'  (se pastreaza cea mai buna retea
%                                            pe validare, nu ultima)
%   b) opts = trainingOptions('adam', optArgs{:});
%   c) net = trainnet(Xtrain, Ytrain, net0, lossFcn, opts), cronometrat:
%      trainSeconds = durata in secunde (tic/toc).
todo('5.4', 'optiunile de validare si trainnet');

% ---------------------------------------------------------------------
% Model + metrici pe setul primit
% ---------------------------------------------------------------------
model.modelObj    = net;
model.modelType   = 'lstm';
model.taskType    = taskType;
model.targetUnit  = targetUnit;
model.normParams  = normParams;
model.numChannels = nCh;
model.numSteps    = nStep;
model.seqOrientation = 'channels x steps (intrare) -> steps x channels (trainnet)';
model.hiddenSize  = round(o.HiddenSize);
model.architecture = sprintf('LSTM(%d) + Dropout(0.2) + FC(16) + FC(%d)', ...
    round(o.HiddenSize), outSize);
model.nTrainSamples = N;
model.anchorChannel = anchorCh;

if isRegression
    preds = w5_predict(model, sequences);
    model.trainR2   = r_squared(y(:), preds);
    model.trainRMSE = sqrt(mean((y(:) - preds).^2));
    model.trainMAE  = mean(abs(y(:) - preds));
else
    model.classValues = classValues;
    model.classNames  = cellstr(string(classValues));
    lab = w5_predict(model, sequences);
    model.trainingAccuracy = mean(lab == y(:));
end

history = struct('maxEpochs', round(o.MaxEpochs), 'nTrain', N, ...
    'nChannels', nCh, 'nSteps', nStep, ...
    'architecture', model.architecture, ...
    'trainSeconds', trainSeconds, 'usedValidation', hasVal);

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
    fprintf('   [w5] %s pe secvente [%d canale x %d pasi], %d esantioane, %.0fs\n', ...
        model.architecture, nCh, nStep, N, trainSeconds);
    if isRegression
        fprintf('   [w5] Train R2=%.4f RMSE=%.4f\n', model.trainR2, model.trainRMSE);
    else
        fprintf('   [w5] Train acuratete=%.4f\n', model.trainingAccuracy);
    end
end
end

% =====================================================================
function Xn = normalize_seq(seqs, np)
% w3 produce secvente [canale x pasi]. API-ul curent trainnet/minibatchpredict
% asteapta insa fiecare secventa ca [pasi x canale] (timpul pe randuri), spre
% deosebire de vechiul trainNetwork, care folosea conventia inversa. Transpunerea
% se face aici, intr-un singur loc, ca sa nu se strecoare in fiecare apelant.
Xn = cell(numel(seqs), 1);
for i = 1:numel(seqs)
    Xn{i} = ((seqs{i} - np.mu) ./ np.sigma).';
end
end

% =====================================================================
function ch = resolve_anchor_channel(taskInfo, explicitCh, nCh)
% Canalul folosit ca ancora de persistenta: implicit intensitatea medie pe
% suprafata, adica exact marimea prezisa in varianta B.
ch = [];
if ~isempty(explicitCh)
    ch = round(explicitCh);
elseif isfield(taskInfo, 'baseFeatureNames') && ~isempty(taskInfo.baseFeatureNames)
    k = find(strcmp(taskInfo.baseFeatureNames, 'arealRainRate'), 1);
    if ~isempty(k), ch = k; end
end
if ~isempty(ch) && (ch < 1 || ch > nCh)
    warning('TIMRadar:BadAnchor', 'Canalul de ancorare %d este in afara intervalului; se ignora.', ch);
    ch = [];
end
end

% =====================================================================
function r2 = r_squared(y, yhat)
ss = sum((y - mean(y)).^2);
if ss <= 0, r2 = NaN; else, r2 = 1 - sum((y - yhat).^2) / ss; end
end

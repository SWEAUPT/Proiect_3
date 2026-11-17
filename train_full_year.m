function results = train_full_year(dataDir, variant, varargin)
% TRAIN_FULL_YEAR Antrenament pe intreaga arhiva locala, fara augmentare.
%
% Semnatura:
%   results = train_full_year()
%   results = train_full_year(dataDir, variant, Name, Value, ...)
%
% Optiuni acceptate:
%   'HorizonMinutes' (implicit 30), 'MaxEpochs' (implicit 200),
%   'NumTrees' (implicit 500), 'SaveDir' (implicit <pwd>/models),
%   'Opera' ('auto' | true | false; implicit 'auto' = esantioane OPERA adaugate
%           la train-ul RF pentru A si C, vezi opera_training_rows)
%
% Doar acestea: o optiune necunoscuta produce o eroare, in loc sa para ca a
% fost aplicata.
%
% Functia este un simplu ambalaj peste modulele w1-w6 si nu dubleaza nicio
% logica a lor, deci modelele produse aici folosesc exact acelasi spatiu de
% trasaturi ca main.m.
%
% DESPRE "FULL YEAR"
% ---------------------------------------------------------------------
% Numele este mostenit. Sursa ANM pastreaza o fereastra rulanta de ~3.5 zile,
% deci un an nu poate fi descarcat dintr-o data: se acumuleaza in timp prin
% rulari repetate ale lui w1_sync_archive. Functia raporteaza perioada efectiv
% acoperita si avertizeaza cand arhiva este mult mai scurta de un an.

if nargin < 1 || isempty(dataDir), dataDir = fullfile(pwd, 'data'); end
if nargin < 2 || isempty(variant), variant = 'B'; end
variant = upper(char(variant));

p = inputParser;
p.addParameter('HorizonMinutes', 30, @isnumeric);
p.addParameter('MaxEpochs', 200, @isnumeric);
p.addParameter('NumTrees', 500, @isnumeric);
p.addParameter('SaveDir', fullfile(pwd, 'models'), @(x) ischar(x) || isstring(x));
p.addParameter('Opera', 'auto', @(x) islogical(x) || isnumeric(x) || ...
    (ischar(x) || isstring(x)) && strcmpi(x, 'auto'));
p.parse(varargin{:});
o = p.Results;
saveDir = char(o.SaveDir);
if ~isfolder(saveDir), mkdir(saveDir); end

fprintf('\n=================================================================\n');
fprintf('   ANTRENAMENT PE ARHIVA COMPLETA - DATE REALE, FARA AUGMENTARE\n');
fprintf('   Varianta %s | orizont %g min | director %s\n', variant, o.HorizonMinutes, dataDir);
fprintf('=================================================================\n\n');

% -----------------------------------------------------------------
fprintf('[1/4] Construirea setului de date...\n');
[X, y, featureNames, taskInfo] = w3_extract_features(variant, ...
    'DataDir', dataDir, 'HorizonMinutes', o.HorizonMinutes);

% Intervalul calendaristic NU este acoperirea: golurile din sincronizarile
% ratate (62.9 h, 132.1 h, apoi 4-18 octombrie) il umfla, exact defectul deja
% corectat in w3. Acoperirea reala = cadre utilizate x pasul de scanare.
spanDays = days(taskInfo.source.dateRange(2) - taskInfo.source.dateRange(1));
coverageDays = taskInfo.source.nUsed * taskInfo.source.stepMinutes / (60 * 24);
fprintf('   Interval: %s -> %s (%.2f zile calendaristice, %.2f zile cu date)\n', ...
    string(taskInfo.source.dateRange(1)), string(taskInfo.source.dateRange(2)), ...
    spanDays, coverageDays);
if coverageDays < 365
    warning('TIMRadar:ShortArchive', ...
        ['Arhiva contine %.2f zile de date, nu un an. Sursa ANM pastreaza doar ~3.5 zile, ' ...
         'deci un an se poate obtine doar acumuland in timp prin w1_sync_archive.'], coverageDays);
end

tr = taskInfo.split.train;
va = taskInfo.split.val;
te = taskInfo.split.test;

% Aceeasi verificare ca in main.m. Fara ea, un segment de validare gol trece
% neobservat: w5_train_lstm renunta in tacere la oprirea timpurie si macina
% toate epocile pe un set mic, iar abia la evaluare, minute mai tarziu, w6
% arunca TIMRadar:EmptyEvalSet - fara nicio indicatie ca splitul e cauza.
if isempty(tr) || isempty(va) || isempty(te)
    error('TIMRadar:SplitTooSmall', ...
        ['Impartirea temporala a lasat un segment gol (train %d / val %d / test %d) ' ...
         'pentru %d esantioane si embargo de %d cadre. Arhiva este prea scurta ' ...
         'pentru orizontul de %g minute; ruleaza w1_sync_archive() si reia.'], ...
        numel(tr), numel(va), numel(te), taskInfo.nSamples, ...
        taskInfo.split.embargo, o.HorizonMinutes);
end

% -----------------------------------------------------------------
fprintf('\n[2/4] Random Forest...\n');
[Xo, yo, operaInfo] = opera_training_rows(variant, featureNames, taskInfo, 'Use', o.Opera);
[rfModel, rfImportance] = w4_train_random_forest([X(tr, :); Xo], [y(tr); yo], featureNames, ...
    'TaskInfo', taskInfo, 'NumTrees', o.NumTrees, ...
    'SaveDir', saveDir, 'FileName', sprintf('rf_full_%s.mat', variant));

% -----------------------------------------------------------------
fprintf('\n[3/4] LSTM...\n');
[lstmModel, lstmHistory] = w5_train_lstm(taskInfo.sequences(tr), y(tr), ...
    'TaskInfo', taskInfo, 'ValidationData', {taskInfo.sequences(va), y(va)}, ...
    'MaxEpochs', o.MaxEpochs, ...
    'SaveDir', saveDir, 'FileName', sprintf('lstm_full_%s.mat', variant));

% -----------------------------------------------------------------
fprintf('\n[4/4] Evaluare pe validare si pe test...\n\n');
[valTable, valDetail] = w6_evaluate_models(rfModel, lstmModel, X, y, taskInfo, ...
    'Idx', va, 'Name', 'Validare');
disp(valTable);
[testTable, testDetail] = w6_evaluate_models(rfModel, lstmModel, X, y, taskInfo, ...
    'Idx', te, 'Name', 'Test');
disp(testTable);

results = struct( ...
    'variant', variant, ...
    'horizonMinutes', o.HorizonMinutes, ...
    'nSamples', taskInfo.nSamples, ...
    'nTrain', numel(tr), 'nVal', numel(va), 'nTest', numel(te), ...
    'opera', operaInfo, ...
    'spanDays', spanDays, ...
    'coverageDays', coverageDays, ...
    'dateRange', taskInfo.source.dateRange, ...
    'featureNames', {featureNames}, ...
    'rfImportance', rfImportance, ...
    'lstmHistory', lstmHistory, ...
    'valTable', valTable, ...
    'testTable', testTable, ...
    'valDetail', valDetail, ...
    'testDetail', testDetail, ...
    'savedTo', saveDir);

save(fullfile(saveDir, sprintf('results_full_%s.mat', variant)), 'results');
fprintf('\nModele si rezultate salvate in: %s\n\n', saveDir);
end

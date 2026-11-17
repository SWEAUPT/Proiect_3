% MAIN Punct unic de intrare pentru proiectul TIM Radar Lab.
%
% Ruleaza fluxul complet al celor 7 saptamani pe arhiva radar locala:
%   w1 sincronizare -> w2 curatare -> w3 set de date de prognoza ->
%   w4 Random Forest -> w5 LSTM -> w6 evaluare pe test -> w7 dashboard
%
% CONFIGURARE
%   PROJECT_VARIANT : 'A', 'B' sau 'C' (vezi variante_proiect_studenti.md)
%   HORIZON_MINUTES : cat de departe in viitor se prognozeaza
%   SYNC_FIRST      : true = descarca intai cadrele noi de la ANM
%
% NOTA IMPORTANTA DESPRE DATE
%   Serverul ANM pastreaza doar o fereastra rulanta de ~3.5 zile. Arhiva
%   locala din data/ este singura copie a cadrelor mai vechi si nu poate fi
%   recuperata. Nu stergeti fisiere .hdf din data/.

PROJECT_VARIANT = 'C';
HORIZON_MINUTES = 30;
SYNC_FIRST      = true;
DO_SPEAK        = true;
RANDOM_SEED     = 42;     % [] = nedeterminist

clc;

% Reproductibilitate: Random Forest-ul face bagging, iar LSTM-ul initializeaza
% ponderi si amesteca minibatch-urile. Fara samanta fixa, doua rulari succesive
% dau cifre diferite si tabelul din raport nu mai poate fi reprodus.
if ~isempty(RANDOM_SEED)
    rng(RANDOM_SEED);
end
fprintf('\n=================================================================\n');
fprintf('   TIM RADAR LAB - PROGNOZA RADAR PRIN INVATARE AUTOMATA\n');
fprintf('   Varianta %s | orizont %g minute\n', PROJECT_VARIANT, HORIZON_MINUTES);
fprintf('=================================================================\n\n');

dataDir = fullfile(pwd, 'data');
modelDir = fullfile(pwd, 'models');
if ~isfolder(modelDir), mkdir(modelDir); end

% -----------------------------------------------------------------
% Saptamana 1: sincronizarea arhivei (optional)
% -----------------------------------------------------------------
if SYNC_FIRST
    fprintf('[S1] Sincronizare arhiva cu MeteoRomania...\n');
    w1_sync_archive(dataDir);
else
    fprintf('[S1] Se foloseste arhiva locala existenta (SYNC_FIRST = false).\n');
end

% -----------------------------------------------------------------
% Saptamanile 2-3: statistici fizice pe cadru si setul de date de prognoza
% -----------------------------------------------------------------
fprintf('\n[S2+S3] Construirea setului de date de prognoza...\n');
[X, y, featureNames, taskInfo] = w3_extract_features(PROJECT_VARIANT, ...
    'DataDir', dataDir, 'HorizonMinutes', HORIZON_MINUTES);

tr = taskInfo.split.train;
va = taskInfo.split.val;
te = taskInfo.split.test;

% Cu o arhiva foarte scurta, embargoul poate consuma complet un segment; se
% opreste aici cu un mesaj clar, nu mai jos cu o eroare de indexare.
if isempty(tr) || isempty(va) || isempty(te)
    error('TIMRadar:SplitTooSmall', ...
        ['Impartirea temporala a lasat un segment gol (train %d / val %d / test %d) ' ...
         'pentru %d esantioane si embargo de %d cadre. Arhiva este prea scurta ' ...
         'pentru orizontul de %g minute; ruleaza w1_sync_archive() si reia.'], ...
        numel(tr), numel(va), numel(te), taskInfo.nSamples, ...
        taskInfo.split.embargo, HORIZON_MINUTES);
end

% -----------------------------------------------------------------
% Saptamana 4: Random Forest, antrenat DOAR pe segmentul de train
% -----------------------------------------------------------------
% Variantele A si C castiga pe validare cu esantioane OPERA adaugate la train
% (vezi opera_training_rows); validarea si testul raman doar TIM.
fprintf('\n[S4] Antrenare Random Forest...\n');
[Xo, yo] = opera_training_rows(PROJECT_VARIANT, featureNames, taskInfo);
[treeModel, importance] = w4_train_random_forest([X(tr, :); Xo], [y(tr); yo], featureNames, ...
    'TaskInfo', taskInfo, 'NumTrees', 300, ...
    'SaveDir', modelDir, 'FileName', sprintf('rf_variant_%s.mat', PROJECT_VARIANT));

% -----------------------------------------------------------------
% Saptamana 5: LSTM pe secvente reale, cu validare pentru oprire timpurie
% -----------------------------------------------------------------
fprintf('\n[S5] Antrenare LSTM...\n');
[lstmModel, lstmHistory] = w5_train_lstm(taskInfo.sequences(tr), y(tr), ...
    'TaskInfo', taskInfo, 'ValidationData', {taskInfo.sequences(va), y(va)}, ...
    'MaxEpochs', 150, ...
    'SaveDir', modelDir, 'FileName', sprintf('lstm_variant_%s.mat', PROJECT_VARIANT));

% -----------------------------------------------------------------
% Saptamana 6: evaluare pe segmentul de TEST, niciodata vazut
% -----------------------------------------------------------------
fprintf('\n[S6] Evaluare pe segmentul de test (%d esantioane, %s -> %s):\n\n', ...
    numel(te), string(taskInfo.timestamps(te(1))), string(taskInfo.timestamps(te(end))));
[resultsTable, evalDetail] = w6_evaluate_models(treeModel, lstmModel, X, y, taskInfo);
disp(resultsTable);

if strcmp(taskInfo.type, 'regression')
    fprintf(['\nCiteste tabelul asa: SkillVsPersistenta > 0 inseamna ca modelul bate\n' ...
             'prognoza triviala "vremea ramane neschimbata". Valoare negativa inseamna\n' ...
             'ca modelul este mai slab decat sa nu faci nimic.\n']);
elseif isfield(evalDetail, 'baseRateBrier')
    fprintf('\nScor Brier al referintei climatologice (rata de baza %.3f): %.4f\n', ...
        evalDetail.baseRate, evalDetail.baseRateBrier);
end

% -----------------------------------------------------------------
% Saptamana 7: prognoza pentru ACUM + dashboard
% -----------------------------------------------------------------
fprintf('\n[S7] Prognoza pe cel mai recent cadru si dashboard...\n');

if ~taskInfo.live.available
    warning('Nu exista un cadru recent cu istoric complet; se omite prognoza live.');
    predValue = [];
else
    live = taskInfo.live;
    fprintf('   Cadru de baza: %s (valabil pentru %s)\n', ...
        string(live.timestamp), string(live.validTime));

    if strcmp(taskInfo.type, 'regression')
        % w4_predict / w5_predict, nu predict() direct: ambele modele sunt
        % antrenate pe schimbarea fata de persistenta si isi adauga ancora
        % inapoi in interior.
        predValue = max(0, w4_predict(treeModel, live.X));
        predLSTM  = max(0, w5_predict(lstmModel, live.sequence));
        fprintf('   Random Forest: %.4f %s | LSTM: %.4f %s | persistenta: %.4f %s\n', ...
            predValue, taskInfo.unit, predLSTM, taskInfo.unit, live.persistence, taskInfo.unit);
    else
        [labRF, scoreRF] = w4_predict(treeModel, live.X);
        classOrder = str2double(string(treeModel.classOrder));
        if strcmp(PROJECT_VARIANT, 'C')
            kPos = find(classOrder == 1, 1);
            predValue = 100 * scoreRF(kPos);
            fprintf('   Probabilitate de ploaie extinsa: %.1f%%\n', predValue);
        else
            predValue = labRF;      % w4_predict returneaza deja valoarea clasei
            fprintf('   Clasa prognozata: %d (%s)\n', predValue, ...
                taskInfo.classNames{max(1, min(end, predValue))});
        end
    end
end

% Cadrul afisat in dashboard trebuie sa fie EXACT cadrul pe care s-a facut
% prognoza, altfel hartile si cardul descriu momente diferite.
%
% Fara esantion live se ia cel mai recent cadru PVOL care se poate citi: ordinea
% vine din NUMELE fisierului (momentul scanarii), nu din data de pe disc, iar
% cadrele IMAGE (PCAPPI, alta geometrie, excluse din antrenament) se sar.
if taskInfo.live.available
    frame = radar_read_frame(fullfile(dataDir, char(taskInfo.live.file)));
else
    latest = dir(fullfile(dataDir, 'TIM_*dBZ.hdf'));
    [~, ordName] = sort({latest.name});      % numele contine timestamp-ul scanarii
    frame = [];
    for k = flip(ordName)
        if latest(k).bytes == 0, continue; end
        try
            F = radar_read_frame(fullfile(dataDir, latest(k).name));
        catch
            continue;
        end
        if strcmp(F.product, 'PVOL'), frame = F; break; end
    end
    if isempty(frame)
        error('TIMRadar:NoFrame', 'Niciun cadru PVOL lizibil in %s.', dataDir);
    end
end
[~, frameStats] = w2_clean_and_stats(frame);

dashboardFig = w7_main_dashboard(frame, frameStats, ...
    'Prediction', predValue, 'TaskInfo', taskInfo); %#ok<NASGU>

% -----------------------------------------------------------------
% Anunt vocal
% -----------------------------------------------------------------
if DO_SPEAK && ~isempty(predValue)
    speak_forecast(PROJECT_VARIANT, predValue, 'TaskInfo', taskInfo);
end

fprintf('\n=================================================================\n');
fprintf('   FLUX COMPLET. Modele salvate in: %s\n', modelDir);
fprintf('=================================================================\n\n');

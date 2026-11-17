function results = run_all_tests(varargin)
% RUN_ALL_TESTS Suita completa de teste pentru proiectul TIM Radar.
%
% Semnatura:
%   results = run_all_tests()
%   results = run_all_tests('Week', 3)     % doar testele saptamanii 3
%
% ---------------------------------------------------------------------
% NOTE
% ---------------------------------------------------------------------
% - Pe cale se adauga doar radacina si tests/, nu data/ (mii de fisiere HDF).
% - Numararea testelor vine direct din obiectele TestResult, inclusiv cand un
%   fisier de test nu poate fi incarcat.
% - Testele nu suprascriu modelele reale din models/ (vezi test_w4/test_w5).

p = inputParser;
p.addParameter('Week', [], @(x) isempty(x) || isnumeric(x));
p.parse(varargin{:});
week = p.Results.Week;

root = fileparts(mfilename('fullpath'));
testDir = fullfile(root, 'tests');
addpath(root);
addpath(testDir);

fprintf('\n========================================================\n');
fprintf('   TESTE AUTOMATE - PROIECT TIM RADAR (SAPTAMANILE 1-7)\n');
fprintf('========================================================\n\n');

if isempty(week)
    files = dir(fullfile(testDir, 'test_w*.m'));
    [~, ord] = sort({files.name});
    files = files(ord);
    suitePaths = fullfile(testDir, {files.name});
else
    suitePaths = {fullfile(testDir, sprintf('test_w%d.m', week))};
    if ~isfile(suitePaths{1})
        error('TIMRadar:NoSuchSuite', 'Nu exista %s', suitePaths{1});
    end
end

allResults = [];
loadErrors = {};
for i = 1:numel(suitePaths)
    [~, name] = fileparts(suitePaths{i});
    fprintf('[%s] ', name);
    try
        r = runtests(suitePaths{i});
        allResults = [allResults, r]; %#ok<AGROW>
        nPass = sum([r.Passed]);
        nFail = sum([r.Failed]);
        nInc  = sum([r.Incomplete]);
        nTot  = numel(r);
        % Esecul se anunta INAINTE de "sarite": o suita cu 3 trecute, 1 esuat
        % si 1 sarit trebuie sa afiseze cuvantul ESUAT, nu doar "1 sarite".
        if nFail > 0
            fprintf('ESUAT (%d trecute, %d esuate, %d sarite din %d)\n', ...
                nPass, nFail, nInc, nTot);
        elseif nInc > 0
            fprintf('%d/%d trecute, %d sarite\n', nPass, nTot, nInc);
        else
            fprintf('OK (%d/%d)\n', nPass, nTot);
        end
    catch ME
        % O suita care nu se INCARCA nu produce niciun TestResult, deci nu ar
        % intra in totaluri si raportul final ar spune "Toate testele au trecut".
        % Se contorizeaza explicit ca esec.
        loadErrors{end+1} = sprintf('%s: %s', name, ...
            regexprep(ME.message, '[\r\n]+', ' ')); %#ok<AGROW>
        fprintf('EROARE LA INCARCARE: %s\n', ME.message);
    end
end

if isempty(allResults)
    warning('TIMRadar:NoTestsRan', 'Niciun test nu a rulat.');
    results = struct('passed', 0, 'failed', 0, 'incomplete', 0, 'total', 0, ...
        'percent', NaN, 'loadErrors', {loadErrors}, 'details', []);
    return;
end

passed = sum([allResults.Passed]);
failed = sum([allResults.Failed]);
incomplete = sum([allResults.Incomplete]);
total = numel(allResults);
pct = 100 * passed / max(total, 1);

fprintf('\n--------------------------------------------------------\n');
fprintf('REZULTAT: %d trecute, %d esuate, %d sarite din %d (%.1f%%)\n', ...
    passed, failed, incomplete, total, pct);
fprintf('Durata totala: %.1f s\n', sum([allResults.Duration]));
fprintf('--------------------------------------------------------\n\n');

if ~isempty(loadErrors)
    fprintf('Suite care NU s-au incarcat (testele lor nu sunt in totalurile de mai sus):\n');
    for i = 1:numel(loadErrors)
        fprintf('  - %s\n', loadErrors{i});
    end
    fprintf('\n');
end

if failed > 0
    fprintf('Teste esuate:\n');
    for r = allResults([allResults.Failed])
        fprintf('  - %s\n', r.Name);
    end
    fprintf('\n');
    warning('TIMRadar:TestsFailed', '%d teste au esuat.', failed);
end

if ~isempty(loadErrors)
    warning('TIMRadar:SuiteLoadFailed', ...
        ['%d suite de teste nu s-au putut incarca si nu au fost rulate. ' ...
         'Rezultatul de mai sus NU acopera intreg proiectul.'], numel(loadErrors));
elseif failed == 0 && incomplete > 0
    fprintf('Toate testele rulate au trecut; %d au fost sarite (date sau retea indisponibile).\n\n', incomplete);
elseif failed == 0
    fprintf('Toate testele au trecut.\n\n');
end

results = struct('passed', passed, 'failed', failed, 'incomplete', incomplete, ...
    'total', total, 'percent', pct, 'loadErrors', {loadErrors}, 'details', allResults);
end

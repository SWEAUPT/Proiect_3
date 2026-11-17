function report = w1_sync_archive(localDir, product)
% W1_SYNC_ARCHIVE Descarca incremental TOATE cadrele noi de pe MeteoRomania.
%
% Completeaza arhiva locala fara a sterge sau rescrie nimic: fisierele care
% exista deja local sunt sarite. Ruleaza-l periodic pentru a nu pierde cadre.
%
% Utilizare:
%   w1_sync_archive();                     % data/ , produs dBZ
%   w1_sync_archive('data', 'dBZ');
%   report = w1_sync_archive();            % struct cu statistici
%
% Iesire:
%   report.existing   - cadre deja prezente local
%   report.downloaded - cadre noi descarcate acum
%   report.failed     - cadre care au esuat
%   report.firstLocal - primul cadru local
%   report.lastLocal  - ultimul cadru local

if nargin < 1 || isempty(localDir)
    localDir = fullfile(pwd, 'data');
end

if nargin < 2 || isempty(product)
    product = 'dBZ';
end

baseUrl = 'https://opendata.meteoromania.ro/radar/TIM/';

if ~isfolder(localDir)
    mkdir(localDir);
end

fprintf('[SYNC] Citire index %s ...\n', baseUrl);

% -------------------------------------------------------------------------
% Citire index MeteoRomania
% -------------------------------------------------------------------------

opts = weboptions( ...
    'Timeout', 60, ...
    'ContentType', 'text');

try
    indexHtml = webread(baseUrl, opts);
catch ME
    error('TIMRadar:IndexRead', ...
        'Nu pot citi indexul MeteoRomania: %s', ME.message);
end

% -------------------------------------------------------------------------
% Identificare fisiere
%
% Format real:
%
% TIM_2026082516000200dBZ.hdf
%     16 cifre
% -------------------------------------------------------------------------

productEscaped = regexptranslate('escape', product);

pattern = ['TIM_\d{16}' productEscaped '\.hdf'];

fileNames = regexp(indexHtml, pattern, 'match');

if isempty(fileNames)
    error('TIMRadar:NoProduct', ...
        'Niciun fisier %s in indexul MeteoRomania.', product);
end

fileNames = unique(fileNames);
fileNames = sort(fileNames);

nTotal = numel(fileNames);

fprintf('[SYNC] Server: %d cadre %s disponibile (%s -> %s)\n', ...
    nTotal, ...
    product, ...
    stampOf(fileNames{1}), ...
    stampOf(fileNames{end}));

% -------------------------------------------------------------------------
% Sincronizare
% -------------------------------------------------------------------------

nExist = 0;
nDown = 0;
failed = {};

for i = 1:nTotal

    fname = fileNames{i};
    fpath = fullfile(localDir, fname);

    % -------------------------------------------------------------
    % Fisier deja existent si valid
    % -------------------------------------------------------------

    d = dir(fpath);

    if ~isempty(d) && d.bytes > 0
        nExist = nExist + 1;
        continue;
    end

    % -------------------------------------------------------------
    % Download temporar
    % -------------------------------------------------------------

    tmpPath = [fpath '.part'];

    try

        websave(tmpPath, [baseUrl fname], opts);

        t = dir(tmpPath);

        if isempty(t) || t.bytes == 0
            error('TIMRadar:EmptyFile', ...
                'Fisier gol.');
        end

        movefile(tmpPath, fpath, 'f');

        nDown = nDown + 1;

        fprintf('   + %s (%d/%d)\n', ...
            fname, i, nTotal);

    catch ME

        if isfile(tmpPath)
            delete(tmpPath);
        end

        failed{end+1} = fname; %#ok<AGROW>

        fprintf(2, ...
            '   ! esuat %s : %s\n', ...
            fname, ME.message);
    end
end

% -------------------------------------------------------------------------
% Acoperirea reala a arhivei locale dupa sincronizare
% -------------------------------------------------------------------------

localList = dir(fullfile(localDir, ...
    sprintf('TIM_*%s.hdf', product)));

localNames = sort({localList.name});

report = struct( ...
    'existing',   nExist, ...
    'downloaded', nDown, ...
    'failed',     {failed}, ...
    'localTotal', numel(localNames), ...
    'firstLocal', '', ...
    'lastLocal',  '');

if ~isempty(localNames)

    report.firstLocal = stampOf(localNames{1});
    report.lastLocal  = stampOf(localNames{end});

end

% -------------------------------------------------------------------------
% Raport final
% -------------------------------------------------------------------------

fprintf('\n[SYNC] Existau deja: %d | Descarcate acum: %d | Esuate: %d\n', ...
    nExist, ...
    nDown, ...
    numel(failed));

fprintf('[SYNC] Arhiva locala: %d cadre, %s -> %s\n', ...
    report.localTotal, ...
    report.firstLocal, ...
    report.lastLocal);

if ~isempty(failed)
    fprintf('[SYNC] Reruleaza scriptul pentru a relua cadrele esuate.\n');
end

end


% =========================================================================
% STAMPOF
% =========================================================================

function s = stampOf(fname)

% Exemplu:
% TIM_2026082516000200dBZ.hdf
%
% timestamp = 2026082516000200
%
% Primele 14 cifre:
% yyyyMMddHHmmss

t = regexp(fname, ...
    'TIM_(\d{16})', ...
    'tokens', ...
    'once');

if isempty(t)

    s = '?';

else

    timestamp = t{1};

    try

        s = char(datetime( ...
            timestamp(1:14), ...
            'InputFormat', 'yyyyMMddHHmmss', ...
            'Format', 'yyyy-MM-dd HH:mm:ss'));

    catch

        s = timestamp;

    end
end

end
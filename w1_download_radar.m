function [data, timestamps, filePaths] = w1_download_radar(frameCount, varargin)
% W1_DOWNLOAD_RADAR Saptamana 1: Obtinerea cadrelor radar ODIM HDF5.
%
% Semnatura:
%   [matrix2D, timestamp, filePath]     = w1_download_radar()
%   [framesCell, timestamps, filePaths] = w1_download_radar(frameCount)
%   [...] = w1_download_radar(frameCount, 'LocalOnly', true)
%
% Optiuni:
%   'LocalOnly' true = nu se atinge reteaua, se folosesc cadrele din arhiva
%                      locala (implicit false)
%   'DataDir'   folderul arhivei (implicit <pwd>/data)
%
% Iesiri:
%   data       matrice dBZ (frameCount == 1) sau cell array de matrice
%   timestamps datetime UTC
%   filePaths  caile locale
%
% -------------------------------------------------------------------------
% Citirea HDF5/calibrarea este facuta centralizat prin radar_read_frame.
% -------------------------------------------------------------------------

if nargin < 1 || isempty(frameCount)
    frameCount = 1;
end

p = inputParser;

p.addParameter('LocalOnly', false, ...
    @(x) islogical(x) || isnumeric(x));

p.addParameter('DataDir', fullfile(pwd, 'data'), ...
    @(x) ischar(x) || isstring(x));

p.parse(varargin{:});

o = p.Results;

localDir = char(o.DataDir);

if ~isfolder(localDir)
    mkdir(localDir);
end

baseUrl = 'https://opendata.meteoromania.ro/radar/TIM/';

%% ------------------------------------------------------------------------
% Determinare fisiere
% -------------------------------------------------------------------------

if logical(o.LocalOnly)

    % ================================================================
    % MOD LOCAL
    % ================================================================

    d = dir(fullfile(localDir, 'TIM_*dBZ.hdf'));

    if isempty(d)

        error('TIMRadar:NoLocalFiles', ...
            ['Modul LocalOnly cere cadre in %s. ' ...
             'Ruleaza w1_sync_archive().'], ...
            localDir);

    end

    [~, ord] = sort({d.name});

    d = d(ord);

    % Cele mai recente primele
    d = flipud(d(:));

    n = min(frameCount, numel(d));

    chosen = fullfile(localDir, ...
        {d(1:n).name}');

else

    % ================================================================
    % MOD ONLINE
    % ================================================================

    opts = weboptions( ...
        'Timeout', 60, ...
        'ContentType', 'text');

    try

        indexHtml = webread(baseUrl, opts);

    catch ME

        error('TIMRadar:IndexRead', ...
            'Nu pot citi indexul MeteoRomania: %s', ...
            ME.message);

    end

    % ----------------------------------------------------------------
    % Format real:
    %
    % TIM_2026082513050200dBZ.hdf
    %
    % TIM_ + 16 cifre + dBZ + .hdf
    % ----------------------------------------------------------------

    pattern = 'TIM_\d{16}dBZ\.hdf';

    fileNames = regexp(indexHtml, pattern, 'match');

    if isempty(fileNames)

        % Fallback pentru cazul in care HTML-ul contine un format
        % diferit de href.
        fileNames = regexp( ...
            indexHtml, ...
            'href="([^"]*dBZ\.hdf)"', ...
            'tokens');

        if ~isempty(fileNames)

            fileNames = cellfun( ...
                @(x) x{1}, ...
                fileNames, ...
                'UniformOutput', false);

        end
    end

    if isempty(fileNames)

        error('TIMRadar:NoProduct', ...
            'Niciun fisier dBZ in indexul MeteoRomania.');

    end

    fileNames = unique(fileNames);

    fileNames = sort(fileNames);

    % Cele mai recente primele
    fileNames = flipud(fileNames(:));

    n = min(frameCount, numel(fileNames));

    chosen = cell(n, 1);

    % ----------------------------------------------------------------
    % Descarca numai cele mai recente frameCount cadre
    % ----------------------------------------------------------------

    for i = 1:n

        fpath = fullfile(localDir, fileNames{i});

        % ------------------------------------------------------------
        % Daca exista deja local si este nenul -> nu descarca
        % ------------------------------------------------------------

        d = dir(fpath);

        if isempty(d) || d.bytes == 0

            tmp = [fpath '.part'];

            try

                websave(tmp, ...
                    [baseUrl fileNames{i}], ...
                    opts);

                t = dir(tmp);

                if isempty(t) || t.bytes == 0

                    error('TIMRadar:EmptyFile', ...
                        'Fisier descarcat gol: %s', ...
                        fileNames{i});

                end

                movefile(tmp, fpath, 'f');

            catch ME

                if isfile(tmp)
                    delete(tmp);
                end

                rethrow(ME);

            end
        end

        chosen{i} = fpath;
    end
end

%% ------------------------------------------------------------------------
% Citire cadre prin radar_read_frame
% -------------------------------------------------------------------------

frames = cell(n, 1);

timestamps = NaT(n, 1);

filePaths = chosen;

for i = 1:n

    F = radar_read_frame(chosen{i});

    frames{i} = F.dbz;

    timestamps(i) = F.timestamp;

end

%% ------------------------------------------------------------------------
% Format iesire
% -------------------------------------------------------------------------

if frameCount == 1

    data = frames{1};

    filePaths = chosen{1};

else

    data = frames;

end

end
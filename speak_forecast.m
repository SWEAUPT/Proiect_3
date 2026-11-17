function [audioSignal, Fs, forecastInfo] = speak_forecast(variant, predictionValue, varargin)
% SPEAK_FORECAST Formuleaza si optional rosteste prognoza radar.
%
% SEMNATURA - NU SE SCHIMBA
% -------------------------------------------------------------------------
%   forecastInfo = speak_forecast(variant, predictionValue)
%   [audio, Fs, info] = speak_forecast(variant, predictionValue, Name, Value, ...)
%
% OPTIUNI
% -------------------------------------------------------------------------
%   'TaskInfo' structura returnata de w3_extract_features
%
%   'Client'
%       'piper'      - (implicit) Piper, voce ROMANEASCA offline (ro_RO-mihai),
%                      din tts_piper/; daca nu este instalat ramane doar textul
%       'TextOnly'   - doar afiseaza textul
%
%   'Play'
%       true/false - reda sau nu audio
%
%   'Blocking'
%       true/false - asteapta terminarea redarii sau nu
%
% IESIRI - NU SE SCHIMBA
% -------------------------------------------------------------------------
%   audioSignal
%       semnalul audio sintetizat
%
%   Fs
%       frecventa de esantionare
%
%   forecastInfo
%       structura cu informatii despre prognoza si TTS
%
% -------------------------------------------------------------------------
% COMPATIBILITATE
% -------------------------------------------------------------------------
% MATLAB R2026a, fara toolbox-uri suplimentare (audioread/audioplayer).
%
% Piper este singura voce: HiFi-GAN din Audio Toolbox si vocile Windows
% instalate sunt doar englezesti si citesc textul cu pronuntie engleza.
%   tts_piper/.venv cu piper-tts + tts_piper/voices/ro_RO-mihai-medium.onnx
%   instalare: tts_piper/setup_piper.ps1 (fara drepturi de administrator)
%
% -------------------------------------------------------------------------
% -------------------------------------------------------------------------

%% ========================================================================
% 1. INPUT
% ========================================================================

if nargin < 1 || isempty(variant)
    variant = 'B';
end

if nargin < 2 || isempty(predictionValue)
    predictionValue = 0;
end

variant = upper(char(variant));

if ~ismember(variant, {'A','B','C'})
    error('TIMRadar:BadVariant', ...
        'Varianta trebuie sa fie A, B sau C.');
end

persistent lastPlayer %#ok<PUSE> tine redarea non-blocking in viata (sectiunea 8)

p = inputParser;

p.addParameter('TaskInfo', struct(), @isstruct);

p.addParameter('Client', 'piper', ...
    @(x) (ischar(x) || isstring(x)) && ...
    any(strcmpi(strtrim(x), {'piper','TextOnly','none'})));

p.addParameter('Play', true, ...
    @(x) islogical(x) || isnumeric(x));

p.addParameter('Blocking', false, ...
    @(x) islogical(x) || isnumeric(x));

p.parse(varargin{:});

o = p.Results;

clientType = char(o.Client);

%% ========================================================================
% 2. INFORMATION FROM TASK
% ========================================================================

horizon = 30;

if isfield(o.TaskInfo, 'horizonMinutes') && ...
        ~isempty(o.TaskInfo.horizonMinutes)

    horizon = o.TaskInfo.horizonMinutes;
end

classNames = {};

if isfield(o.TaskInfo, 'classNames') && ...
        ~isempty(o.TaskInfo.classNames)

    classNames = o.TaskInfo.classNames;
end

%% ========================================================================
% 3. BUILD FORECAST MESSAGE
% ========================================================================

switch variant

    % ---------------------------------------------------------------------
    % VARIANTA A - CLASSIFICATION
    % ---------------------------------------------------------------------

    case 'A'

        k = round(predictionValue);

        k = max(1, min(4, k));

        if numel(classNames) >= k

            desc = strip_parens(classNames{k});

        else

            fallback = { ...
                'fara precipitatii semnificative', ...
                'precipitatii izolate', ...
                'precipitatii extinse', ...
                'precipitatii generalizate'};

            desc = fallback{k};

        end

        spokenMessage = sprintf( ...
            'Prognoza radar Timisoara pentru urmatoarele %s: %s.', ...
            minute_text(horizon), desc);

        alertType = sprintf('clasa_%d', k);


    % ---------------------------------------------------------------------
    % VARIANTA B - REGRESSION
    % ---------------------------------------------------------------------

    case 'B'

        v = double(predictionValue);

        if ~isfinite(v)
            v = 0;
        end

        v = max(0, v);

        if v < 0.02

            desc = 'fara precipitatii semnificative';
            alertType = 'senin';

        elseif v < 0.05

            desc = 'ploaie slaba, izolata';
            alertType = 'ploaie_slaba';

        elseif v < 0.12

            desc = 'ploaie moderata';
            alertType = 'ploaie_moderata';

        else

            desc = 'ploaie intensa, extinsa pe suprafata mare';
            alertType = 'ploaie_intensa';

        end

        spokenMessage = sprintf( ...
            ['Prognoza radar Timisoara pentru urmatoarele %s: ' ...
             'intensitate medie estimata la %s milimetri pe ora ' ...
             'pe suprafata acoperita, %s.'], ...
            minute_text(horizon), decimal_ro(v, 3), desc);


    % ---------------------------------------------------------------------
    % VARIANTA C - PROBABILITY OF PRECIPITATION
    % ---------------------------------------------------------------------

    case 'C'

        pct = double(predictionValue);

        if ~isfinite(pct)
            pct = 0;
        end

        % SCARA VINE DIN taskInfo, NU SE GHICESTE DIN VALOARE.
        %
        % main.m trimite deja procente (100 * scoreRF), deci o sansa reala de
        % 0.8% intra ca 0.8. Dedusa din marime ("<= 1 inseamna fractie"),
        % scara ar rosti-o "80 la suta" - exact pe vremea linistita, cazul cel
        % mai frecvent. Unitatea se afla de la apelant.

        if isfield(o.TaskInfo, 'unit') && strcmp(o.TaskInfo.unit, '%')
            % Apelantul lucreaza deja in procente (0...100).
            isPercent = true;
        else
            % Fara taskInfo presupunem probabilitate bruta (0...1).
            isPercent = false;
        end

        if ~isPercent
            % Fara TaskInfo scara nu se poate DEDUCE, deci nu se ghiceste:
            % speak_forecast('C', 62) ar deveni 6200, plafonat la "100 la suta".
            % O valoare > 1 primeste o eroare explicita, nu una plauzibila.
            if pct > 1
                error('TIMRadar:AmbiguousScale', ...
                    ['Fara ''TaskInfo'', varianta C asteapta o probabilitate in ' ...
                     '0..1, dar a primit %g. Transmite ''TaskInfo'' de la ' ...
                     'w3_extract_features (unit = ''%%'') sau imparte valoarea la 100.'], pct);
            end
            pct = pct * 100;
        end

        pct = max(0, min(100, pct));

        if pct < 25

            desc = 'sanse mici';
            alertType = 'senin';

        elseif pct < 60

            desc = 'sanse moderate';
            alertType = 'ploaie_moderata';

        else

            desc = 'sanse ridicate';
            alertType = 'ploaie_extinsa';

        end

        spokenMessage = sprintf( ...
            ['Prognoza radar Timisoara: %s de precipitatii extinse ' ...
             'in urmatoarele %s, estimate la %.0f la suta.'], ...
            desc, minute_text(horizon), pct);

end

%% ========================================================================
% 4. DISPLAY FORECAST
% ========================================================================

fprintf('\n');
fprintf('=======================================================\n');
fprintf('   PROGNOZA RADAR TIMISOARA\n');
fprintf('=======================================================\n');
fprintf('   Varianta       : %s\n', variant);
fprintf('   Orizont        : %g minute\n', horizon);
fprintf('   Client TTS     : %s\n', clientType);
fprintf('-------------------------------------------------------\n');
fprintf('   "%s"\n', spokenMessage);
fprintf('=======================================================\n');

%% ========================================================================
% 5. DEFAULT OUTPUTS
% ========================================================================

audioSignal = [];
Fs = 24000;

synthesized = false;

actualClient = 'none';

%% ========================================================================
% 6. TTS DISABLED
% ========================================================================

if ~logical(o.Play)

    statusMsg = 'redarea audio este dezactivata';

elseif any(strcmpi(clientType, {'TextOnly','none'}))

    statusMsg = 'mod TextOnly';

else

    %% ====================================================================
    % 7. PIPER - LOCAL, VOCE ROMANEASCA
    % ====================================================================

    try

        fprintf('   [TTS] Sintetizare Piper (ro_RO-mihai)...\n');

        [audioSignal, Fs] = synth_piper(ro_diacritics(spokenMessage));

        synthesized = true;

        actualClient = 'piper';

        statusMsg = 'Piper local, voce romaneasca ro_RO-mihai';

    catch ME

        synthesized = false;

        statusMsg = sprintf('Piper indisponibil: %s', ...
            cleanErrorMessage(ME.message));

        fprintf(2, '   [TTS] %s\n', statusMsg);

    end

    %% ====================================================================
    % 8. PLAY AUDIO
    % ====================================================================

    if synthesized && ~isempty(audioSignal)

        try

            player = audioplayer(audioSignal, Fs);

            if logical(o.Blocking)

                fprintf('   [TTS] Redare audio - blocking...\n');

                playblocking(player);

            else

                fprintf('   [TTS] Redare audio - non-blocking...\n');

                play(player);

                % audioplayer se opreste cand obiectul este distrus, adica la
                % iesirea din functie. Variabila persistenta il tine in viata
                % pana la urmatorul anunt (care il inlocuieste).
                lastPlayer = player;

            end

        catch ME

            statusMsg = sprintf( ...
                '%s | redarea audio a esuat: %s', ...
                statusMsg, ...
                cleanErrorMessage(ME.message));

            fprintf(2, ...
                '   [TTS] %s\n', statusMsg);

        end

    end

end

%% ========================================================================
% 9. TEXT-ONLY FALLBACK
% ========================================================================

if ~synthesized

    fprintf('\n');
    fprintf('   [TTS] ------------------------------------------------\n');
    fprintf('   [TTS] %s\n', statusMsg);
    fprintf('   [TTS] Mesajul ramane disponibil ca text.\n');
    fprintf('   [TTS] ------------------------------------------------\n');

end

%% ========================================================================
% 10. FORECAST INFORMATION STRUCT
% ========================================================================

durationSec = 0;

if ~isempty(audioSignal) && Fs > 0

    durationSec = size(audioSignal, 1) / Fs;

end

forecastInfo = struct( ...
    'text',            spokenMessage, ...
    'client',          clientType, ...
    'actualClient',    actualClient, ...
    'alertType',       alertType, ...
    'variant',         variant, ...
    'horizonMinutes',  horizon, ...
    'predictionValue', predictionValue, ...
    'synthesized',     synthesized, ...
    'status',          statusMsg, ...
    'durationSec',     durationSec);

%% ========================================================================
% 11. SINGLE OUTPUT COMPATIBILITY
% ========================================================================

if nargout == 1

    audioSignal = forecastInfo;

end

end


% =========================================================================
% LOCAL FUNCTION
% =========================================================================

function s = minute_text(h)
% MINUTE_TEXT Acordul numeralului in limba romana: peste 19 se intercaleaza "de".
%   15 -> "15 minute"    30 -> "30 de minute"    60 -> "60 de minute"
r = mod(abs(h), 100);
if r == 0 || r >= 20
    s = sprintf('%g de minute', h);
else
    s = sprintf('%g minute', h);
end
end


% =========================================================================
% LOCAL FUNCTION
% =========================================================================

function s = decimal_ro(v, nDec)
% DECIMAL_RO Zecimala cu VIRGULA, nu cu punct.
% Un motor TTS romanesc citeste "0.082" altfel decat "0,082", iar in textul
% afisat punctul zecimal este oricum ortografie gresita in romana.
s = strrep(sprintf('%.*f', nDec, v), '.', ',');
end


% =========================================================================
% LOCAL FUNCTION
% =========================================================================

function s = strip_parens(s)
% STRIP_PARENS Elimina explicatia dintre paranteze.

s = regexprep( ...
    char(s), ...
    '\s*\(.*\)\s*$', ...
    '');

s = lower(strtrim(s));

end


% =========================================================================
% LOCAL FUNCTIONS - PIPER
% =========================================================================

function [py, model, script] = piper_paths()
% Instalarea locala din tts_piper/ (vezi tts_piper/setup_piper.ps1).
root   = fullfile(fileparts(mfilename('fullpath')), 'tts_piper');
py     = fullfile(root, '.venv', 'Scripts', 'python.exe');
model  = fullfile(root, 'voices', 'ro_RO-mihai-medium.onnx');
script = fullfile(root, 'piper_say.py');
end


function ok = piper_available()
[py, model, script] = piper_paths();
ok = isfile(py) && isfile(model) && isfile([model '.json']) && isfile(script);
end


function [audio, Fs] = synth_piper(text)
% Textul trece printr-un fisier UTF-8: pe linia de comanda Windows
% diacriticele s-ar pierde, iar fara ele vocea pronunta gresit.
[py, model, script] = piper_paths();
if ~piper_available()
    error('TIMRadar:NoPiper', ...
        'Piper nu este instalat. Ruleaza tts_piper/setup_piper.ps1.');
end
txt = [tempname '.txt'];
wav = [tempname '.wav'];
cleanup = onCleanup(@() delete_quiet({txt, wav}));
fid = fopen(txt, 'w');
if fid < 0
    error('TIMRadar:PiperIO', 'Nu se poate scrie fisierul temporar %s.', txt);
end
fwrite(fid, unicode2native(text, 'UTF-8'), 'uint8');
fclose(fid);
cmd = sprintf('"%s" "%s" "%s" "%s" "%s"', py, script, model, txt, wav);
[status, out] = system(cmd);
if status ~= 0 || ~isfile(wav)
    error('TIMRadar:PiperFailed', 'Piper a esuat (%d): %s', status, strtrim(out));
end
[audio, Fs] = audioread(wav);
audio = double(audio);
if size(audio, 2) > 1
    audio = mean(audio, 2);
end
if isempty(audio)
    error('TIMRadar:EmptyTTS', 'Piper a returnat un semnal audio gol.');
end
end


function delete_quiet(files)
for k = 1:numel(files)
    if isfile(files{k}), delete(files{k}); end
end
end


function s = ro_diacritics(s)
% RO_DIACRITICS Diacriticele pentru vocabularul FIX al mesajelor de mai sus.
% Textul afisat si cel din forecastInfo raman fara diacritice, ca restul
% proiectului; doar vocea primeste forma corecta. Fara ele "precipitatii"
% se rosteste cu t simplu, iar "fara" cu a in loc de ă. Inlocuirea se face
% pe CUVINTE intregi, deci "in" nu atinge "intensitate" sau "izolate".
map = { ...
    'Timisoara',    'Timișoara'; ...
    'urmatoarele',  'următoarele'; ...
    'fara',         'fără'; ...
    'precipitatii', 'precipitații'; ...
    'slaba',        'slabă'; ...
    'izolata',      'izolată'; ...
    'moderata',     'moderată'; ...
    'intensa',      'intensă'; ...
    'extinsa',      'extinsă'; ...
    'suprafata',    'suprafață'; ...
    'estimata',     'estimată'; ...
    'ora',          'oră'; ...
    'acoperita',    'acoperită'; ...
    'sanse',        'șanse'; ...
    'in',           'în'; ...
    'suta',         'sută'};
for k = 1:size(map, 1)
    s = regexprep(s, ['(?<![a-zA-Z])' map{k, 1} '(?![a-zA-Z])'], map{k, 2});
end
end


% =========================================================================
% LOCAL FUNCTION
% =========================================================================

function s = cleanErrorMessage(msg)
% CLEANERRORMESSAGE Face mesajul MATLAB mai usor de citit in consola.

s = char(msg);

% Elimina newline-uri multiple.
s = regexprep(s, '[\r\n]+', ' ');

% Reduce spatiile consecutive.
s = regexprep(s, '\s+', ' ');

% Limiteaza lungimea pentru consola.
maxLength = 500;

if numel(s) > maxLength

    s = [s(1:maxLength) ' ...'];

end

end
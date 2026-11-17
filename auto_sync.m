function auto_sync(dataDir)
% AUTO_SYNC Sincronizare neasistata a arhivei radar, pentru rulare programata.
%
% Gandita pentru Task Scheduler / cron: nu pune intrebari, nu deschide figuri,
% nu arunca niciodata o exceptie in afara, si adauga o singura linie de jurnal
% per rulare in `sync_log.txt`, pe care o poti citi dintr-o privire.
%
% Utilizare:
%   auto_sync                 % foloseste <radacina proiectului>/data
%   auto_sync('D:\alta\data')
%
% DE CE EXISTA ACEST FISIER
% ---------------------------------------------------------------------
% Serverul ANM pastreaza o fereastra rulanta de ~3.5 zile. O sincronizare
% ratata mai mult de atat pierde definitiv cadrele (arhiva are deja goluri de
% 62.9 h si 132.1 h din aceasta cauza). Singura protectie este ca
% sincronizarea sa nu depinda de memoria cuiva.
%
% DE CE SCRIE JURNALUL SINGUR, NU PRIN REDIRECTARE DIN .cmd
% ---------------------------------------------------------------------
% Pe Windows, `matlab.exe` este o aplicatie din subsistemul GUI: pornita dintr-un
% .cmd se DETASEAZA imediat, iar `>> sync_log.txt` nu capteaza nimic (sarcina
% programata raporteaza "Last Result: 0" inainte ca MATLAB sa porneasca).
% Scrierea directa din MATLAB elimina dependenta de conducta de stdout.

if nargin < 1 || isempty(dataDir)
    dataDir = fullfile(fileparts(mfilename('fullpath')), 'data');
end
logFile = fullfile(fileparts(mfilename('fullpath')), 'sync_log.txt');

stamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));

try
    r = w1_sync_archive(dataDir);

    % Cel mai important semnal de alarma: daca nu exista NICIO suprapunere
    % intre server si arhiva locala, inseamna ca s-a pierdut definitiv o
    % bucata de serie. Merita marcat distinct in jurnal, nu ascuns in numere.
    if r.downloaded > 0 && r.existing == 0
        verdict = 'ATENTIE-GOL-PERMANENT';
    elseif ~isempty(r.failed)
        verdict = 'PARTIAL';
    else
        verdict = 'OK';
    end

    line = sprintf('%s  %-22s descarcate=%-5d existau=%-5d esuate=%-3d total=%-6d ultimul=%s', ...
        stamp, verdict, r.downloaded, r.existing, numel(r.failed), ...
        r.localTotal, r.lastLocal);

catch ME
    % Un esec de retea nu trebuie sa opreasca sarcina programata: se
    % logheaza si se reia la urmatoarea rulare.
    line = sprintf('%s  %-22s %s', stamp, 'ESUAT', ...
        regexprep(ME.message, '[\r\n]+', ' '));
end

% Consola (rulare interactiva) SI fisier (rulare programata).
fprintf('%s\n', line);
fid = fopen(logFile, 'a');
if fid > 0
    fprintf(fid, '%s\n', line);
    fclose(fid);
else
    warning('TIMRadar:LogWrite', 'Nu am putut scrie in %s', logFile);
end
end

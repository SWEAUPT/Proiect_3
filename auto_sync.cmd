@echo off
REM Sincronizare automata a arhivei radar TIM (vezi auto_sync.m).
REM
REM Inregistrare ca sarcina programata, la fiecare 12 ore:
REM   schtasks /create /tn "TIM Radar Sync" /tr "\"C:\UPT\SWEA\Project 3 Redesign\auto_sync.cmd\"" /sc hourly /mo 12 /f
REM
REM -wait este OBLIGATORIU: pe Windows matlab.exe apartine subsistemului GUI si
REM se detaseaza imediat, deci fara el sarcina raporteaza succes instantaneu, in
REM timp ce MATLAB abia porneste. Jurnalul este scris de auto_sync.m direct in
REM sync_log.txt, nu prin redirectare, tocmai pentru ca stdout-ul unui matlab.exe
REM detasat nu ajunge nicaieri.
REM
REM Calea catre MATLAB NU mai este fixata pe o versiune. Pana pe 2026-10-04 era
REM "R2026a\bin\matlab.exe"; dupa dezinstalarea R2026a fisierul a disparut, cmd
REM intorcea 9009 ("command not found"), iar sync_log.txt nu a mai primit nicio
REM linie - fiindca jurnalul il scrie MATLAB, care nu mai pornea deloc. Acum se
REM alege cea mai noua versiune instalata, iar lipsa ei se scrie in jurnal.
cd /d "%~dp0"
set "MATLAB_EXE="
for /f "delims=" %%D in ('dir /b /ad /o:n "C:\Program Files\MATLAB\R20*" 2^>nul') do (
    if exist "C:\Program Files\MATLAB\%%D\bin\matlab.exe" set "MATLAB_EXE=C:\Program Files\MATLAB\%%D\bin\matlab.exe"
)
if not defined MATLAB_EXE (
    echo %DATE% %TIME%  ESUAT                  matlab.exe negasit in C:\Program Files\MATLAB>> "%~dp0sync_log.txt"
    exit /b 9009
)
"%MATLAB_EXE%" -wait -batch "auto_sync"
exit /b %ERRORLEVEL%

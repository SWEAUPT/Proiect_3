function fig = w7_main_dashboard(frameOrMatrix, stats, varargin)
% W7_MAIN_DASHBOARD Saptamana 7: Dashboard vizual cu 4 panouri.
%
% Semnatura:
%   fig = w7_main_dashboard(frame, stats, Name, Value, ...)
%   fig = w7_main_dashboard(cleanMatrix, stats)          % mod compatibil
%
% Optiuni:
%   'Prediction' valoarea prezisa (mm/h pentru B, clasa pentru A, % pentru C)
%   'TaskInfo'   structura de la w3_extract_features (determina afisajul)
%   'Visible'    'on' | 'off'   (implicit 'on')
%
% ---------------------------------------------------------------------
% CE AVETI DE FACUT (Saptamana 7) - cautati apelurile todo(...)
% ---------------------------------------------------------------------
%   7.1  histograma dBZ PONDERATA CU ARIA (panoul 3)
%   7.2  conversia polar -> cartezian in kilometri (panourile 1 si 2)
% Verificare: run_all_tests('Week', 7), apoi main
%
% Fisierele PVOL contin date POLARE [920 raze x 360 azimuturi]. Un imagesc()
% direct pe matrice ar desena distanta-fata-de-azimut ca si cum ar fi o harta.
% Varianta (A/B/C) vine explicit din taskInfo, nu se ghiceste din valoare.

p = inputParser;
p.addParameter('Prediction', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
p.addParameter('TaskInfo', struct(), @isstruct);
p.addParameter('Visible', 'on', @(x) ischar(x) || isstring(x));
p.parse(varargin{:});
o = p.Results;

% ---------------------------------------------------------------------
% Normalizarea intrarii: struct de cadru sau matrice simpla
% ---------------------------------------------------------------------
if isstruct(frameOrMatrix)
    F = frameOrMatrix;
    dbz = F.dbz;
    validMask = F.validMask;
    rainRate = F.rainRate;
    geom = F.geometry;
else
    dbz = frameOrMatrix;
    validMask = isfinite(dbz);
    rainRate = zeros(size(dbz));
    m = validMask & dbz > -10;
    rainRate(m) = (10 .^ (min(dbz(m), 53) / 10) / 200) .^ (1 / 1.6);
    geom = struct('type', 'grid');
end
if nargin < 2 || isempty(stats)
    [~, stats] = w2_clean_and_stats(dbz);
end

fig = figure('Name', 'TIM Radar - Dashboard Precipitatii & AI', ...
             'Color', 'w', 'Position', [100 100 1180 780], 'Visible', char(o.Visible));

% ---------------------------------------------------------------------
% 1. Harta de reflectivitate, in coordonate reale
% ---------------------------------------------------------------------
ax1 = subplot(2, 2, 1);
plot_field(ax1, dbz, validMask, geom, turbo(256), [-32 60]);
title(ax1, '1. Reflectivitate radar (dBZ)', 'FontSize', 11, 'FontWeight', 'bold');
cb1 = colorbar(ax1); ylabel(cb1, 'dBZ');

% ---------------------------------------------------------------------
% 2. Harta de intensitate a ploii (Z-R aplicat pe pixel, cu plafon de grindina)
% ---------------------------------------------------------------------
ax2 = subplot(2, 2, 2);
rr = rainRate;
hi = max(1, prctile(rr(validMask & rr > 0), 99));
plot_field(ax2, rr, validMask, geom, parula(256), [0 hi]);
title(ax2, '2. Intensitate ploaie (mm/h, Z-R pe pixel)', 'FontSize', 11, 'FontWeight', 'bold');
cb2 = colorbar(ax2); ylabel(cb2, 'mm/h');

% ---------------------------------------------------------------------
% 3. Distributia semnalului, doar pe ecou
% ---------------------------------------------------------------------
ax3 = subplot(2, 2, 3);
noEcho = -32;
if isstruct(frameOrMatrix) && isfield(frameOrMatrix, 'noEchoDbz')
    noEcho = frameOrMatrix.noEchoDbz;
end
% HISTOGRAMA SE PONDEREAZA CU ARIA, ca statisticile suprapuse peste ea.
%
% Intr-o grila polara pixelii de langa radar sunt masiv supra-reprezentati la
% numarare, deci o histograma pe PIXELI nu s-ar potrivi cu stats.mean si
% stats.p95 (ponderate cu aria, vezi w2_clean_and_stats): liniile "Medie" si
% "P95" ar cadea in afara masei histogramei.
echoSel = validMask & dbz > noEcho + 1e-9;
if ~any(echoSel(:)), echoSel = validMask; end
echoVals = dbz(echoSel);

wts = [];
if isstruct(frameOrMatrix) && isfield(frameOrMatrix, 'areaWeight')
    wts = frameOrMatrix.areaWeight(echoSel);
end

lo = min(echoVals); hi2 = max(echoVals);
if ~(hi2 > lo), hi2 = lo + 1; end          % cadru cu o singura valoare
edges = linspace(lo, hi2, 41);

if isempty(wts) || sum(wts) <= 0
    % Matrice bruta: ponderile sunt uniforme, deci numararea ESTE ponderarea.
    histogram(ax3, echoVals, edges, 'FaceColor', [0.2 0.5 0.8], ...
        'EdgeColor', 'none', 'Normalization', 'probability');
    yLab = 'Pondere (pixeli)';
else
    % TODO 7.1: counts [numel(edges)-1 x 1] = SUMA ponderilor de arie (wts) a
    %   pixelilor din fiecare interval de dBZ, normalizata sa insumeze 1.
    %   Indiciu: discretize(echoVals, edges) da intervalul fiecarui pixel, iar
    %   accumarray poate aduna ponderile pe intervale. Fara ponderare, pixelii
    %   mici de langa radar domina histograma si liniile Medie/P95 (ponderate,
    %   din w2) cad in afara ei.
    todo('7.1', 'counts (histograma ponderata cu aria)');
    histogram(ax3, 'BinEdges', edges, 'BinCounts', counts, ...
        'FaceColor', [0.2 0.5 0.8], 'EdgeColor', 'none');
    yLab = 'Pondere de arie';
end

hold(ax3, 'on');
xline(ax3, stats.mean, 'r--', sprintf('Medie %.1f', stats.mean), 'LineWidth', 1.5);
xline(ax3, stats.p95, 'm-', sprintf('P95 %.1f', stats.p95), 'LineWidth', 1.5);
title(ax3, '3. Distributia dBZ pe pixelii cu ecou', 'FontSize', 11, 'FontWeight', 'bold');
xlabel(ax3, 'Reflectivitate (dBZ)'); ylabel(ax3, yLab);
grid(ax3, 'on');

% ---------------------------------------------------------------------
% 4. Cardul de prognoza, condus EXPLICIT de varianta
% ---------------------------------------------------------------------
ax4 = subplot(2, 2, 4);
axis(ax4, 'off');
[headline, detailText, footer, col] = forecast_card(o.Prediction, o.TaskInfo, stats);

rectangle(ax4, 'Position', [0.03 0.05 0.94 0.90], 'Curvature', 0.08, ...
          'FaceColor', [0.96 0.97 0.99], 'EdgeColor', col, 'LineWidth', 3);
text(ax4, 0.5, 0.86, '4. PREVIZIUNE', 'HorizontalAlignment', 'center', ...
     'FontSize', 13, 'FontWeight', 'bold', 'Color', [0.1 0.1 0.2]);
text(ax4, 0.5, 0.68, headline, 'HorizontalAlignment', 'center', ...
     'FontSize', 12, 'FontWeight', 'bold', 'Color', col);
text(ax4, 0.5, 0.52, detailText, 'HorizontalAlignment', 'center', 'FontSize', 12);
text(ax4, 0.5, 0.34, sprintf('Ecou pe %.1f%% din suprafata  |  P95 %.1f dBZ  |  %.3f mm/h acum', ...
     100 * stats.echoFraction, stats.p95, stats.arealRainRate), ...
     'HorizontalAlignment', 'center', 'FontSize', 9, 'Color', [0.3 0.3 0.3]);
text(ax4, 0.5, 0.18, footer, 'HorizontalAlignment', 'center', 'FontSize', 9, ...
     'FontAngle', 'italic', 'Color', [0.4 0.4 0.4]);
xlim(ax4, [0 1]); ylim(ax4, [0 1]);

drawnow;
end

% =====================================================================
function plot_field(ax, C, validMask, geom, cmap, clim_)
% Deseneaza campul in coordonate fizice, cu pixelii din afara acoperirii
% transparenti.
if isfield(geom, 'type') && strcmp(geom.type, 'polar')
    % Coordonate carteziene din geometria polara reala
    [nb, nr] = size(C);
    step = max(1, round(nb / 460));                 % subesantionare pentru viteza
    rIdx = 1:step:nb;
    % TODO 7.2: coordonatele in km ale centrelor de celula.
    %   r  - distanta de la radar a razei rIdx, in KM: geom.rstart si
    %        geom.rscale sunt in metri; centrul celulei k este la
    %        rstart + (k - 0.5) * rscale
    %   az - azimutul celor nr coloane, in radiani, de la NORD, in sens ORAR
    %   [AZ, R] = meshgrid(az, r);  apoi Xk (km spre est) si Yk (km spre nord).
    %   Atentie: azimutul meteorologic se masoara de la nord, nu de la axa x.
    todo('7.2', 'r, az, Xk, Yk (polar -> cartezian)');

    Cs = C(rIdx, :);
    Ms = validMask(rIdx, :);
    Cs(~Ms) = NaN;

    % Inchiderea cercului, ca sa nu ramana o felie goala la 0/360 grade
    Xk = [Xk, Xk(:, 1)];
    Yk = [Yk, Yk(:, 1)];
    Cs = [Cs, Cs(:, 1)];

    surf(ax, Xk, Yk, zeros(size(Cs)), Cs, 'EdgeColor', 'none');
    view(ax, 2);
    axis(ax, 'equal');
    xlabel(ax, 'km E fata de radar'); ylabel(ax, 'km N fata de radar');
    hold(ax, 'on');
    draw_range_rings(ax, geom);
    hold(ax, 'off');
    maxR = geom.maxRangeKm;
    xlim(ax, [-maxR maxR]); ylim(ax, [-maxR maxR]);
else
    % Grila carteziana (PCAPPI) sau matrice simpla
    if isfield(geom, 'xscale')
        halfX = geom.xscale * size(C, 2) / 2000;
        halfY = geom.yscale * size(C, 1) / 2000;
        % Y de la +halfY la -halfY, NU invers.
        %
        % Intr-o imagine cartografica ODIM primul rand este cel mai de NORD
        % (colturile din /where sunt date UL -> LL). Cu [-halfY halfY] si
        % 'YDir','normal', randul 1 ar ajunge in partea de JOS a axei, iar
        % harta PCAPPI ar fi oglindita nord-sud fata de PVOL.
        imagesc(ax, [-halfX halfX], [halfY -halfY], C, 'AlphaData', validMask);
        xlabel(ax, 'km E fata de radar'); ylabel(ax, 'km N fata de radar');
        axis(ax, 'image');
    else
        imagesc(ax, C, 'AlphaData', validMask);
        xlabel(ax, 'coloana'); ylabel(ax, 'linie');
        axis(ax, 'image');
    end
    set(ax, 'YDir', 'normal');
end
colormap(ax, cmap);
if ~isempty(clim_) && clim_(2) > clim_(1)
    clim(ax, clim_);       % clim() inlocuieste caxis(), depreciat
end
set(ax, 'Color', [0.94 0.94 0.94]);
end

% =====================================================================
function draw_range_rings(ax, geom)
maxR = geom.maxRangeKm;
rings = 50:50:floor(maxR / 50) * 50;
th = linspace(0, 2 * pi, 181);
for rr = rings
    plot3(ax, rr * cos(th), rr * sin(th), ones(size(th)), ...
        'Color', [1 1 1 0.35], 'LineWidth', 0.5);
    text(ax, 0, rr, 1, sprintf('%d km', rr), 'Color', [1 1 1 0.7], ...
        'FontSize', 7, 'HorizontalAlignment', 'center');
end
end

% =====================================================================
function [headline, detailText, footer, col] = forecast_card(pred, taskInfo, stats) %#ok<INUSD>
green = [0.1 0.7 0.2]; blue = [0.2 0.6 0.9]; orange = [0.9 0.5 0.1]; red = [0.8 0.1 0.1];
grey = [0.4 0.4 0.4];

if isempty(pred) || ~isfield(taskInfo, 'variant')
    headline = 'Model neantrenat';
    detailText = 'Ruleaza main.m pentru o prognoza';
    footer = 'Marshall-Palmer: Z = 200 R^{1.6}, plafon 53 dBZ';
    col = grey;
    return;
end

horizon = 30;
if isfield(taskInfo, 'horizonMinutes'), horizon = taskInfo.horizonMinutes; end

switch taskInfo.variant
    case 'B'
        v = max(0, pred);
        detailText = sprintf('%.3f mm/h medie pe suprafata, peste %g min', v, horizon);
        footer = 'Marshall-Palmer pe pixel, mediat cu ponderi de arie';
        if v < 0.02
            headline = 'FARA PRECIPITATII SEMNIFICATIVE'; col = green;
        elseif v < 0.05
            headline = 'PLOAIE SLABA / IZOLATA'; col = blue;
        elseif v < 0.12
            headline = 'PLOAIE MODERATA'; col = orange;
        else
            headline = 'PLOAIE INTENSA / EXTINSA'; col = red;
        end
    case 'A'
        k = max(1, min(4, round(pred)));
        % taskInfo poate veni fara classNames sau cu classNames gol (apel manual,
        % model incarcat dintr-un .mat vechi). Fara aceasta verificare, accesul
        % arunca o eroare in mijlocul desenarii figurii.
        if isfield(taskInfo, 'classNames'), names = taskInfo.classNames; else, names = {}; end
        if numel(names) >= k
            % Fara paranteza explicativa: numele complet are pana la 47 de
            % caractere ('FARA PRECIPITATII SEMNIFICATIVE (<5% DIN DOMENIU)') si
            % la FontSize 12 bold, centrat intr-un sfert de figura, iesea in
            % afara cardului. speak_forecast face deja acelasi lucru cu
            % strip_parens; explicatia completa ramane in detailText.
            headline = upper(regexprep(names{k}, '\s*\(.*\)\s*$', ''));
            detailText = sprintf('%s, peste %g min', names{k}, horizon);
        else
            headline = sprintf('CLASA %d DIN 4', k);
            detailText = sprintf('Clasa %d din 4, peste %g min', k, horizon);
        end
        footer = 'Clasificare dupa fractiunea din domeniu cu ploaie masurabila';
        cols = {green, blue, orange, red};
        col = cols{k};
    case 'C'
        pct = max(0, min(100, pred));
        headline = sprintf('%.0f%% SANSE DE PLOAIE EXTINSA', pct);
        detailText = sprintf('In urmatoarele %g minute', horizon);
        popThr = 0.10;      % implicit, daca taskInfo nu il poarta
        if isfield(taskInfo, 'popThresholdC') && ~isempty(taskInfo.popThresholdC)
            popThr = taskInfo.popThresholdC;
        end
        footer = sprintf('P(ploaie pe >= %.0f%% din domeniu), evaluat cu scor Brier', ...
            100 * popThr);
        if pct < 25
            col = green;
        elseif pct < 60
            col = blue;
        else
            col = red;
        end
    otherwise
        headline = 'Varianta necunoscuta';
        detailText = '';
        footer = '';
        col = grey;
end
end

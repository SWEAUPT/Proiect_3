function [Xo, yo, info] = opera_training_rows(variant, featureNames, taskInfo, varargin)
% OPERA_TRAINING_ROWS Esantioane suplimentare de ANTRENAMENT din compozitul OPERA.
%
% Semnatura:
%   [Xo, yo, info] = opera_training_rows(variant, featureNames, taskInfo, Name, Value, ...)
%
%   variant, featureNames, taskInfo - exact cum le-a intors w3_extract_features
%                                     pentru radarul TIM.
% Optiuni:
%   'Use'     'auto' | true | false (implicit 'auto' = doar variantele A si C)
%   'Verbose' (implicit true)
%
% Iesire: Xo [n x numel(featureNames)], coloanele in ordinea lui featureNames,
% si yo [n x 1]. Se adauga DOAR la segmentul de train al lui TIM:
%   Xtr = [X(tr,:); Xo];  ytr = [y(tr); yo];
% Validarea si testul raman exclusiv TIM - asa se masoara castigul pe radarul
% pentru care se face prognoza.
%
% DE CE DOAR A SI C
% ---------------------------------------------------------------------
% Experiment pe 2026-10-20 (Random Forest, 3 seminte, scor pe val/test TIM):
%   A  macro-F1     val 0.896 -> 0.930 (3/3 seminte), test 0.923 -> 0.927
%   C  Brier        val 0.0181 -> 0.0176 (3/3),       test 0.0565 -> 0.0474
%   B  abilitate    val 0.589 -> 0.510  (mai slab)
% OPERA aduce ~10 luni de vreme fata de ~2 luni TIM, deci mai multe episoade de
% extindere/retragere a ploii. Dar intensitatea lui este sistematic mai mare
% (~1.6x ploaia medie TIM pe aceleasi cadre), iar B prezice exact mm/h - de
% aceea la B strica. OPERA singur este mai slab la toate trei.
%
% FARA SCURGERE
% ---------------------------------------------------------------------
% Se folosesc numai esantioane OPERA a caror TINTA este anterioara inceputului
% segmentului de validare TIM, minus o fereastra de intrare + orizont + 60 min.
% Altfel aceeasi ploaie, vazuta de celalalt radar, ar intra in antrenament si
% ar reaparea la evaluare.
%
% Este alt produs decat TIM: cadrele nu se amesteca niciodata, doar
% esantioanele de antrenament (trasaturi agregate pe domeniu) se concateneaza.
% LSTM-ul ramane antrenat doar pe TIM: experimentul a fost facut pe RF.

p = inputParser;
p.addParameter('Use', 'auto', @(x) islogical(x) || isnumeric(x) || ...
    (ischar(x) || isstring(x)) && strcmpi(x, 'auto'));
p.addParameter('Verbose', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
o = p.Results;

variant = upper(char(variant));
if ischar(o.Use) || isstring(o.Use)
    use = any(strcmp(variant, {'A', 'C'}));
else
    use = logical(o.Use);
end

Xo = zeros(0, numel(featureNames));
yo = zeros(0, 1);
info = struct('used', false, 'nRows', 0, 'cutoff', NaT, 'reason', '');

if ~use
    info.reason = sprintf('varianta %s: OPERA dezactivat', variant);
    return;
end
operaDir = fullfile(fileparts(mfilename('fullpath')), 'data_opera');
if ~isfolder(operaDir) || isempty(dir(fullfile(operaDir, 'OPERA_TIM_*.mat')))
    info.reason = 'data_opera/ lipseste sau este gol';
    warning('TIMRadar:NoOpera', 'OPERA cerut, dar %s. Se antreneaza doar pe TIM.', info.reason);
    return;
end

[XO, yO, fnO, tiO] = w3_extract_features(variant, 'Source', 'OPERA', ...
    'HorizonMinutes', taskInfo.horizonMinutes, 'Verbose', false);
[ok, loc] = ismember(featureNames, fnO);
if ~all(ok)
    error('TIMRadar:OperaFeatures', 'OPERA nu are trasaturile: %s', ...
        strjoin(featureNames(~ok), ', '));
end

va = taskInfo.split.val;
cutoff = taskInfo.timestamps(va(1)) - minutes(taskInfo.stepMinutes * ...
    (taskInfo.historyFrames + taskInfo.horizonFrames) + 60);
keep = tiO.targetTimestamps < cutoff;
Xo = XO(keep, loc);
yo = yO(keep);

info.used = true;
info.nRows = nnz(keep);
info.cutoff = cutoff;
info.reason = sprintf('%d esantioane OPERA cu tinta inainte de %s', info.nRows, string(cutoff));
if o.Verbose
    fprintf('   [OPERA] +%d esantioane de antrenament (din %d; tinta < %s)\n', ...
        info.nRows, numel(yO), string(cutoff));
end
end

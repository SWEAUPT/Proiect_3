function [out, scores] = w5_predict(model, sequences)
% W5_PREDICT Predictie cu modelul LSTM antrenat de w5_train_lstm.
%
% Semnatura:
%   preds            = w5_predict(model, sequences)   % regresie
%   [labels, scores] = w5_predict(model, sequences)   % clasificare
%
% Normalizarea salvata in model se aplica automat, astfel incat apelantii
% (w6, w7, main) sa nu duplice codul de normalizare si de impachetare a
% secventelor.

if ~iscell(sequences)
    error('TIMRadar:BadSequences', 'w5_predict asteapta un cell array de secvente.');
end
if isempty(sequences)
    out = []; scores = []; return;
end

np = model.normParams;
X = cell(numel(sequences), 1);
for i = 1:numel(sequences)
    s = sequences{i};
    if size(s, 1) ~= model.numChannels
        error('TIMRadar:ChannelMismatch', ...
            'Secventa %d are %d canale, modelul asteapta %d.', i, size(s, 1), model.numChannels);
    end
    % [canale x pasi] -> [pasi x canale], conventia ceruta de minibatchpredict
    X{i} = ((s - np.mu) ./ np.sigma).';
end

raw = minibatchpredict(model.modelObj, X);

if strcmp(model.taskType, 'regression')
    out = double(raw(:));
    % Daca modelul a fost antrenat pe SCHIMBAREA fata de persistenta, se adauga
    % inapoi ancora - ultima valoare observata a canalului de referinta.
    if isfield(model, 'anchorChannel') && ~isempty(model.anchorChannel)
        anchor = cellfun(@(s) s(model.anchorChannel, end), sequences(:));
        out = out + anchor;
    end
    scores = [];
else
    scores = double(raw);
    [~, k] = max(scores, [], 2);
    if isfield(model, 'classValues') && ~isempty(model.classValues)
        vals = model.classValues;
    else
        vals = str2double(string(model.classNames));
    end
    out = reshape(vals(k), [], 1);
end
end

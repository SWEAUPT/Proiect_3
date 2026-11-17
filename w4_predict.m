function [out, scores] = w4_predict(model, X)
% W4_PREDICT Predictie cu modelul Random Forest antrenat de w4_train_random_forest.
%
% Semnatura:
%   preds            = w4_predict(model, X)   % regresie
%   [labels, scores] = w4_predict(model, X)   % clasificare
%
% Simetric cu w5_predict. Exista pentru acelasi motiv: cand modelul este
% antrenat pe SCHIMBAREA fata de persistenta, valoarea bruta returnata de
% predict() nu este prognoza, ci un increment. Ancora trebuie adaugata inapoi,
% iar daca fiecare apelant o face pe cont propriu, mai devreme sau mai tarziu
% unul o uita.
%
% DE CE ANCORARE SI LA RANDOM FOREST
% ---------------------------------------------------------------------
% Un arbore nu poate returna o valoare in afara intervalului tintelor din
% antrenament, deci prezicand nivelul absolut satureaza pe orice segment de
% test mai ploios decat antrenamentul (R2 = -0.84 pe test, fata de +0.94 cu
% ancora). Cu ambele modele ancorate, w6 compara arhitecturi, nu doua
% parametrizari diferite ale tintei.

if ~isstruct(model) || ~isfield(model, 'modelObj')
    error('TIMRadar:BadModel', ...
        'w4_predict asteapta structura returnata de w4_train_random_forest.');
end
if isempty(X)
    out = []; scores = []; return;
end

nExpected = numel(model.featureNames);
if size(X, 2) ~= nExpected
    error('TIMRadar:FeatureCountMismatch', ...
        'X are %d coloane, modelul a fost antrenat pe %d.', size(X, 2), nExpected);
end

if strcmp(model.taskType, 'regression')
    out = double(predict(model.modelObj, X));
    out = out(:);
    if isfield(model, 'anchorColumn') && ~isempty(model.anchorColumn)
        % Reteaua/padurea a invatat delta; ancora este ultima valoare observata
        % a canalului de referinta, deja prezenta in X.
        out = out + X(:, model.anchorColumn);
    end
    if isfield(model, 'clampNonNegative') && model.clampNonNegative
        out = max(0, out);
    end
    scores = [];
else
    [lab, scores] = predict(model.modelObj, X);
    scores = double(scores);
    if iscategorical(lab) || iscell(lab) || isstring(lab)
        out = str2double(string(lab));
    else
        out = double(lab);
    end
    out = out(:);
end
end

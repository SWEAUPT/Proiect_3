function tests = test_w3_motion
% Teste pentru estimarea miscarii ecourilor (radar_phase_shift) si pentru
% tabelul de trasaturi de advectie (radar_motion_table).
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
testCase.TestData.dataDir = fullfile(root, 'data');
end

% ---------------------------------------------------------------------
function [Ia, Ib] = shifted_pair(sx, sy, n)
% Camp neted aleator, deplasat EXACT cu (sx, sy) pixeli prin rampa de faza.
rng(3);
f = imgaussfilt(rand(n), 6);
f = (f - min(f(:))) / (max(f(:)) - min(f(:)));
k = [0:(n/2 - 1), -n/2:-1].' / n;
ramp = exp(-2i * pi * (k * sy + k.' * sx));
Ia = f;
Ib = real(ifft2(fft2(f) .* ramp));       % Ib(r, c) = Ia(r - sy, c - sx)
end

function testRecoversKnownSubpixelShift(testCase)
for s = [3.4 -2.2; -7.0 5.6; 0 0]'
    [Ia, Ib] = shifted_pair(s(1), s(2), 128);
    [sx, sy, pk] = radar_phase_shift(Ia, Ib, 12);
    verifyEqual(testCase, [sx sy], s', 'AbsTol', 0.25, ...
        sprintf('Deplasarea (%g, %g) nu a fost regasita.', s(1), s(2)));
    verifyGreaterThan(testCase, pk, 0.3);
end
end

function testBatchMatchesSinglePairs(testCase)
% Toate perechile dintr-un lot trebuie tratate independent: un indice de
% pagina gresit ar amesteca deplasarile intre ele.
[a1, b1] = shifted_pair(2, -1, 128);
[a2, b2] = shifted_pair(-4, 3, 128);
[sx, sy] = radar_phase_shift(cat(3, a1, a2), cat(3, b1, b2), 12);
verifyEqual(testCase, [sx sy], [2 -1; -4 3], 'AbsTol', 0.25);
end

function testGpuMatchesCpu(testCase)
assumeTrue(testCase, canUseGPU(), 'Nu exista GPU.');
[Ia, Ib] = shifted_pair(5.3, -3.1, 128);
[sxC, syC] = radar_phase_shift(Ia, Ib, 12);
[sxG, syG] = radar_phase_shift(gpuArray(single(Ia)), gpuArray(single(Ib)), 12);
verifyEqual(testCase, double([sxG syG]), [sxC syC], 'AbsTol', 0.05);
verifyClass(testCase, sxG, 'single');      % rezultatul este adus inapoi din GPU
end

function testMotionTableOnRealFrames(testCase)
d = testCase.TestData;
assumeNotEmpty(testCase, dir(fullfile(d.dataDir, 'TIM_*dBZ.hdf')));
% Grilele carteziene (~0,5 GB pe arhiva completa) merg intr-un folder temporar.
% Statisticile pe cadru folosesc cache-ul obisnuit din data/, la care se pot
% ADAUGA cadre noi, exact ca la rularea lui main.
tmp = tempname; mkdir(tmp);
cleanup = onCleanup(@() rmdir(tmp, 's')); %#ok<NASGU>
[M, meta] = radar_motion_table(d.dataDir, 'MaxFrames', 40, 'UseParallel', false, ...
    'CacheFile', fullfile(tmp, 'cart.mat'), 'Verbose', false);
verifyEqual(testCase, height(M), meta.nFrames);
cols = {'motionU', 'motionV', 'motionSpeed', 'motionQuality', 'advArealDelta', ...
        'advRainFracDelta', 'inflowRain', 'outflowRain'};
for c = cols
    verifyTrue(testCase, all(isfinite(M.(c{1}))), ['NaN/Inf in ' c{1}]);
end
verifyTrue(testCase, issorted(M.timestamp));
% Plafonul fizic din functie este 150 km/h.
verifyLessThanOrEqual(testCase, max(M.motionSpeed), 150 * sqrt(2) + 1);
% Primele LagFrames cadre nu au cadru precedent: miscare necunoscuta.
verifyEqual(testCase, M.motionQuality(1:2), [0; 0]);
verifyTrue(testCase, isfile(fullfile(tmp, 'cart.mat')));
end

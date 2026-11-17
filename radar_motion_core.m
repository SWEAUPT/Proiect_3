function [Mo, info] = radar_motion_core(Q, ts, have, disc, Xkm, Ykm, Rmax, o)
% RADAR_MOTION_CORE Miscarea si advectia pe o stiva de grile carteziene (GPU).
%
% Nucleul comun al radar_motion_table (radarul TIM, grile din sweep-ul polar)
% si al opera_feature_table (compozitul OPERA, grile din decupajul de 1 km).
% Ambele construiesc aceeasi grila de 2 km centrata pe radarul TIM, deci
% trasaturile de miscare au aceeasi definitie pe ambele surse.
%
%   Q     uint8 [n n nF], R pe scara logaritmica: R = expm1(q/255*log1p(QMAX))
%         randul 1 = SUD, coloana 1 = vest
%   ts    datetime [nF 1], cronologic
%   have  logical [nF 1], cadrul exista in stiva
%   disc  logical [n n], celulele din cercul de raza Rmax
%   Xkm, Ykm  coordonatele centrelor de celula fata de radar (km, est / nord)
%   o     struct: HorizonMinutes, LagFrames, CellKm, MinRainForMotion,
%         MinRainCells, useGPU, stepMin, QMAX; optional clutter [n n] logical
%         (harta de ecou static calculata dinainte pe tot setul)
%
%   Mo    [nF 8]: motionU, motionV, motionQuality, advArealDelta,
%         advRainFracDelta, inflowRain, outflowRain, cartArealRain
%   info  struct: clutter (harta), gpuSeconds

CLUTTER_FREQ = 0.25;
RAIN_MIN = 0.1;                     % acelasi prag ca rainAreaFraction din w2
EDGE_KM = 40;
QMAX = o.QMAX;
useGPU = o.useGPU;
nF = size(Q, 3);
n = size(Q, 1);
stepMin = o.stepMin;

lag = round(o.LagFrames);
lagMin = lag * stepMin;
scale = o.HorizonMinutes / lagMin;          % deplasarea pe orizont / deplasarea pe lag
pairOK = false(nF, 1);
for i = (lag + 1):nF
    pairOK(i) = have(i) && have(i - lag) && ...
        abs(minutes(ts(i) - ts(i - lag)) - lagMin) <= stepMin / 2;
end

dev = @(x) x;
if useGPU, dev = @gpuArray; end
discG = dev(single(disc));
nDisc = sum(disc(:));

% clutter: frecventa cu care fiecare celula depaseste 0.5 mm/h, pe toata arhiva.
% Cine proceseaza arhiva pe bucati (OPERA, zi cu zi) o calculeaza o singura data
% pe tot setul si o transmite in o.clutter - altfel fiecare zi ar avea alta harta.
if isfield(o, 'clutter') && ~isempty(o.clutter)
    clutter = dev(logical(o.clutter)) & discG > 0;
else
    qThr = clutter_threshold(QMAX);
    cnt = zeros(n, n, 'like', discG);
    for c0 = 1:2000:nF
        idx = c0:min(nF, c0 + 1999);
        cnt = cnt + sum(dev(Q(:, :, idx)) > qThr, 3);
    end
    clutter = (cnt / nF) > CLUTTER_FREQ & discG > 0;
end
mobile = discG .* single(~clutter);

% fereastra: atenuare cosinus pe ultimii 30 km, ca marginea discului sa nu
% devina o structura fixa care trage corelatia spre deplasare zero
rKm = hypot(Xkm, Ykm);
taper = 0.5 * (1 + cos(pi * min(1, max(0, (rKm - (Rmax - 30)) / 30))));
win = dev(single(taper .* disc));

maxPx = ceil(150 / 60 * lagMin / o.CellKm);        % plafon fizic: 150 km/h
N2 = 2 * n;
ky = dev(single([0:(N2/2 - 1), -N2/2:-1].' / N2));       % frecvente pe grila dublata
kx = ky.';
% Trece-jos gaussian pe spectrul de corelatie: corelatia de faza pura
% amplifica zgomotul de inalta frecventa la fel de mult ca structura ploii.
lpn = exp(-fftfreq2(n, dev) / (2 * 0.15^2));

annulus = dev(single(disc & rKm >= Rmax - EDGE_KM));
Xg = dev(single(Xkm)); Yg = dev(single(Ykm));

U = zeros(nF, 1); V = zeros(nF, 1); QL = zeros(nF, 1);
advA = zeros(nF, 1); advF = zeros(nF, 1); inflow = zeros(nF, 1); outflow = zeros(nF, 1);
cartA = zeros(nF, 1);

t0 = tic;
batch = 200;
for b0 = 1:batch:nF
    idx = b0:min(nF, b0 + batch - 1);
    R = dequant(dev(Q(:, :, idx)), QMAX);                         % [n n m] mm/h
    cartA(idx) = gather(squeeze(sum(sum(R .* discG, 1), 2)) / nDisc);

    prevIdx = idx - lag;
    valid = pairOK(idx);
    if ~any(valid), continue; end
    vi = idx(valid);
    Rb = R(:, :, valid);
    Ra = dequant(dev(Q(:, :, prevIdx(valid))), QMAX);

    % ---- miscarea: corelatie de faza pe log(1+R) al ecoului mobil ----
    % Doar PRECIPITATIA (>= MinRainForMotion) intra in corelatie. In cadrele
    % fara ploaie organizata, ecourile slabe si aproape fixe (aer clar, clutter
    % slab) ar domina corelatia si ar da "0 km/h" cu aer de certitudine.
    Ia = log1p(Ra) .* (Ra >= o.MinRainForMotion) .* mobile .* win;
    Ib = log1p(Rb) .* (Rb >= o.MinRainForMotion) .* mobile .* win;
    [sx, sy, pk] = radar_phase_shift(Ia, Ib, maxPx, lpn);  % sy: randuri = nord
    m = numel(sx);

    % prea putin ecou mobil in oricare cadru: miscarea nu are sens
    echoA = gather(squeeze(sum(sum((Ra .* mobile) >= o.MinRainForMotion, 1), 2)));
    echoB = gather(squeeze(sum(sum((Rb .* mobile) >= o.MinRainForMotion, 1), 2)));
    good = (echoA >= o.MinRainCells) & (echoB >= o.MinRainCells) & ...
           isfinite(sx(:)) & isfinite(sy(:));
    sx(~good) = 0; sy(~good) = 0; pk(~good) = 0;

    U(vi) = sx(:) * o.CellKm * 60 / lagMin;
    V(vi) = sy(:) * o.CellKm * 60 / lagMin;
    QL(vi) = pk(:);

    % ---- advectia pe orizont: rampa de faza pe grila dublata ----
    Rm = Rb .* mobile;
    Rs = Rb .* single(clutter);
    P = zeros(N2, N2, m, 'like', Rm);
    P(1:n, 1:n, :) = Rm;
    shy = reshape(single(sy(:) * scale), 1, 1, []);
    shx = reshape(single(sx(:) * scale), 1, 1, []);
    if useGPU, shy = gpuArray(shy); shx = gpuArray(shx); end
    ramp = exp(complex(0, -2 * pi) * (ky .* shy + kx .* shx));
    Pa = real(ifft2(fft2(P) .* ramp));
    Radv = max(Pa(1:n, 1:n, :), 0) .* discG + Rs;

    A0 = squeeze(sum(sum(Rb .* discG, 1), 2)) / nDisc;
    A1 = squeeze(sum(sum(Radv, 1), 2)) / nDisc;
    Fr0 = squeeze(sum(sum((Rb >= RAIN_MIN) .* discG, 1), 2)) / nDisc;
    Fr1 = squeeze(sum(sum((Radv >= RAIN_MIN) .* discG, 1), 2)) / nDisc;
    advA(vi) = gather(A1 - A0);
    advF(vi) = gather(Fr1 - Fr0);

    % ---- ploaia de pe marginea din amonte / aval ----
    uu = reshape(single(U(vi)), 1, 1, []); vv = reshape(single(V(vi)), 1, 1, []);
    if useGPU, uu = gpuArray(uu); vv = gpuArray(vv); end
    dotp = Xg .* uu + Yg .* vv;
    up = annulus .* (dotp < 0);
    dn = annulus .* (dotp > 0);
    inflow(vi)  = gather(squeeze(sum(sum(Rb .* up, 1), 2)) ./ max(1, squeeze(sum(sum(up, 1), 2))));
    outflow(vi) = gather(squeeze(sum(sum(Rb .* dn, 1), 2)) ./ max(1, squeeze(sum(sum(dn, 1), 2))));
    noMotion = ~good;
    inflow(vi(noMotion)) = 0; outflow(vi(noMotion)) = 0;
    advA(vi(noMotion)) = 0;  advF(vi(noMotion)) = 0;
end

Mo = [U, V, QL, advA, advF, inflow, outflow, cartA];
info = struct('clutter', gather(clutter), 'clutterFraction', gather(sum(clutter(:)) / nDisc), ...
    'gpuSeconds', toc(t0), 'lagMinutes', lagMin);
end

% =====================================================================
function q = clutter_threshold(QMAX)
q = uint8(round(255 * log1p(0.5) / log1p(QMAX)));
end

% =====================================================================
function R = dequant(q, QMAX)
R = expm1(single(q) / 255 * log1p(QMAX));
end

% =====================================================================
function f2 = fftfreq2(n, dev)
% |k|^2 pe grila FFT (frecvente normalizate in cicluri/pixel), ordine FFT.
k = dev(single([0:(n/2 - 1), -n/2:-1].' / n));
f2 = k.^2 + (k.').^2;
end

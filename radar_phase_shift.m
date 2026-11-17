function [sx, sy, peak] = radar_phase_shift(Ia, Ib, maxPx, lowpass)
% RADAR_PHASE_SHIFT Deplasarea globala dintre doua imagini, prin corelatie de faza.
%
%   [sx, sy, peak] = radar_phase_shift(Ia, Ib, maxPx)
%   [sx, sy, peak] = radar_phase_shift(Ia, Ib, maxPx, lowpass)
%
% Ia, Ib  [n x n x m] - m perechi de imagini (pot fi gpuArray: totul ruleaza
%         pe GPU, toate perechile deodata). n trebuie sa fie par.
% maxPx   cea mai mare deplasare cautata, in pixeli (plafon fizic).
% lowpass [n x n] ponderi pe spectru, in ordinea FFT (optional).
%
% sx, sy  deplasarea lui Ib fata de Ia, in pixeli, pe coloane (sx) si pe
%         randuri (sy), cu precizie sub-pixel (interpolare parabolica).
%         Daca Ib(r, c) = Ia(r - sy, c - sx), rezultatul este (sx, sy).
% peak    inaltimea varfului de corelatie (1 = potrivire perfecta).
%
% Principiul: o translatie in spatiu este o rampa de faza in spectru. Spectrul
% de putere incrucisat, normalizat la modul 1, pastreaza doar faza; transformata
% lui inversa este un varf ascutit exact la deplasare.

n = size(Ia, 1);
m = size(Ia, 3);
X = fft2(Ib) .* conj(fft2(Ia));
X = X ./ max(abs(X), 1e-6);
if nargin >= 4 && ~isempty(lowpass)
    X = X .* lowpass;
end
cc = fftshift(fftshift(real(ifft2(X)), 1), 2);     % deplasarea zero ajunge in centru
ctr = n / 2 + 1;
w = (ctr - maxPx - 1):(ctr + maxPx + 1);           % +1 margine pentru interpolare
sub = cc(w, w, :);
inner = sub(2:end - 1, 2:end - 1, :);
[peak, li] = max(reshape(inner, [], m), [], 1);
[r0, c0] = ind2sub([2 * maxPx + 1, 2 * maxPx + 1], li);
r0 = r0 + 1; c0 = c0 + 1;                          % indici in `sub`
ps = numel(sub(:, :, 1));
pg = (0:m - 1) * ps;
at = @(r, c) sub(sub2ind([size(sub, 1), size(sub, 2)], r, c) + pg);
dr = parabolic(at(r0 - 1, c0), at(r0, c0), at(r0 + 1, c0));
dc = parabolic(at(r0, c0 - 1), at(r0, c0), at(r0, c0 + 1));
sy = gather(reshape(r0 + dr - (maxPx + 2), [], 1));
sx = gather(reshape(c0 + dc - (maxPx + 2), [], 1));
peak = gather(reshape(peak, [], 1));
end

% =====================================================================
function d = parabolic(a, b, c)
% Varful sub-pixel al unei parabole prin trei puncte egal departate.
den = a - 2 * b + c;
d = zeros(size(b), 'like', b);
ok = abs(den) > 1e-12;
d(ok) = 0.5 * (a(ok) - c(ok)) ./ den(ok);
d = max(-0.5, min(0.5, d));
end

function A = vc_analyze(x, fs, fmin, fmax)
%VC_ANALYZE  Analysis pass: F0 (YIN), voicing ratio, spectral centroid.
%
%   A = VC_ANALYZE(X, FS, FMIN, FMAX) returns
%
%       A.f0      median F0 of the voiced frames (Hz, NaN if none)
%       A.voiced  fraction of frames considered voiced
%       A.cent    median spectral centroid over the voiced frames (Hz)
%       A.rms     RMS level
%       A.track   per-frame F0 track (Hz, NaN where unvoiced)
%
%   The pitch tracker is the YIN estimator: it works on the cumulative mean
%   normalised squared difference function
%
%       d(tau) = sum_j (x(j) - x(j+tau))^2 ,  d'(tau) = d(tau) / mean(d(1..tau))
%
%   which - unlike plain autocorrelation - has no lag-0 lobe, so the first
%   dip below a fixed threshold is the period and not a spurious peak of the
%   decaying main lobe.
%
%   Everything is vectorised over frames; no per-frame loop is used except the
%   O(1) bookkeeping loop of the dip search.
%
%   This routine is used for reporting and for the absolute-target pitch mode;
%   the pitch/formant conversion itself does not depend on it.

x = double(x(:));
n = numel(x);
if nargin < 3 || isempty(fmin), fmin = 60;  end
if nargin < 4 || isempty(fmax), fmax = 500; end

A = struct('f0', NaN, 'voiced', 0, 'cent', NaN, 'rms', 0, 'track', []);
if n < 128
    return
end
A.rms = sqrt(mean(x .^ 2));

% ---------------------------------------------------------------- frames
% Only the first NFMAX frames are tracked: the estimate is a median over
% frames, so a bounded prefix gives the same answer for a fraction of the cost
% on long recordings (and keeps the 1 s per-run budget).
flen = min(n, 2 * round(fs / fmin));        % >= two periods of fmin
flen = max(64, 2 * round(flen / 2));
fhop = round(flen / 2);
NFMAX = 400;
nf   = min(1 + floor((n - flen) / fhop), NFMAX);
fidx = (1:flen).' + (0:(nf - 1)) * fhop;    % [flen x nf], 1-based
fr   = x(fidx);
fr   = fr - mean(fr, 1);                    % per-frame DC removal: an offset would
                                            % otherwise dominate the difference fn

% ------------------------------------------------- difference function (YIN)
nfft = 2 ^ nextpow2(2 * flen);
F = fft(fr, nfft, 1);
ac = real(ifft(F .* conj(F), nfft, 1));
ac = ac(1:(nfft / 2 + 1), :);
power = ac(1, :);                           % sum x^2 per frame, [1 x nf]

tau  = (1:flen).';                          % lags 1..flen  (all terms inside the frame)
csum = [zeros(1, nf); cumsum(fr .^ 2, 1)];  % [flen+1 x nf] running energy
cs   = csum(flen + 1, :) - csum(tau, :);    % sum_{j=tau+1..flen} x^2, [flen x nf]
d    = power + cs - 2 * ac(tau + 1, :);     % difference function,  [flen x nf]
d    = max(d, 0);
d    = d ./ (cumsum(d, 1) ./ tau);          % cumulative mean normalised
d(1, :) = 1;

% ------------------------------------------------------------ F0 per frame
lag_lo = max(2, floor(fs / fmax));
lag_hi = min(flen - 1, ceil(fs / fmin));
track  = NaN(nf, 1);
if lag_hi > lag_lo + 2
    band = d(lag_lo:lag_hi, :);
    [dmin, imin] = min(band, [], 1);

    % Period selection: the first local minimum of the normalised difference
    % curve.  A dip has to be lower than its neighbours, and an absolute
    % threshold backstop rejects dips that are not deep enough to count as
    % periodicity at all; if no such dip exists the global minimum is kept.
    dl_ = [band(1, :); band; band(end, :)];      % pad: neighbours of the ends
    ismin = (band < dl_(1:end - 2, :)) & (band <= dl_(3:end, :));
    deep  = band < max(0.35, 0.9 * dmin);
    cand  = ismin & deep;
    hit   = cumsum(cand, 1) > 0;
    [anyhit, rel] = max(hit, [], 1);
    rel(~anyhit) = imin(~anyhit);
    found = anyhit;
    lag = lag_lo + rel - 1;

    % Parabolic refinement of the dip position.
    i0 = max(lag - 1, lag_lo);
    i2 = min(lag + 1, lag_hi);
    y0 = d(sub2ind(size(d), i0, 1:nf));
    y1 = d(sub2ind(size(d), lag, 1:nf));
    y2 = d(sub2ind(size(d), i2, 1:nf));
    den = y0 - 2 * y1 + y2;
    dl = zeros(1, nf);
    g = (i0 < lag) & (lag < i2) & (abs(den) > 1e-12);
    dl(g) = 0.5 * (y0(g) - y2(g)) ./ den(g);
    dl = max(-0.5, min(0.5, dl));

    f0f = fs ./ (lag + dl);
    rms = sqrt(power / flen);               % [1 x nf]
    % Silence test on an ABSOLUTE scale: a purely relative threshold
    % (a fraction of the median frame RMS) rejects every frame of a quiet but
    % perfectly periodic signal - which is exactly what a level-normalised
    % conversion produces (measured: -42 dBFS output, reported as unvoiced).
    thr = 10 ^ (-60 / 20);                  % -60 dBFS counts as silence
    yin = d(sub2ind(size(d), lag, 1:nf));   % YIN value of the selected period
    voiced = (yin < 0.5) & (rms > thr) & (f0f > fmin) & (f0f < fmax);
    track(voiced) = f0f(voiced);
    A.track  = track;
    A.voiced = mean(voiced);
    if any(voiced)
        A.f0 = median(track(voiced));
    end
end

% ------------------------------------------- spectral centroid (per frame)
cwin  = 0.5 - 0.5 * cos(2 * pi * (0:(flen - 1)).' / flen);
cnfft = 2 ^ nextpow2(4 * flen);
CF = fft(fr .* cwin, cnfft, 1);
CF = CF(1:(cnfft / 2 + 1), :);
CP = abs(CF) .^ 2;
cbin = (0:(cnfft / 2)).' * (fs / cnfft);
den  = sum(CP, 1);
good = den > 0;
cent = NaN(nf, 1);
cent(good) = sum(cbin .* CP(:, good), 1) ./ den(good);

sel = ~isnan(A.track) & ~isnan(cent);
if ~any(sel)
    sel = ~isnan(cent);
end
if any(sel)
    A.cent = median(cent(sel));
end
end

function w = hann_loc(n)
k = (0:(n - 1)).';
w = 0.5 - 0.5 * cos(2 * pi * k / n);
end

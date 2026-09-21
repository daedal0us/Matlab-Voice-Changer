function [x, fs, truth] = vc_synthvoice(fs, dur, f0, formants, seed)
%VC_SYNTHVOICE  Synthetic "speech" test signal (source-filter model).
%
%   [X, FS, TRUTH] = VC_SYNTHVOICE(FS, DUR, F0, FORMANTS, SEED) builds a
%   voiced test signal with a known F0 (Hz) and known formant frequencies
%   (Hz), so that pitch shifting and formant scaling can be verified
%   numerically without any external audio file.
%
%   TRUTH.f0 and TRUTH.formants echo the requested values.

if nargin < 1 || isempty(fs),       fs = 16000;          end
if nargin < 2 || isempty(dur),      dur = 2.0;           end
if nargin < 3 || isempty(f0),       f0 = 120;            end
if nargin < 4 || isempty(formants), formants = [700 1220 2600 3400]; end
if nargin < 5 || isempty(seed),     seed = 7;            end

n = round(fs * dur);
t = (0:(n - 1)).' / fs;
rs = RandStream('mt19937ar', 'Seed', seed);

% ---- F0 contour: slow declination + gentle vibrato + tiny jitter ----
f0t = f0 * (1 - 0.06 * (t / t(end))) ...
      + f0 * 0.006 * sin(2 * pi * 5.2 * t) ...
      + f0 * 0.002 * randn(rs, n, 1);

% ---- utterance layout: three "syllables" with pauses ---------------
env = zeros(n, 1);
segs = [0.05 0.38; 0.46 0.72; 0.80 0.97];
for i = 1:size(segs, 1)
    a = max(1, round(segs(i, 1) * n));
    b = min(n, round(segs(i, 2) * n));
    L = b - a + 1;
    s = 0.5 - 0.5 * cos(2 * pi * (0:(L - 1)).' / (L - 1));      % raised cosine
    env(a:b) = s .^ 0.7;
end
% slow syllabic amplitude ripple inside the voiced parts
env = env .* (1 + 0.10 * sin(2 * pi * 3.4 * t));

% ---- glottal source: phase-continuous pulse train ------------------
ph = cumsum(2 * pi * f0t / fs);
r = 0.02;                                   % glottal pulse width (fraction of period)
pul = zeros(n, 1);
per = fs ./ f0t;                            % instantaneous period in samples
p1 = mod((0:(n - 1)).', per);               % position within the period
m = p1 < r * per;
pul(m) = 0.5 * (1 - cos(pi * p1(m) ./ (r * per(m))));
source = -diff([0; pul]) * fs / (2 * pi) * 1e-3;    % differentiated pulse
src = source + 0.05 * env .* randn(rs, n, 1);       % a little aspiration
src = src .* env;

% ---- vocal tract: cascade of 2-pole resonators ---------------------
v = src;
for i = 1:numel(formants)
    F = formants(i);
    if i == 1
        BW = 70;  else
        BW = 110;
    end
    w0 = 2 * pi * F / fs;
    rr = exp(-pi * BW / fs);
    a1 = -2 * rr * cos(w0);
    a2 = rr ^ 2;
    g = (1 - rr) * sqrt(1 - 2 * rr * cos(2 * w0) + rr ^ 2);
    v = filter(g, [1 a1 a2], v);
end

x = v;
x = x / max(abs(x)) * 0.9;

truth = struct('f0', f0, 'formants', formants, 'fs', fs, 'dur', dur);
end

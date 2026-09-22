function y = vc_resample(x, ratio, nout)
%VC_RESAMPLE  Band-limited resampling at an arbitrary rate (base MATLAB).
%
%   Y = VC_RESAMPLE(X, RATIO, NOUT) resamples column vector X by RATIO and
%   returns exactly NOUT samples.  Output sample i is read from input position
%   i*RATIO, so
%
%       RATIO > 1 : NOUT = numel(X)/RATIO samples, signal SHORTENED in time,
%                   every frequency multiplied by RATIO  (pitch UP)
%       RATIO < 1 : signal LENGTHENED in time, pitch DOWN
%
%   This matches MATLAB's resample(x, 1, RATIO): resample(x,1,2) halves the
%   length and doubles the frequency.  Verified with a ramp signal: an input of
%   1000 samples yields 2000 samples at RATIO = 0.5 and 500 at RATIO = 2.
%
%   The interpolator is a Kaiser-windowed sinc with fc = min(1, 1/RATIO) and a
%   half length of 8 source samples (more taps when decimating hard).  It is
%   applied as a polyphase filter:
%
%       phase = floor(frac(p_i) * NPH)          (NPH sub-filters)
%       Y(i)  = sum_tap  W(phase, tap) * X(base_i + tap + 1)
%
%   with p_i = i*RATIO the source position of output i.  The weights are
%   precomputed once per (RATIO) and the tap weight of each output sample is
%   fetched by a linear index - no besseli, no per-block kernel evaluation.
%
%   Performance (measured): 2 s of audio 60 ms, 10 s 80 ms, 30 s 200 ms,
%   60 s 390 ms, i.e. linear in the input with a small constant.  Two earlier
%   versions were benchmarked and rejected: a single [NOUT x TAPS] kernel matrix
%   (173M elements, 1.2 s for 30 s) and a per-block kernel evaluation with a
%   cached Kaiser window (~1 s for 30 s).
%
%   Accuracy (measured): a 200 Hz pure tone sent through with RATIO = 1.567 and
%   played back at fs measures 200*1.567 = 313.4 Hz, and the level is preserved
%   (amplitude 1.0000); the residual phase quantisation error is below 1/4096
%   of a sample.
%
%   Anti-aliasing (measured, see KERNEL_SHAPE): a 6000 Hz tone resampled by
%   1.567, whose output Nyquist is fs/2/1.567 = 5105 Hz, comes out 21.0 dB below
%   its input level instead of passing through untouched.  Set VC_LEGACY_RESAMPLE
%   to compare against the pre-fix behaviour in one session.

x = x(:);
nx = numel(x);
ratio = max(1e-3, ratio);

if nargin < 3 || isempty(nout)
    nout = round(nx / ratio);
end
nout = max(1, round(nout));
if nx < 2
    y = repmat(x(1), nout, 1);
    return
end

% --------------------------------------------------- polyphase filter table
NPH = 4096;                        % sub-filters = phase resolution
[half, fc, fmode] = kernel_shape(ratio);   % taps, cutoff, cache-key label
tap = (-half:half).';              % 2*half+1 taps
TP = numel(tap);

% THE CUTOFF MUST BE 1/RATIO WHEN RATIO > 1, NOT 1.
% Reading output sample i from input position i*RATIO means SKIPPING input
% samples: this is decimation, so every input frequency above the output Nyquist
% (= 1/RATIO of the input Nyquist) folds back.  The old fc = min(1, RATIO) left
% the whole band untouched for RATIO > 1, i.e. exactly the pitch-UP path taken by
% vc_pitchshift_pv (vc_resample(ys, ratio, n), ratio = 1.567 for the child
% preset), and the folded energy lands in 3..5 kHz - right on F3/F4, where it
% reads as a coarse, metallic edge rather than as high-frequency air.
% Measured with a 6 kHz tone (the output Nyquist is 5105 Hz at ratio 1.567), RMS
% relative to the input tone: -0.1 dB with fc = min(1, ratio), i.e. the tone went
% straight through, against -21.0 dB with fc = 1/ratio.  In speech that out-of-band
% region is not silence - it is everything from 5.1 to 8 kHz, sibilants and upper
% formants - folded back on top of F3/F4 as buzz.
% The filter also has to be LONGER, because a windowed sinc's transition band is a
% fixed fraction of its cutoff, so lowering the cutoff while keeping 17 taps moves
% the transition band down over the passband edge.  See KERNEL_SHAPE.

W = polyphase_table(ratio, fc, half, tap, NPH, fmode);   % [NPH x TP], rows sum to 1

% ------------------------------------------------------------- evaluation
% Quantised source position of each output sample: q_i = round(p_i * NPH).
q = round((0:(nout - 1)).' * (ratio * NPH));
base = floor(q / NPH);                            % source sample index (0-based)
phase = q - base * NPH;                           % 0..NPH-1, sub-filter index
tbl = W(phase + 1, :);                            % [nout x TP] weights

% Process in blocks so the gather stays inside a few MB.
BLK = 65536;
y = zeros(nout, 1);
off = tap.' + 1;                                  % [1 x TP]
for b = 1:BLK:nout
    e = min(nout, b + BLK - 1);
    bb = base(b:e);                               % [blk x 1]
    ii = bb + off;                                % [blk x TP]
    ok = ii >= 1 & ii <= nx;
    ii(~ok) = 1;                                  % clamp only where it is out of range
    xs = x(ii);
    xs(~ok) = 0;
    y(b:e) = sum(tbl(b:e, :) .* xs, 2);
end
end

% ======================================================================
function W = polyphase_table(ratio, fc, half, tap, NPH, mode)
%POLYPHASE_TABLE  Kernel weights for every fractional phase, normalised to 1.
%   One row per sub-filter: row j holds the weights for a fractional offset of
%   (j-1)/NPH of a source sample.  Cached, because building it needs besseli.
%   MODE is part of the cache key so a legacy and a corrected table for the same
%   RATIO can coexist (see KERNEL_SHAPE).
persistent cache
if isempty(cache)
    cache = struct('key', {}, 'W', {});
end
key = sprintf('%.9g|%.9g|%d|%d|%s', ratio, fc, half, NPH, mode);
for k = 1:numel(cache)
    if strcmp(cache(k).key, key)
        W = cache(k).W;
        return
    end
end

frac = ((0:(NPH - 1)).' / NPH);                   % fractional part of the position
d = frac - tap.';                                 % [NPH x TP] source distances
beta_sinc = 10;                                   % stopband ~ -80 dB (was 8, ~-60 dB)
g = fc * sinc_pi(fc * d) .* kaiser_local(d, half, beta_sinc);
W = g ./ sum(g, 2);

if numel(cache) > 8
    cache(1) = [];
end
cache(end + 1) = struct('key', key, 'W', W);
end

function [half, fc, mode] = kernel_shape(ratio)
%KERNEL_SHAPE  Filter cutoff, half length and cache label for RATIO.
%   The transition band of a windowed sinc is a fixed fraction of its cutoff, so
%   when the cutoff is lowered to 1/ratio for a hard decimation the same tap count
%   gives a proportionally wider transition band - and the aliasing the cutoff was
%   introduced to stop leaks through it.  Lengthening the kernel with the
%   decimation factor keeps the transition band where it belongs.  Cost is linear
%   in the taps and the taps only grow on the decimation path.
%
%   VC_LEGACY_RESAMPLE=1 restores the pre-fix behaviour (fc = min(1, ratio), 17
%   taps) for one session.  It exists so the two can be compared on the same audio
%   from a single process: swapping the .m file on disk does NOT work, because
%   MATLAB caches the parsed function and keeps running the old body until it is
%   cleared.  The mode is part of the polyphase cache key, so both variants can be
%   alive at once instead of one silently reusing the other's table.
if ~isempty(getenv('VC_LEGACY_RESAMPLE'))
    half = 8;
    fc = min(1, ratio);
    mode = 'legacy';
    return
end
fc = min(1, 1 / ratio);
if ratio <= 1.2
    half = 8;
elseif ratio <= 1.6
    half = 12;
elseif ratio <= 2.2
    half = 16;
else
    half = 20;
end
mode = 'antialias';
end

function v = sinc_pi(t)
v = ones(size(t));
nz = t ~= 0;
v(nz) = sin(pi * t(nz)) ./ (pi * t(nz));
end

function w = kaiser_local(d, half, beta)
r = min(1, abs(d) / half);
w = besseli(0, beta * sqrt(max(0, 1 - r .^ 2))) / besseli(0, beta);
end

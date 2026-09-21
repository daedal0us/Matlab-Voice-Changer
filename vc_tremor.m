function y = vc_tremor(x, fs, depth_pct, rate_hz, wobble_hz, wobble_pct)
%VC_TREMOR  Slow, bounded pitch/level instability (the "old voice" tremor).
%
%   Y = VC_TREMOR(X, FS, DEPTH_PCT, RATE_HZ, WOBBLE_HZ, WOBBLE_PCT) performs a
%   time-varying fractional-delay resampling: the local playback rate is
%   1 + trem(t) + wob(t) instead of 1.
%
%       DEPTH_PCT   peak pitch deviation of the tremor, in percent
%       RATE_HZ     tremor rate (typically 4-7 Hz for senile tremor)
%       WOBBLE_HZ   slow secondary component (0 disables it)
%       WOBBLE_PCT  peak deviation of the slow component, in percent
%
%   DEV = 1/100 is added back in the rate so that the mean rate is exactly 1
%   (DEPTH is expressed as an amplitude deviation).

if nargin < 5, wobble_hz = 0;  end
if nargin < 6, wobble_pct = 0; end

x = double(x(:));
n = numel(x);
y = x;
if n < 4 || (depth_pct <= 0 && wobble_pct <= 0)
    return
end

t = (0:(n - 1)).' / fs;
r = 1 + (depth_pct / 100) * -cos(2 * pi * rate_hz * t);     % mean rate == 1
if wobble_hz > 0 && wobble_pct > 0
    r = r + (wobble_pct / 100) * -cos(2 * pi * wobble_hz * t + 1.1);
end

p = cumsum(r);                       % source position (samples) per output sample
y = zeros(n, 1);

i0 = floor(p);
f = p - i0;
i0 = i0 + 1;                         % 1-based
ok = (i0 >= 1) & (i0 + 1 <= n);
y(ok) = (1 - f(ok)) .* x(i0(ok)) + f(ok) .* x(i0(ok) + 1);
end

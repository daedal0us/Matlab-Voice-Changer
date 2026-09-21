function [y, noise] = vc_breath(x, fs, pct, seed)
%VC_BREATH  Add envelope-scaled, mildly high-pass shaped breath noise.
%
%   [Y, NOISE] = VC_BREATH(X, FS, PCT, SEED) mixes band-passed noise into X at
%   a level of PCT percent of the short-term signal envelope.  The noise is
%   shaped by a zero-phase first-order high-pass in the frequency domain (no
%   delay compensation needed) and is scaled by the envelope, which keeps
%   pauses quiet instead of adding a constant hiss.
%
%   A private random stream is used, so the caller's global RNG state is not
%   touched.

if nargin < 4 || isempty(seed)
    seed = 12345;
end

x = double(x(:));
y = x;
noise = zeros(size(x));
n = numel(x);
if n < 8 || pct <= 0
    return
end

rs = RandStream('mt19937ar', 'Seed', seed);
r = rand(rs, n, 1) * 2 - 1;

% Zero-phase high-pass shaping of white noise (kills the low-frequency rumble).
R = fft(r);
nh = floor(n / 2) + 1;
fn = (0:(nh - 1)).' / max(1, nh - 1);            % normalised frequency 0..1
sh = fn ./ sqrt(fn .^ 2 + (200 / (fs / 2)) ^ 2); % ~unity above ~200 Hz
R(1:nh) = R(1:nh) .* sh;
r = real(ifft(R));
r = r / max(sqrt(mean(r .^ 2)), 1e-12);

e = vc_localenv(x, fs, 20);
e = e / max(max(e), 1e-12);
noise = (pct / 100) * r .* e;
y = x + noise;
end

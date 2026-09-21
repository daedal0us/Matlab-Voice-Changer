function [M, P, win, hop] = vc_stft(x, nfft, hop)
%VC_STFT  Short-time Fourier analysis (base MATLAB only, fully vectorized).
%
%   [M,P,WIN,HOP] = VC_STFT(X, NFFT, HOP) returns the magnitude and wrapped
%   phase spectrograms of column vector X, with NFFT rows (the full spectrum,
%   so every row has a well defined bin frequency).  WIN is the periodic Hann
%   window of length NFFT and HOP the frame advance.
%
%   The frame matrix is built with implicit expansion (no per-frame loop),
%   which keeps the whole analysis at a single batched FFT.

x = x(:);
win = hann_local(nfft);
if nargin < 3 || isempty(hop)
    hop = nfft / 4;
end
hop = max(1, round(hop));

n = numel(x);
if n < nfft                                   % zero-pad very short inputs
    x = [x; zeros(nfft - n, 1)];
    n = nfft;
end
nf = 1 + floor((n - nfft) / hop);

idx = (1:nfft).' + (0:(nf - 1)) * hop;        % [nfft x nf] 1-based sample indices

% The FULL spectrum (all nfft bins) is kept, not the one-sided half.  A phase
% vocoder has to propagate the phase of every bin with its own bin frequency; a
% one-sided matrix cannot be paired with a symmetric frequency vector, and
% getting that wrong transposes the pitch instead of shifting it (this was a
% real bug: it produced 176 Hz where 128 Hz was expected).
X = fft(x(idx) .* win, nfft, 1);              % single batched FFT
M = abs(X);
P = angle(X);
end

function w = hann_local(n)
% Periodic Hann window without depending on the Signal Processing Toolbox.
k = (0:(n - 1)).';
w = 0.5 - 0.5 * cos(2 * pi * k / n);
end

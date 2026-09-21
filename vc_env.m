function [env, mag] = vc_env(x, nfft)
%VC_ENV  Spectral envelope by cepstral liftering (base MATLAB only).
%
%   [ENV, MAG] = VC_ENV(X, NFFT) returns the smooth spectral envelope of X and
%   the plain magnitude spectrum.  Both are one-sided real spectra of length
%   NFFT/2+1 and are meant for *relative* shaping only (ENV is scaled by the
%   same 1/NFFT factor as MAG).
%
%   Liftering keeps the low-quefrency part of the real cepstrum, i.e. the
%   vocal-tract (formant) structure, and discards the pitch harmonics - which
%   is exactly the component a formant scaling factor must act on.

x = x(:);
n = numel(x);
if nargin < 2 || isempty(nfft)
    nfft = 2 ^ nextpow2(min(n, 8192));
end
nfft = max(16, 2 * round(nfft / 2));

if n < nfft
    x = [x; zeros(nfft - n, 1)];
elseif n > 4 * nfft                       % average long signals: cheaper + steadier
    blk = floor(n / nfft);
    blk = min(blk, 64);                   % bounded cost, statistics stay identical
    x = reshape(x(1:blk * nfft), nfft, blk);
    x = mean(abs(fft(x, nfft, 1)), 2);    % mean magnitude spectrum
    mag = x;
    nfft_half = nfft / 2 + 1;
    logmag = log(max(x, 1e-12));
    sym = [logmag; logmag(nfft_half - 1:-1:2)];   % rebuild conjugate symmetry
    c = real(ifft(sym));
    L = max(2, min(40, round(0.0025 * nfft)));    % ~2.5 ms of quefrency
    keep = [1:L+1, nfft-L+1:nfft].';
    env = real(fft(c(keep), nfft));
    env = exp(env(1:nfft_half));
    return
end

X = fft(x, nfft);
mag = abs(X(1:nfft / 2 + 1));
logmag = log(max(mag, 1e-12));
sym = [logmag; logmag(nfft / 2:-1:2)];
c = real(ifft(sym));

L = max(2, min(40, round(0.0025 * nfft)));        % quefrency cutoff
keep = [1:L+1, nfft-L+1:nfft].';
ce = zeros(nfft, 1);
ce(keep) = c(keep);
env = real(fft(ce));
env = exp(env(1:nfft / 2 + 1));
end

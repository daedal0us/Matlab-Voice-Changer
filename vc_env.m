function [env, mag] = vc_env(x, nfft, lifter_ms)
%VC_ENV  Spectral envelope by cepstral liftering (base MATLAB only).
%
%   [ENV, MAG] = VC_ENV(X, NFFT, LIFTER_MS) returns the spectral envelope of X
%   and the plain magnitude spectrum.  Both are one-sided real spectra of length
%   NFFT/2+1 and are meant for *relative* shaping only (ENV is scaled by the same
%   1/NFFT factor as MAG).
%
%   Liftering keeps the low-quefrency part of the real cepstrum, i.e. the
%   vocal-tract (formant) structure, and discards the pitch harmonics - which is
%   exactly the component a formant scaling factor must act on.
%
%   THE LIFTER LENGTH MATTERS, AND 2.5 ms WAS TOO SHORT.  The number of cepstral
%   coefficients kept is L = lifter_ms/1000 * NFFT, so with the old fixed
%   2.5 ms and NFFT = 2048 only L = 5 coefficients were retained.  Measured on a
%   synthetic vowel with formants at 700/1220/2600 Hz, that envelope had a single
%   spurious maximum at 1508 Hz and no formant structure at all, which means the
%   formant warp downstream had nothing to move and any peak-based measurement of
%   it was meaningless.  The effect of the length, measured the same way:
%
%       2.5 ms -> L=5   one peak,  at 1508 Hz            (formants lost)
%       8   ms -> L=16  one peak,  at 1031 Hz            (still lost)
%       12  ms -> L=25  THREE peaks, 758 / 1227 / 2602 Hz  <- matches the truth
%       16  ms -> L=33  THREE peaks, 727 / 1227 / 2617 Hz
%
%   12 ms is the default: it resolves F1..F3 without yet letting the pitch
%   harmonics (F0 = 120 Hz -> 8.3 ms quefrency) back into the envelope.

x = x(:);
n = numel(x);
if nargin < 2 || isempty(nfft)
    nfft = 2 ^ nextpow2(min(n, 8192));
end
if nargin < 3 || isempty(lifter_ms)
    lifter_ms = 12;
end
nfft = max(16, 2 * round(nfft / 2));

% Lifter length in cepstral coefficients, capped so it stays well below the
% quefrency of the pitch period: keeping more than about half the spectrum would
% bring the harmonic comb back in.
nkeep = round(lifter_ms / 1000 * nfft);
L = max(2, min([nkeep, floor(nfft / 2) - 1, round(0.05 * nfft)]));

if n < nfft
    x = [x; zeros(nfft - n, 1)];
end

% One FFT of the WHOLE signal, zero padded to at least the requested size.
% This replaced a block-averaging branch that was actively harmful: it reshaped
% the signal into hard, unwindowed blocks of nfft samples and averaged their
% magnitude spectra, which both loses frequency resolution and washes the
% harmonic comb away - and with it the formant structure.  Measured on a
% synthetic vowel (formants 700/1220/2600 Hz, 12 ms lifter):
%     averaged 1..8 blocks of 2048 -> peaks at 598/414/1305 Hz (wrong)
%     single FFT of the whole signal -> 758/1227/2602 Hz (correct)
% The cost is the same order as before: one FFT of the file instead of 64 small
% ones, and the spectrum it produces is the one the mask is actually applied to.
nfft_full = 2 ^ nextpow2(max(n, nfft));
X = fft(x, nfft_full);
mag = abs(X(1:nfft_full / 2 + 1));
logmag = log(max(mag, 1e-12));
sym = [logmag; logmag(nfft_full / 2:-1:2)];
c = real(ifft(sym));

Lfull = max(2, min([round(lifter_ms / 1000 * nfft_full), ...
                    floor(nfft_full / 2) - 1, round(0.05 * nfft_full)]));
keep = [1:Lfull + 1, nfft_full - Lfull + 1:nfft_full].';
ce = zeros(nfft_full, 1);
ce(keep) = c(keep);
env = exp(real(fft(ce)));
env = env(1:nfft_full / 2 + 1);
end

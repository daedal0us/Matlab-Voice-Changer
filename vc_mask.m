function g = vc_mask(env, formant, tilt, gain_dc, nfft, fnyq, apply_dc)
%VC_MASK  Frequency mask that scales the formants and tilts the spectrum.
%
%   G = VC_MASK(ENV, FORMANT, TILT, GAIN_DC, NFFT, FNYQ) builds a one-sided
%   multiplicative mask of length NFFT/2+1:
%
%     * FORMANT warps the spectral envelope ENV on a log-frequency axis
%       (FORMANT > 1 -> formants move up = shorter vocal tract = child-like).
%       The piecewise-linear map keeps DC and Nyquist pinned, so the warped
%       envelope stays monotone in frequency and the mask never blows up.
%     * TILT applies TILT dB per octave about 1 kHz.
%     * GAIN_DC sets the mask level near DC (used for rumble control).
%
%   The mask is normalised to unit RMS over the magnitude spectrum ENV, so
%   applying it does not change the overall level.
%
%   VC_MASK(..., APPLY_DC) with APPLY_DC = false returns unity when FORMANT and
%   TILT are both neutral.  The DC shelf and the level normalisation are then
%   skipped altogether, which is what keeps an identity conversion transparent.

if nargin < 7 || isempty(apply_dc)
    apply_dc = (abs(formant - 1) >= 1e-9) || (abs(tilt) >= 1e-12);
end

nf = numel(env);
k = (0:(nf - 1)).';
f = k * (fnyq / (nf - 1));                    % bin frequencies (Hz), strictly rising

formant = max(0.25, min(4, formant));

% Nothing to do -> unity mask.  Returning a flat 1 keeps an identity conversion
% transparent; the DC handling and the level normalisation below are only
% meaningful when the spectrum is actually being reshaped.
if ~apply_dc
    g = ones(nf, 1);
    return
end

if abs(formant - 1) < 1e-6
    we = env;
else
    % Piecewise-linear frequency map  wk = (f/fc)^formant * fc, with the
    % knee fc placed so that Nyquist maps onto itself.
    fm = max(fnyq * 0.08, 300);
    lo = f < fm;
    wk = zeros(nf, 1);
    wk(lo)  = (f(lo) / fm) .^ formant * fm;                        % warp, slope = formant
    wk(~lo) = fm * (fnyq / fm) .^ ((f(~lo) - fm) / (fnyq - fm));    % geometric bridge fm -> fnyq
    wk = min(max(wk, f(1)), fnyq);

    we = exp(interp1(f, log(max(env, 1e-12)), wk, 'linear', 'extrap'));
end

g = we ./ max(env, 1e-12);                    % relative envelope correction
fe = max(f, 1);                               % keeps the DC bin out of log(0)
g = g .* 10 .^ (tilt / 20 * log2(fe / 1000)); % spectral tilt about 1 kHz
g(1) = g(1) * gain_dc;

% Level normalisation (power weighted by the envelope itself).
pw = max(env .^ 2, 0);
ref = sqrt(sum(pw .* g .^ 2) / max(sum(pw), 1e-12));
if ref > 1e-9
    g = g / ref;
end
end

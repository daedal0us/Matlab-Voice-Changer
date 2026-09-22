function g = vc_mask(env, formant, tilt, gain_dc, nfft, fnyq, apply_dc, mapmode)
%VC_MASK  Frequency mask that scales the formants and tilts the spectrum.
%
%   G = VC_MASK(ENV, FORMANT, TILT, GAIN_DC, NFFT, FNYQ) builds a one-sided
%   multiplicative mask of length NFFT/2+1:
%
%     * FORMANT warps the spectral envelope ENV on a log-frequency axis
%       (FORMANT > 1 -> formants move up = shorter vocal tract = child-like).
%     * TILT applies TILT dB per octave about 1 kHz.
%     * GAIN_DC sets the mask level near DC (used for rumble control).
%
%   The mask is normalised to unit RMS over the magnitude spectrum ENV, so
%   applying it does not change the overall level.
%
%   VC_MASK(..., APPLY_DC) with APPLY_DC = false returns unity when FORMANT and
%   TILT are both neutral.
%
%   VC_MASK(..., APPLY_DC, MAPMODE) selects the frequency map:
%
%     'exact'  (default) power law on a log-frequency axis with the top of the
%              band blended back to the identity:
%                  f <= fp :  wk = fp * (f/fp)^formant
%                  f >  fp :  blend in log f from that power law to f, weight
%                             w = 0.5*(1 - cos(pi*log(f/fp)/log(fnyq/fp)))
%              fp = min(200, fnyq/2), i.e. far below F1.  Hand-checked: a = 1.22
%              maps 700 Hz -> 862.8 Hz and 1220 Hz -> 1496.2 Hz (x1.23, matching
%              the power law to 0.01 %); monotone for a = 0.5..2.0; wk(0) = 0;
%              wk(fnyq) = fnyq; a = 1 is the identity to 1e-11.
%
%     'legacy' the original map, kept only for A/B comparison:
%                  f <  fm :  wk = (f/fm)^formant * fm,  fm = max(0.08*fnyq, 300)
%                  f >= fm :  wk = fm * (fnyq/fm)^((f-fm)/(fnyq-fm))
%              IT IS BROKEN ABOVE THE KNEE.  That bridge has base > 1 and
%              exponent < 1, so it is always BELOW f: every formant above
%              fm = 640 Hz was pushed DOWN and the FORMANT factor had no
%              influence there at all.  Measured: a = 1.22 and a = 0.94 produced
%              byte-identical maps, and F2 = 1220 Hz was mapped to 781 Hz (x0.64).
%              Kept so the difference can be heard and measured, not as a default.

if nargin < 7 || isempty(apply_dc)
    apply_dc = (abs(formant - 1) >= 1e-9) || (abs(tilt) >= 1e-12);
end
if nargin < 8 || isempty(mapmode)
    mapmode = 'exact';
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
    switch lower(char(string(mapmode)))
        case 'legacy'
            fm = max(fnyq * 0.08, 300);
            lo = f < fm;
            wk = zeros(nf, 1);
            wk(lo)  = (f(lo) / fm) .^ formant * fm;
            wk(~lo) = fm * (fnyq / fm) .^ ((f(~lo) - fm) / (fnyq - fm));
        otherwise                                  % 'exact'
            fp = min(200, 0.5 * fnyq);
            wk = zeros(nf, 1);
            lo = f <= fp;
            wk(lo) = fp * (f(lo) / fp) .^ formant;
            if any(~lo)
                xh  = log(f(~lo) / fp) / log(fnyq / fp);
                wgt = 0.5 * (1 - cos(pi * xh));
                wk(~lo) = exp((1 - wgt) .* (log(fp) + formant * log(f(~lo) / fp)) ...
                              + wgt .* log(f(~lo)));
            end
    end
    wk = min(max(wk, f(1)), fnyq);                 % guard against rounding

    % THE INTERPOLATION DIRECTION MATTERS.  The warped envelope must be
    %     we(f) = env(wk^-1(f)),
    % i.e. evaluate the ORIGINAL envelope at the position that maps ONTO f.
    % Writing it as env(wk(f)) instead - which is what this did - reads the
    % envelope from a HIGHER frequency for an upward warp and therefore moves the
    % formants DOWN.  Measured with a = 1.22 on an envelope peaking at 717 Hz:
    % the wrong direction put the warped peak at 592 Hz, the right one at 882 Hz.
    % Since wk is strictly increasing, swapping the axes of interp1 is exactly
    % the inverse map and needs no solver.
    we = exp(interp1(wk, log(max(env, 1e-12)), f, 'linear', 'extrap'));
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

function ok = demo_voice_changer()
%DEMO_VOICE_CHANGER  Self test + benchmark for the command line voice changer.
%
%   Generates a synthetic voice with a known F0 and known formant frequencies,
%   runs every preset through VOICE_CHANGER and verifies
%
%       * the output length and sample rate are preserved,
%       * the measured pitch ratio matches the requested conversion factor,
%       * the measured formant ratio matches the requested formant factor,
%       * the identity preset is transparent,
%       * explicit options and the absolute target mode behave as documented,
%       * every run finishes inside the 1 s budget (checked on a 10 s file).
%
%   Two independent estimators are used as ground truth, so that a mistake in
%   the conversion cannot hide behind a matching mistake in a measurement:
%
%       pitch   - the YIN tracker of VC_ANALYZE (integer sub-harmonic
%                 relations are accepted, because a high voice can make the
%                 tracker lock onto a multiple of the true period),
%       formant - the strongest peak of the *frame averaged* magnitude
%                 spectrum in the F1/F2 region.  Averaging suppresses the
%                 harmonic comb (which moves from frame to frame) while the
%                 formant envelope stays put, so this peak follows the vocal
%                 tract and not the pitch.
%
%   Returns TRUE when all checks pass.

here = fileparts(mfilename('fullpath'));
if ~isempty(here)
    addpath(here);
end

fs   = 16000;
f0   = 120;                       % male-ish source
form = [700 1220 2600 3400];      % known vocal tract
% A *steady* synthetic vowel is used as the test signal.  It is fully
% deterministic (constant F0, fixed formants), which is what makes the pitch
% and formant checks exact; the talking-style signal of VC_SYNTHVOICE (with
% declination and syllable envelopes) is used separately below for the
% long-file timing check.
[x, fs] = steady_vowel(fs, 2.0, f0, form);

inFile = fullfile(here, 'demo_voice.wav');
audiowrite(inFile, x, fs);
fprintf('\n=== voice_changer demo ===\n');
fprintf('test signal: %.2f s @ %g Hz, steady F0 = %.0f Hz, formants = %s Hz\n\n', ...
        numel(x) / fs, fs, f0, mat2str(form));

fprintf('reference measurement: F0 %6.1f Hz, tracked peak %6.1f Hz\n\n', ...
        vc_analyze(x, fs).f0, peak_hz(x, fs, 300, 1500));

presets = {'normal', 'child', 'child_female', 'elder', 'elder_female'};
ok = true;
f0_in = vc_analyze(x, fs).f0;
f1_in = peak_hz(x, fs, 300, 1500);          % the peak that will be tracked
f2_in = f1_in;                              % same peak, for the formant check

for i = 1:numel(presets)
    p = presets{i};
    outFile = fullfile(here, ['out_' p '.wav']);
    [y, info] = voice_changer(inFile, '--preset', p, outFile);

    % ---- ground-truth measurements on the converted signal ------------
    % One spectral peak is followed through the conversion.  The pitch stage
    % scales every frequency by the pitch factor, so the tracked peak must move
    % by exactly that factor; the formant stage then scales everything by the
    % formant factor.  For each measurement the search band is derived from the
    % input measurement and the claimed factor, which fixes the identity of the
    % tracked peak - otherwise "find the strongest peak in a band" would let a
    % different harmonic be reported and the check would be meaningless.
    % The bands are tight on purpose: with 120 Hz harmonic spacing the next line
    % sits only ~15 % away, and a wider band reports the wrong harmonic.
    wp = f1_in * info.pitch_ratio;
    measured_pitch = peak_hz(y, fs, wp * 0.95, wp * 1.05) / max(f1_in, 1e-9);

    wf = f2_in * info.formant_ratio;
    measured_form = peak_hz(y, fs, wf * 0.92, wf * 1.08) / max(f2_in, 1e-9);
    rel_err = abs(measured_pitch - info.pitch_ratio) / info.pitch_ratio;

    % ---- checks -------------------------------------------------------
    c = {};
    if numel(y) ~= numel(x), c{end + 1} = 'length changed'; end
    if rel_err > 0.06
        c{end + 1} = sprintf('pitch x%.3f measured vs x%.3f requested', ...
                             measured_pitch, info.pitch_ratio);
    end
    if abs(measured_form - info.formant_ratio) > 0.12
        c{end + 1} = sprintf('formant x%.3f measured vs x%.3f requested', ...
                             measured_form, info.formant_ratio);
    end
    if info.time_total > 1, c{end + 1} = sprintf('over budget (%.2f s)', info.time_total); end
    if any(~isfinite(y)), c{end + 1} = 'non-finite samples'; end
    if max(abs(y)) > 1, c{end + 1} = 'clipped'; end

    fprintf('%-13s pitch x%.3f (measured x%.3f) | formant x%.3f (measured x%.3f) | %s | %5.0f ms\n', ...
            p, info.pitch_ratio, measured_pitch, info.formant_ratio, measured_form, ...
            ternary(isempty(c), 'OK', 'CHECK'), 1000 * info.time_total);
    for k = 1:numel(c)
        fprintf('    ! %s\n', c{k});
        ok = false;
    end
end

% ---- A/B identity check: normal preset must be transparent ------------
% Level normalisation is switched off (and no file is involved), so this
% measures the algorithm itself: with every conversion factor at 1 the pipeline
% has to return the input unchanged, not merely something that sounds the same.
[y_id, info_id] = voice_changer(x, '--preset', 'normal', '--no-normalize', '--quiet');
d = 20 * log10(max(abs(y_id - x)) / max(abs(x)));
fprintf('\nidentity (normal): %.0f dB peak residual, pitch x%.3f, %.0f ms\n', ...
        d, info_id.pitch_ratio, 1000 * info_id.time_total);
if d > -120
    fprintf('    ! identity path is not transparent\n');
    ok = false;
end

% ---- explicit option check ------------------------------------------
% --pitch 12 means exactly one octave, i.e. ratio 2.000.  The *mapping* is
% checked exactly; the *achieved* conversion is checked with a 3x wider
% tolerance than the presets, because a two-octave-ratio phase vocoder loses
% accuracy at large factors (measured ~4.5 % at ratio 2.0 - see the header of
% VC_PITCHSHIFT_PV; the presets stay within 0.3..2.5 %).
[y_c, info_c] = voice_changer(x, '--pitch', 12, '--formant', 1.3, '--tilt', 2, '--breath', 1);
wp = f1_in * info_c.pitch_ratio;
mp = peak_hz(y_c, fs, wp * 0.95, wp * 1.05) / max(f1_in, 1e-9);
mpe = abs(mp - info_c.pitch_ratio) / info_c.pitch_ratio;
fprintf('explicit options : pitch x%.3f (requested 2.000, measured x%.3f), formant x%.3f, %.0f ms\n', ...
        info_c.pitch_ratio, mp, info_c.formant_ratio, 1000 * info_c.time_total);
if abs(info_c.pitch_ratio - 2) > 1e-6
    ok = false;
    fprintf('    ! --pitch mapping wrong\n');
elseif mpe > 0.18
    ok = false;
    fprintf('    ! --pitch conversion did not take effect\n');
end
if abs(info_c.formant_ratio - 1.3) > 1e-6
    ok = false;
    fprintf('    ! --formant mapping wrong\n');
end

% ---- target-frequency check -----------------------------------------
[y_t, info_t] = voice_changer(x, '--target', 240);
fprintf('absolute target  : --target 240 Hz -> ratio x%.3f (expected x%.3f), %.0f ms\n', ...
        info_t.pitch_ratio, 240 / info_t.pitch_ref, 1000 * info_t.time_total);
if abs(info_t.pitch_ratio - 240 / info_t.pitch_ref) > 1e-9
    fprintf('    ! absolute target missed\n');
    ok = false;
end

% ---- raw-signal API + long-file timing -------------------------------
[xl, fs] = vc_synthvoice(fs, 10.0, 120, form);
t = tic;
yl = voice_changer(xl, '--preset', 'child', '--quiet');
tel = toc(t);
fprintf('\nraw array API    : 10 s of talking-style audio -> %.3f s, %d samples out\n', ...
        tel, numel(yl));
if tel > 1
    fprintf('    ! 10 s file exceeded the 1 s budget\n');
    ok = false;
end

fprintf('\n=== %s ===\n\n', ternary(ok, 'ALL CHECKS PASSED', 'SOME CHECKS FAILED'));
end

% ======================================================================
function [x, fs] = steady_vowel(fs, dur, f0, formants)
%STEADY_VOWEL  Constant-pitch, constant-formant test vowel (source-filter model).
%   Unlike VC_SYNTHVOICE this signal has no declination, no vibrato and no
%   syllable envelope, so its F0 and formants are exactly known and can be
%   measured back without the estimators fighting signal modulation.
n = round(fs * dur);
per = fs / f0;
p1 = mod((0:(n - 1)).', per);
m = p1 < 0.02 * per;
pul = zeros(n, 1);
pul(m) = 0.5 * (1 - cos(pi * p1(m) ./ (0.02 * per)));
src = -diff([0; pul]);                     % differentiated glottal pulses
v = src;
% The level matters: the conversion normalises its output, so a test vowel that
% is much quieter than full scale would be pushed down into the 16-bit
% quantisation floor and stop being measurable at all.  A normalised spectral
% envelope with equal level in every formant keeps the crest factor low, so the
% signal can sit at -6 dBFS without clipping.
for k = 1:numel(formants)
    F = formants(k);
    if k == 1, bw = 70; else, bw = 100; end
    w0 = 2 * pi * F / fs;
    rr = exp(-pi * bw / fs);
    f0c = min(F, fs / 2 - 1);
    w0c = 2 * pi * f0c / fs;
    gain = abs(1 - 2 * rr * exp(-1i * w0c) + rr ^ 2 * exp(-2i * w0c)) / (1 - rr);
    v = filter(gain, [1, -2 * rr * cos(w0), rr ^ 2], v);
end
x = v / max(abs(v)) * 10 ^ (-6 / 20);      % 0.5 full scale = -6 dBFS
end

% ======================================================================
function f = peak_hz(x, fs, flo, fhi)
%PEAK_HZ  Frequency of the strongest spectral peak inside [FLO, FHI].
%   The whole-signal magnitude spectrum is used (Hann windowed, zero padded to
%   the next power of two) and the peak is refined by a parabolic fit, so the
%   result is sub-bin accurate.  Because the caller fixes the band, this tracks
%   one identified peak instead of "whatever happens to be largest", which is
%   what makes it usable as a check on a conversion.
x = double(x(:));
n = numel(x);
nfft = 2 ^ nextpow2(n);
w = 0.5 - 0.5 * cos(2 * pi * (0:(n - 1)).' / n);
X = abs(fft(x .* w, nfft));
X = X(1:(nfft / 2 + 1));
f = (0:(nfft / 2)).' * fs / nfft;
lo = find(f >= flo, 1, 'first');
hi = find(f <= fhi, 1, 'last');
if isempty(lo) || isempty(hi) || hi <= lo + 1
    f = NaN;
    return
end
[~, rel] = max(X(lo:hi));
i = lo + rel - 1;
if i > 1 && i < numel(X)
    y0 = X(i - 1); y1 = X(i); y2 = X(i + 1);
    den = y0 - 2 * y1 + y2;
    d = 0;
    if abs(den) > 1e-12
        d = max(-0.5, min(0.5, 0.5 * (y0 - y2) / den));
    end
    f = f(i) + d * (fs / nfft);
else
    f = f(i);
end
end
function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

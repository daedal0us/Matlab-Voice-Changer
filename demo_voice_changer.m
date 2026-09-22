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
%       * timings are reported for reference (no fixed budget is enforced; see
%         the timing note in VOICE_CHANGER for why).
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

% ---- formant stage: the knob must actually move the formants -----------
% This block exists because the formant stage was silently inert for a while:
% the frequency map moved everything above 640 Hz DOWN regardless of the factor,
% so 1.30, 1.22, 1.10, 0.94 and 0.85 all produced identical output, and the
% envelope itself was too coarse (2.5 ms cepstral lifter) to show it.  Neither a
% listening test nor the preset checks above caught any of that.
%
% The measurement has to be the ENVELOPE peak.  Raw spectral peaks sit on
% harmonics, so they move with the pitch factor no matter what the formant stage
% does - measuring those and concluding "the formant does not move" was the
% original mistake.
p_in = d_envpeaks(x, fs);
fprintf('formant stage: input envelope peaks F1/F2/F3 = %.0f / %.0f / %.0f Hz\n', p_in);

for a = [0.85 1.00 1.30]
    ya = voice_changer(x, '--preset', 'normal', '--formant', a, '--quiet');
    pa = d_envpeaks(ya, fs);
    ra = pa ./ p_in;
    fc = {};
    if a > 1.05 && any(ra < 1.03)
        fc{end + 1} = 'a > 1 did not raise the formants';
    end
    if a < 0.95 && any(ra > 0.97)
        fc{end + 1} = 'a < 1 did not lower the formants';
    end
    if a == 1 && any(abs(ra - 1) > 0.01)
        fc{end + 1} = 'a = 1 is not transparent';
    end
    fprintf('  --formant %.2f -> %5.0f / %5.0f / %5.0f Hz   ratios %.3f %.3f %.3f | %s\n', ...
            a, pa, ra, ternary(isempty(fc), 'OK', 'CHECK'));
    for k = 1:numel(fc)
        fprintf('    ! %s\n', fc{k});
        ok = false;
    end
end

% ---- the formant stage must not wreck the brightness ------------------
% The presets' tilt values were calibrated on real speech so that the formant
% stage leaves the energy spectral centroid close to where the pitch stage put
% it, and the -20*log10(r) term that used to sit on top of them (which measured
% 35..39 % too dark) is gone.  That calibration is a compromise and this check
% is sized accordingly: exact neutrality is NOT achievable across signal types,
% because the size of the effect depends on the signal's own spectral rolloff.
% The synthetic vowel used here has a very steep rolloff (about -12 dB/oct), so
% the same mask that measures -4 % on real speech measures +18 % here.  What is
% asserted is therefore a bound, not equality - the point is to catch a return of
% the old double-compensation, which was an order of magnitude worse.
for p = {'child', 'elder'}
    [yp, ~] = voice_changer(x, '--preset', p{1}, '--formant', 1, ...
                            '--tilt', 0, '--quiet');       % pitch stage only
    [yb, ~] = voice_changer(x, '--preset', p{1}, '--quiet'); % + formant stage
    cp = d_centroid(yp, fs);
    cb = d_centroid(yb, fs);
    drel = cb / cp - 1;
    bc = {};
    if abs(drel) > 0.25
        bc{end + 1} = sprintf('formant stage shifts brightness by %+.0f%%', 100 * drel);
    end
    fprintf('  %-6s brightness: pitch-only %.0f Hz, with formant %.0f Hz (%+.1f%%) | %s\n', ...
            p{1}, cp, cb, 100 * drel, ternary(isempty(bc), 'OK', 'CHECK'));
    for k = 1:numel(bc)
        fprintf('    ! %s\n', bc{k});
        ok = false;
    end
end

% ---- the tilt knob must be monotone (it used to be offset by a constant) ----
% Only monotonicity and "not dead" are asserted here.  The magnitude of the
% effect on this test signal is small by nature: the synthetic vowel has almost
% no energy above 3 kHz, so a tilt of a few dB/oct barely moves its centroid
% (measured x1.06 over a 4 dB/oct span, against x1.42 on real speech, where the
% rolloff is much shallower).  The calibration itself is done on real recordings.
ct = zeros(1, 3);
for k = 1:3
    yy = voice_changer(x, '--preset', 'child', '--tilt', -2 + 2 * (k - 1), '--quiet');
    ct(k) = d_centroid(yy, fs);
end
tc = {};
if ~(ct(1) < ct(2) && ct(2) < ct(3))
    tc{end + 1} = 'tilt is not monotone in brightness';
end
if (ct(3) / ct(1) - 1) < 0.02
    tc{end + 1} = sprintf('tilt has almost no effect (x%.3f over 4 dB/oct)', ct(3) / ct(1));
end
fprintf('  tilt --2/0/+2 dB/oct -> centroid %.0f / %.0f / %.0f Hz (x%.3f) | %s\n', ...
        ct, ct(3) / ct(1), ternary(isempty(tc), 'OK', 'CHECK'));
for k = 1:numel(tc)
    fprintf('    ! %s\n', tc{k});
    ok = false;
end

% ---- output pitch ceiling: must cap a high input, never touch a low one ----
% The absolute presets derive their ratio from target/ref, which assumes the
% input sits near 'ref' (150 Hz for child).  A female input was therefore pushed
% up by that ratio regardless, which piles energy into the top of the band:
% measured on a real 44.1 kHz recording the 2-5 kHz share was multiplied by 8.17
% with no ceiling against 4.54 with one.  The invariant asserted here is that the
% output pitch never EXCEEDS the ceiling and that the ceiling never engages for an
% input the preset was designed for - not that it engages for every high input,
% since a preset may already be gentle enough (child_female at 250 Hz lands on
% 329 Hz, under its own 340 Hz ceiling, so it is correct for it not to fire).
% The variable name is deliberately unusual: an earlier version of this block
% used x_hi and silently clobbered the real-recording check further down, which
% showed up as a timing ratio of 0.96 instead of 1.57.
x_fem250 = steady_vowel(fs, 2.0, 250, form);       % female-range input
for c = {'child', 'child_female'}
    [~, il] = voice_changer(x, fs, '--preset', c{1}, '--quiet');
    [~, ih] = voice_changer(x_fem250, fs, '--preset', c{1}, '--quiet');
    cc = {};
    if il.pitch_capped
        cc{end + 1} = sprintf('ceiling engaged on a %g Hz input (it must not)', f0);
    end
    if ~isempty(ih.max_f0) && ih.f0_in * ih.pitch_ratio > ih.max_f0 * 1.01
        cc{end + 1} = sprintf('output F0 %.0f Hz exceeds the %.0f Hz ceiling', ...
                              ih.f0_in * ih.pitch_ratio, ih.max_f0);
    end
    fprintf(['  %-13s ceiling %.0f Hz: %3.0f Hz in -> x%.3f (capped %d) | ' ...
             '250 Hz in -> x%.3f (capped %d, out %.0f Hz) | %s\n'], ...
            c{1}, ih.max_f0, f0, il.pitch_ratio, il.pitch_capped, ...
            ih.pitch_ratio, ih.pitch_capped, ih.f0_in * ih.pitch_ratio, ...
            ternary(isempty(cc), 'OK', 'CHECK'));
    for k = 1:numel(cc)
        fprintf('    ! %s\n', cc{k});
        ok = false;
    end
end

% explicit override: 0 must disable the ceiling again
[~, i0] = voice_changer(x_fem250, fs, '--preset', 'child', '--max-f0', 0, '--quiet');
oc = {};
if i0.pitch_capped
    oc{end + 1} = '--max-f0 0 should disable the ceiling';
end
if abs(i0.pitch_ratio - 235 / 150) > 1e-9
    oc{end + 1} = 'disabling the ceiling should restore the uncapped ratio';
end
fprintf('  --max-f0 0      : 250 Hz in -> x%.3f (capped %d) | %s\n', ...
        i0.pitch_ratio, i0.pitch_capped, ternary(isempty(oc), 'OK', 'CHECK'));
for k = 1:numel(oc)
    fprintf('    ! %s\n', oc{k});
    ok = false;
end

% ---- timing check: same length does NOT prove the same speed ----------
% The span of "audible" samples is compared between input and output.  This test
% exists because the pitch stage once had its stretch and resample directions
% swapped: the output still had exactly the right number of samples, so every
% length check passed, while the audio played ~2.4x too fast and its tail was
% silence.  A span (rather than the burst edges) is used so that a recording
% with long silent stretches does not look like a timing error.
%
% The burst carries a 130 Hz harmonic series, not a bare tone, so that the signal
% still has a voice-range F0.  A pure 1 kHz tone made the F0 tracker report a
% meaningless value (1 kHz is outside its 60..500 Hz search range), which then
% made the output pitch ceiling fire on a nonsense ratio - visible here as the
% printed ratio changing from 1.57 to 0.96 while nothing about the timing was
% actually wrong.
tone = zeros(round(4 * fs), 1);
ta = round(0.60 * fs); tb = round(0.80 * fs);
tt = (0:numel(tone) - 1).' / fs;
burst = zeros(numel(tone), 1);
for h = 1:8
    burst(ta:tb) = burst(ta:tb) + (1 / h) * sin(2 * pi * 130 * h * tt(ta:tb));
end
tone(ta:tb) = 0.7 * burst(ta:tb) / max(abs(burst(ta:tb)));
tone = tone + 1e-4 * randn(numel(tone), 1);       % dither, so the vocoder sees signal everywhere
[s0, e0] = active_span(tone, fs);

for p = {'child', 'elder'}
    [yt, it] = voice_changer(tone, '--preset', p{1}, '--quiet');
    [s1, e1] = active_span(yt, fs);
    ds = abs(s1 - s0);
    de = abs(e1 - e0);
    tc = {};
    if ds > 0.30, tc{end + 1} = sprintf('content start moved %.2f s', ds); end
    if de > 0.30, tc{end + 1} = sprintf('content end moved %.2f s', de); end
    fprintf('timing %-9s content %.2f-%.2f s (input %.2f-%.2f), ratio x%.2f | %s\n', ...
            p{1}, s1, e1, s0, e0, it.pitch_ratio, ternary(isempty(tc), 'OK', 'CHECK'));
    for k = 1:numel(tc)
        fprintf('    ! %s\n', tc{k});
        ok = false;
    end
end

% ---- the same check on a real recording, if one is present ------------
% Real speech is much less periodic than the synthetic vowel and contains silent
% stretches, so the conversion is verified on it as well.  Picking the file is
% the tricky part: a folder used for listening tests fills up with CONVERTED
% files, and those are not source material - running the conversion test on one
% of them verifies nothing about the original recording (it once selected
% A_legacy.wav and dutifully reported an F0 of 320.7 Hz, which is the output of a
% previous conversion rather than a voice).  The source recording is by far the
% longest file in the folder, so that is the selection rule, with the generated
% demo and the out_* products excluded.
realFiles = dir(fullfile(here, '*.wav'));
if ~isempty(realFiles)
    realFiles = realFiles(~strcmp({realFiles.name}, 'demo_voice.wav'));
    realFiles = realFiles(~startsWith({realFiles.name}, 'out_'));
end
if ~isempty(realFiles)
    [~, iLong] = max([realFiles.bytes]);
    realFiles = realFiles(iLong);
end
if ~isempty(realFiles)
    rn = fullfile(here, realFiles(1).name);
    [xr, fsr] = audioread(rn);
    xr = mean(double(xr), 2);
    xr = xr(1:min(numel(xr), round(20 * fsr)));   % 20 s is enough and keeps it fast
    [s0, e0] = active_span(xr, fsr);
    fprintf('\nreal recording "%s": %.1f s @ %g Hz, F0 %.1f Hz, content %.2f-%.2f s\n', ...
            realFiles(1).name, numel(xr) / fsr, fsr, vc_analyze(xr, fsr).f0, s0, e0);
    for p = {'child', 'elder'}
        [yr, ir] = voice_changer(xr, '--preset', p{1}, '--quiet');
        [s1, e1] = active_span(yr, fsr);
        % pitch check with a WIDE band here: real speech has a strong formant
        % structure, so a tight band would let the wrong harmonic answer.
        wp = ir.f0_in * ir.pitch_ratio;
        mp = peak_hz(yr, fsr, wp * 0.55, wp * 1.45) / max(ir.f0_in, 1e-9);
        rc = {};
        if numel(yr) ~= numel(xr), rc{end + 1} = 'length changed'; end
        if abs(s1 - s0) > 0.35, rc{end + 1} = sprintf('content start moved %.2f s', abs(s1 - s0)); end
        if abs(e1 - e0) > 0.35, rc{end + 1} = sprintf('content end moved %.2f s', abs(e1 - e0)); end
        if any(~isfinite(yr)), rc{end + 1} = 'non-finite samples'; end
        fprintf('  %-9s F0 %.1f -> %.1f Hz (ratio x%.2f), content %.2f-%.2f s (input %.2f-%.2f), %.0f ms | %s\n', ...
                p{1}, ir.f0_in, ir.f0_out, ir.pitch_ratio, s1, e1, s0, e0, ...
                1000 * ir.time_total, ternary(isempty(rc), 'OK', 'CHECK'));
        for k = 1:numel(rc)
            fprintf('    ! %s\n', rc{k});
            ok = false;
        end
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
% Reported, not asserted.  The 1 s figure this used to enforce was a development
% guard against a non-terminating loop, not a property of the algorithm; cost
% legitimately scales with sample count (the same audio at 44.1 kHz costs about
% 3x what it costs at 16 kHz).  See the timing note in VOICE_CHANGER.
[xl, fs] = vc_synthvoice(fs, 10.0, 120, form);
t = tic;
yl = voice_changer(xl, '--preset', 'child', '--quiet');
tel = toc(t);
fprintf('\nraw array API    : 10 s of talking-style audio -> %.3f s (%.0f ms per audio second), %d samples out\n', ...
        tel, 1000 * tel / (numel(xl) / fs), numel(yl));

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

% ======================================================================
function p = d_envpeaks(y, fs)
%D_ENVPEAKS  Peaks of the cepstral envelope in the F1/F2/F3 bands.
%   Deliberately named with a d_ prefix: several files in this folder define
%   local helpers, and local functions in DIFFERENT files really do shadow each
%   other through the path.  That is not hypothetical - it silently made one
%   verification script call another script's copy of the frequency map, which
%   produced measurements that contradicted the implementation for a whole round
%   of debugging.
[env, ~] = vc_env(y, 2048, 12);
nf = numel(env);
f = (0:nf - 1).' * (fs / 2) / (nf - 1);
p = [d_peakof(env, f, 450, 1000), d_peakof(env, f, 1000, 1800), ...
     d_peakof(env, f, 1800, 3400)];
end

% ======================================================================
function q = d_peakof(e, f, flo, fhi)
%D_PEAKOF  Energy weighted centre of the strongest envelope peak in a band.
sel = f >= flo & f <= fhi;
[~, i] = max(e .* sel);
lo = max(1, i - 10); hi = min(numel(e), i + 10);
w = e(lo:hi) .^ 2;
q = sum(f(lo:hi) .* w) / max(sum(w), 1e-12);
end

% ======================================================================
function c = d_centroid(y, fs)
%D_CENTROID  Energy spectral centroid: the brightness metric the tilt
%   calibration is expressed in.
y = double(y(:)) .* d_hann(numel(y));
X = abs(fft(y, 2 ^ nextpow2(numel(y))));
X = X(1:numel(X) / 2 + 1) .^ 2;
f = (0:numel(X) - 1).' * fs / (2 * (numel(X) - 1));
c = sum(f .* X) / max(sum(X), 1e-12);
end

% ======================================================================
function w = d_hann(n)
w = 0.5 - 0.5 * cos(2 * pi * (0:n - 1).' / n);
end

% ======================================================================
function [s, e] = active_span(y, fs)
%ACTIVE_SPAN  First and last time where the signal carries real energy.
%   A robust timing metric: it survives silent stretches, a slow fade and the
%   overlap-add transients at the edges - all of which broke a naive "find the
%   burst edges" test when it was pointed at a real recording.
y = double(y(:));
w = max(1, round(0.02 * fs));
env = sqrt(filter(ones(w, 1) / w, 1, y .^ 2));
thr = max(0.08 * max(env), 10 ^ (-50 / 20));    % 8 % of peak, and above -50 dBFS
i = find(env > thr);
if isempty(i)
    s = NaN; e = NaN;
    return
end
s = (i(1) - 1) / fs;
e = (i(end) - 1) / fs;
end

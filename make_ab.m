function make_ab()
%MAKE_AB  Render a listening comparison for the male -> child conversion.
%   Writes AB_*.wav at 16 kHz:
%     A_dry           input, 16 kHz (the reference for A/B)
%     B_child         the default child preset (target 210 Hz, formant x1.15)
%     C_child_bright  the previous default (target 235 Hz, formant x1.22)
%     D_child_light   default child with a smaller formant factor (1.10)
%     E_pv_only       pitch stages only: no formant, no tilt, no normalisation
%     F_child_prev    child with the OLD ratio ceiling 1.400 - i.e. what it did
%                     before the ceilings were rewritten as target/floor
%     G_cf_prev       child_female with the OLD ratio ceiling 1.316
%     H_cf_new        child_female as it now behaves (target 250 Hz)
%
%   F/G/H are the A/B for the ceiling fix: on this 148.5 Hz male recording the old
%   ceilings put child at 207.9 Hz and child_female at 195.5 Hz, which is why
%   "child" sounded higher and thinner than "child_female".  The new ceilings put
%   them at their targets, 210 and 250 Hz.  See the note above the preset switch
%   in VOICE_CHANGER for the rule.
here = fileparts(mfilename('fullpath'));
cd(here);
fs = 16000;
secs = 24;
[xr, fsr] = audioread('测试2.wav');
xr = mean(xr, 2);
x = vc_resample(xr, fsr / fs, min(numel(xr), round(secs * fs)));
x = x / max(abs(x)) * 0.9;
audiowrite('AB_00_A_dry.wav', x, fs);
fprintf('input %.1f s, F0 %.1f Hz\n', numel(x) / fs, vc_analyze(x, fs).f0);

% how loud is the input band above 5.1 kHz, i.e. what can fold back at ratio 1.57
S = abs(fft(x .* hann(numel(x)), 2 ^ 17));
S = S(1:2 ^ 16 + 1);
ff = (0:2 ^ 16).' * fs / 2 ^ 16;
fprintf('input energy above 5100 Hz: %.1f dB below the total\n', ...
        10 * log10(sum(S(ff > 5100) .^ 2) / sum(S(ff > 60) .^ 2)));

R = { ...
    'AB_01_B_child.wav',        @() voice_changer(x, '--preset', 'child', '--quiet'); ...
    'AB_02_C_child_bright.wav', @() voice_changer(x, '--preset', 'child_bright', '--quiet'); ...
    'AB_03_D_child_light.wav',  @() voice_changer(x, '--preset', 'child', '--formant', 1.10, '--quiet'); ...
    'AB_04_E_pv_only.wav',      @() voice_changer(x, '--preset', 'child', '--formant', 1, '--tilt', 0, '--no-normalize', '--quiet'); ...
    'AB_05_F_child_prev.wav',   @() voice_changer(x, '--preset', 'child', '--ratio-max', '1.400', '--quiet'); ...
    'AB_06_G_cf_prev.wav',      @() voice_changer(x, '--preset', 'child_female', '--ratio-max', '1.316', '--quiet'); ...
    'AB_07_H_cf_new.wav',       @() voice_changer(x, '--preset', 'child_female', '--quiet')};
for k = 1:size(R, 1)
    [y, info] = R{k, 2}();
    audiowrite(R{k, 1}, y / max(abs(y)) * 0.9, fs);
    fprintf('%-26s F0 %5.1f -> %5.1f Hz, pitch x%.3f%s, formant x%.3f, %5.0f ms\n', ...
            R{k, 1}, info.f0_in, info.f0_out, info.pitch_ratio, ...
            ternary(info.ratio_capped, ' (old ceiling)', ''), info.formant_ratio, ...
            1000 * info.time_total);
end
fprintf('\nwrote AB_00..AB_07 wav files (16 kHz)\n');
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end

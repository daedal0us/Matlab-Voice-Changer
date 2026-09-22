function make_ab()
%MAKE_AB  Render a listening comparison for the male -> child conversion.
%   Writes A/B_*.wav at 16 kHz:
%     A_dry          input, 16 kHz (the reference for A/B)
%     B_child_now    child as it behaves now (anti-aliased resampler, nfft 1024)
%     C_child_soft   child_soft preset (F0 target 210, formant 1.15)
%     D_child_light  child with a smaller formant factor (1.12), same pitch
%     E_pv_only      pitch stages only: no formant, no tilt, no normalisation
%     F_child_prev   child as it behaved before the resampler fix
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
    'AB_01_B_child_now.wav',   @() voice_changer(x, '--preset', 'child', '--quiet'); ...
    'AB_02_C_child_soft.wav',  @() voice_changer(x, '--preset', 'child_soft', '--quiet'); ...
    'AB_03_D_child_light.wav', @() voice_changer(x, '--preset', 'child', '--formant', 1.12, '--quiet'); ...
    'AB_04_E_pv_only.wav',     @() voice_changer(x, '--preset', 'child', '--formant', 1, '--tilt', 0, '--no-normalize', '--quiet')};
for k = 1:size(R, 1)
    [y, info] = R{k, 2}();
    audiowrite(R{k, 1}, y / max(abs(y)) * 0.9, fs);
    fprintf('%-26s F0 %5.1f -> %5.1f Hz, pitch x%.3f, formant x%.3f, %5.0f ms\n', ...
            R{k, 1}, info.f0_in, info.f0_out, info.pitch_ratio, info.formant_ratio, ...
            1000 * info.time_total);
end

% the same child conversion with the pre-fix resampler (legacy cutoff)
setenv('VC_LEGACY_RESAMPLE', '1');
y = voice_changer(x, '--preset', 'child', '--quiet');
setenv('VC_LEGACY_RESAMPLE', '');
audiowrite('AB_05_F_child_prev.wav', y / max(abs(y)) * 0.9, fs);
fprintf('%-26s written with the old resampler cutoff\n', 'AB_05_F_child_prev.wav');

% what did the user's own render use?
for f = {'male_child.wav', 'male_child_2.wav'}
    fn = f{1};
    if exist(fn, 'file') == 2
        [yu, fu] = audioread(fn);
        yu = mean(yu, 2);
        a = vc_analyze(yu, fu);
        Sp = abs(fft(yu .* hann(numel(yu)), 2 ^ 17));
        Sp = Sp(1:2 ^ 16 + 1);
        fq = (0:2 ^ 16).' * fu / 2 ^ 16;
        b = fq >= 60;
        cen = sum(fq(b) .* Sp(b) .^ 2) / sum(Sp(b) .^ 2);
        fprintf('%-16s %5.2f s @ %5.0f Hz, F0 %6.1f Hz, centroid %5.0f Hz, crest %.1f\n', ...
                fn, numel(yu) / fu, fu, a.f0, cen, ...
                max(abs(yu)) / sqrt(mean(yu .^ 2)));
    end
end
fprintf('\nwrote AB_00..AB_05 wav files (16 kHz)\n');
end

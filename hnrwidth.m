function hnrwidth
%HNRWIDTH  Is the locked/unlocked HNR gap a FREQUENCY-SPREAD effect or real
%   extra noise?
%
%   The HNR used earlier counts only energy within +-25 Hz of k*f0 as harmonic and
%   calls everything else noise.  Real speech moves its F0 around, so with a fixed
%   narrow window a partial that drifts a few percent lands outside and is counted
%   as noise even though it is perfectly good voice.  If the locked output simply
%   spreads its partials a little more (phase smearing), a WIDER window should
%   recover them and the gap between the two versions should close.
%
%   So: measure the same pair with windows from +-10 Hz to +-120 Hz and watch the
%   gap.
%       gap shrinks as the window widens  -> the difference is frequency spread,
%                                            i.e. an artefact of the metric
%       gap persists or grows            -> the locked output really does have
%                                            extra energy, and it has to be found
%
%   Run:  matlab -batch "hnrwidth"

here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
addpath(here);

% ---- regenerate the pair (they are build output, deleted between sessions) ----
src = fullfile(here, '测试2.wav');
fs = 44100;
jobs = { ...
    'E1_elder_nolock.wav', {'--preset', 'elder', '--no-phase-lock'}; ...
    'E2_elder_lock.wav',   {'--preset', 'elder', '--phase-lock'}};
for j = 1:size(jobs, 1)
    out = fullfile(here, jobs{j, 1});
    if ~exist(out, 'file')
        [y, ~] = voice_changer(src, jobs{j, 2}{:}, '--quiet', '--out', out);
        pk = max(abs(y));
        audiowrite(out, y / pk * 0.98, fs);
        fprintf('rendered %s\n', jobs{j, 1});
    end
end

f0 = 144.8;                       % the elder preset's output F0 for this file
widths = [10 25 40 60 90 120];

    function [h, tot, nh] = hnr_at(y, fs, f0, w)
        y = double(y(:)) - mean(y);
        N = 2 ^ nextpow2(numel(y));
        Y = abs(fft(y .* hann_loc(numel(y)), N)) .^ 2;
        fr = (0:N / 2).' * fs / N;
        Y = Y(1:N / 2 + 1);
        tot = sum(Y);
        nh = 0;
        for k = 1:floor(fr(end) / f0)
            fk = k * f0;
            b = fr > fk - w & fr < fk + w;
            nh = nh + sum(Y(b));
        end
        h = 10 * log10(nh / max(tot - nh, eps));
    end

    function [h, tot, nh] = hnr_wide(y, fs, f0, w)
        % Same total-energy convention, but the "noise" part is measured as the
        % energy in the MIDPOINTS between harmonics (a band of the same width
        % centred at (k+0.5)*f0).  This asks "how loud is what sits BETWEEN the
        % partials" directly, instead of inferring it from a subtraction, so it
        % cannot be fooled by partials drifting out of the harmonic window.
        y = double(y(:)) - mean(y);
        N = 2 ^ nextpow2(numel(y));
        Y = abs(fft(y .* hann_loc(numel(y)), N)) .^ 2;
        fr = (0:N / 2).' * fs / N;
        Y = Y(1:N / 2 + 1);
        on = 0;  off = 0;
        for k = 1:floor(fr(end) / f0)
            fk = k * f0;
            on = on + sum(Y(fr > fk - w & fr < fk + w));
            fm = (k - 0.5) * f0;
            if fm > 0
                off = off + sum(Y(fr > fm - w & fr < fm + w));
            end
        end
        tot = sum(Y);  nh = on;
        h = 10 * log10(on / max(off, eps));
    end

fprintf('\n=== E1 (lock OFF) vs E2 (lock ON), elder preset, F0 = %.1f Hz ===\n', f0);
[yU, ~] = audioread(fullfile(here, 'E1_elder_nolock.wav'));
[yL, ~] = audioread(fullfile(here, 'E2_elder_lock.wav'));

fprintf('\n(a) harmonic window of +-W Hz, rest counted as noise:\n');
fprintf('%-8s %14s %14s %10s\n', 'W Hz', 'HNR OFF', 'HNR ON', 'gap (ON-OFF)');
for w = widths
    [hU, tU, nU] = hnr_at(yU, fs, f0, w);
    [hL, tL, nL] = hnr_at(yL, fs, f0, w);
    fprintf('%-8d %11.2f dB %11.2f dB %10.2f\n', w, hU, hL, hL - hU);
end

fprintf('\n(b) total energy carried by the harmonic bands themselves:\n');
fprintf('%-8s %14s %14s %10s\n', 'W Hz', 'share OFF', 'share ON', 'ratio');
for w = widths
    [~, tU, nU] = hnr_at(yU, fs, f0, w);
    [~, tL, nL] = hnr_at(yL, fs, f0, w);
    fprintf('%-8d %13.2f%% %13.2f%% %9.2fx\n', w, 100 * nU / tU, 100 * nL / tL, ...
        (nL / tL) / (nU / tU));
end

fprintf('\n(c) on-harmonic vs BETWEEN-harmonic energy (subtraction-free):\n');
fprintf('%-8s %14s %14s %10s\n', 'W Hz', 'HNR OFF', 'HNR ON', 'gap (ON-OFF)');
for w = widths
    [hU, ~, ~] = hnr_wide(yU, fs, f0, w);
    [hL, ~, ~] = hnr_wide(yL, fs, f0, w);
    fprintf('%-8d %11.2f dB %11.2f dB %10.2f\n', w, hU, hL, hL - hU);
end

fprintf('\nreading: if column 4 in (a) goes to ~0 as W grows, the HNR gap was a\n');
fprintf('         frequency-spread artefact of the fixed window; if it stays or\n');
fprintf('         grows, the locked output really carries more noise.\n\n');
end

function w = hann_loc(n)
k = (0:(n - 1)).';
w = 0.5 - 0.5 * cos(2 * pi * k / n);
end

function formant_verify()
%FORMANT_VERIFY  Does --formant actually move the formants now?
%
%   Measured on the ENVELOPE, which is what the mask warps - not on raw spectral
%   peaks, which always sit on a harmonic and therefore move with the pitch
%   factor instead of the formant factor.  That mistake is what made earlier
%   measurements of this stage meaningless.
%
%   Also checks both maps side by side, because the whole point of exposing
%   --formant-map is that 'legacy' is broken above 640 Hz and 'exact' is not.

cd(fileparts(mfilename('fullpath')));
fs = 16000;
x = steadyvowel(fs, 2.0, 120, [700 1220 2600 3400]);

fprintf('=== envelope peaks of the OUTPUT, vs --formant ===\n');
fprintf('signal: synthetic vowel, true formants 700 / 1220 / 2600 Hz\n\n');
p0 = envpeaks(x, fs);
fprintf('input                     : %6.0f %6.0f %6.0f Hz\n', p0);

for mode = {'legacy', 'exact'}
    fprintf('\n--formant-map %s\n', mode{1});
    for a = [1.30 1.22 1.10 1.00 0.94 0.85]
        y = voice_changer(x, '--preset', 'normal', '--formant', a, ...
                          '--formant-map', mode{1}, '--quiet');
        p = envpeaks(y, fs);
        fprintf('  --formant %.2f -> %6.0f %6.0f %6.0f Hz   ratios %.3f %.3f %.3f\n', ...
                a, p, p ./ p0);
    end
end

fprintf('\n=== the criterion: a > 1 must raise the peaks, a < 1 must lower them ===\n');
ok = true;
for mode = {'legacy', 'exact'}
    m = mode{1};
    hi = envpeaks(voice_changer(x, '--preset', 'normal', '--formant', 1.30, ...
                                '--formant-map', m, '--quiet'), fs);
    lo = envpeaks(voice_changer(x, '--preset', 'normal', '--formant', 0.85, ...
                                '--formant-map', m, '--quiet'), fs);
    up = all(hi >= p0 * 1.02);
    dn = all(lo <= p0 * 0.98);
    fprintf('  %-7s : a=1.30 %s | a=0.85 %s\n', m, ...
            tern(up, 'moves UP  ', 'NO up    '), tern(dn, 'moves DOWN', 'NO down  '));
    if strcmp(m, 'exact') && ~(up && dn)
        fprintf('    !! exact map did not move the formants as promised\n');
        ok = false;
    end
end

fprintf('\n%s\n', tern(ok, '=== FORMANTS NOW RESPOND TO --formant ===', ...
                          '=== FORMANTS STILL DO NOT RESPOND ==='));
end

% ======================================================================
function p = envpeaks(y, fs)
%ENVPEAKS  Peaks of the cepstral envelope in the F1/F2/F3 bands.
[env, ~] = vc_env(y, 2048, 12);
nf = numel(env);
f = (0:nf - 1).' * (fs / 2) / (nf - 1);
p = [pkof(env, f, 450, 1000), pkof(env, f, 1000, 1800), pkof(env, f, 1800, 3400)];
end

function q = pkof(e, f, flo, fhi)
sel = f >= flo & f <= fhi;
[~, i] = max(e .* sel);
lo = max(1, i - 10); hi = min(numel(e), i + 10);
w = e(lo:hi) .^ 2;
q = sum(f(lo:hi) .* w) / max(sum(w), 1e-12);
end

function x = steadyvowel(fs, dur, f0, formants)
n = round(fs * dur); per = fs / f0;
p1 = mod((0:n - 1).', per); m = p1 < 0.02 * per;
pul = zeros(n, 1); pul(m) = 0.5 * (1 - cos(pi * p1(m) ./ (0.02 * per)));
v = -diff([0; pul]);
for k = 1:numel(formants)
    F = formants(k); if k == 1, bw = 70; else, bw = 100; end
    w0 = 2 * pi * F / fs; rr = exp(-pi * bw / fs);
    f0c = min(F, fs / 2 - 1); w0c = 2 * pi * f0c / fs;
    g = abs(1 - 2 * rr * exp(-1i * w0c) + rr ^ 2 * exp(-2i * w0c)) / (1 - rr);
    v = filter(g, [1, -2 * rr * cos(w0), rr ^ 2], v);
end
x = v / max(abs(v)) * 10 ^ (-6 / 20);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

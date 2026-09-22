function fmt_probe()
% FMT_PROBE  Which audio file formats can this thing actually read and write?
%
% The pipeline never opens a file itself: it reads through AUDIOREAD and writes
% through AUDIOWRITE, so the supported set is exactly whatever this MATLAB
% install's codecs accept - but "exactly" is worth measuring rather than
% assuming, both ways round (a format that can be READ is not necessarily one
% that can be WRITTEN - that is the case for MP3).
%
% Part 1 asks AUDIOWRITE to produce each candidate from a known signal, part 2
% reads every file that appeared back with AUDIOREAD, and part 3 runs the real
% entry point on them so that the answer is about VOICE_CHANGER and not about
% AUDIOREAD in isolation.
%
% Run:  fmt_probe
diary fmt_probe.txt
diary on
fprintf('\n############## fmt_probe ##############\n');

fs = 16000;
% A synthetic 150 Hz source with formant-ish spectral shaping.  It is written out
% here rather than borrowed from DEMO_VOICE_CHANGER because STEADY_VOWEL is a
% local function of that file and is not on the path.  This is deterministic and
% voiced, which is all these format checks need.
tt = (0:round(fs * 1.2) - 1)' / fs;
x = zeros(size(tt));
for k = 1:60
    fk = 150 * k;
    if fk > 7000, break; end
    g = 0;
    for F = [700 1220 2600 3400]
        g = g + 1 / (1 + ((fk - F) / 180) ^ 2);
    end
    x = x + (g / k) * sin(2 * pi * fk * tt);
end
x = x .* (0.6 + 0.4 * sin(2 * pi * 2.5 * tt));
x = x(round(0.05 * fs):end - round(0.05 * fs));      % drop the fade-in
x = x / max(abs(x)) * 0.5;

exts = {'.wav', '.flac', '.ogg', '.opus', '.m4a', '.mp4', '.mp3', '.aiff', ...
        '.aif', '.au', '.w64', '.caf', '.webm', '.mkv', '.avi', '.mov'};
fprintf('\n--- part 1: audiowrite ---\n');
fprintf('%-7s %-34s %s\n', 'ext', 'audiowrite', 'note');
made = {};
for k = 1:numel(exts)
    fn = ['FMT_test' exts{k}];
    if exist(fn, 'file') == 2, delete(fn); end
    note = '';
    try
        audiowrite(fn, x, fs);
        if exist(fn, 'file') == 2
            made{end + 1} = fn; %#ok<AGROW>
            stat = 'OK';
            note = sprintf('%d bytes', dir(fn).bytes);
        else
            stat = 'no file';
        end
    catch err
        stat = 'error';
        note = shorten(err.message);
    end
    fprintf('%-7s %-34s %s\n', exts{k}, stat, note);
end

fprintf('\n--- part 2: audioread ---\n');
fprintf('%-7s %-8s %-28s %s\n', 'ext', 'audioread', 'info', 'note');
for k = 1:numel(made)
    fn = made{k};
    [~, ~, e] = fileparts(fn);
    try
        [y, fr] = audioread(fn);
        % AUDIOINFO does not carry BitsPerSample for the compressed formats, so
        % reading it unguarded made OGG/OPUS/MP3 look like they failed to read
        % when they had read fine.  Only report the fields that exist.
        i = audioinfo(fn);
        bits = '';
        if isfield(i, 'BitsPerSample') && ~isempty(i.BitsPerSample)
            bits = sprintf(', %d bits', i.BitsPerSample);
        end
        fprintf('%-7s %-8s %-28s %d ch, %g Hz%s\n', e, 'OK', ...
                sprintf('%.3f s, %g Hz', numel(y) / fr, fr), ...
                i.NumChannels, i.SampleRate, bits);
    catch err
        fprintf('%-7s %-8s %-28s %s\n', e, 'error', '', oneline(err.message));
    end
end

fprintf('\n--- part 3: the full conversion, in and out ---\n');
tin = fullfile(tempdir, 'FMT_in.wav');
audiowrite(tin, x, fs);
fprintf('%-9s %-7s %-9s %s\n', 'out ext', 'write', 'read back', 'pitch ratio (in x1.411 expected)');
for k = 1:numel(exts)
    e = exts{k};
    t = [tempdir 'FMT_out' e];
    if exist(t, 'file') == 2, delete(t); end
    try
        [y, info] = voice_changer(tin, '--preset', 'child', t, '--quiet');
    catch err
        fprintf('%-9s %-7s %-9s %s\n', e, 'error', '', shorten(err.message));
        continue
    end
    ok = exist(t, 'file') == 2;
    back = '-';
    if ok
        try
            [z, fz] = audioread(t);
            back = sprintf('%.3f s, %g Hz', numel(z) / fz, fz);
        catch err
            back = ['read error: ' shorten(err.message)];
            ok = false;
        end
    end
    fprintf('%-9s %-7s %-9s x%.3f%s\n', e, ternary(ok, 'OK', 'no file'), back, ...
            info.pitch_ratio, ternary(ok, '', '  <- not usable'));
end

fprintf('\n--- part 4: name given WITHOUT an extension ---\n');
nm = [tempdir 'FMT_noext'];
if exist([nm '.wav'], 'file') == 2, delete([nm '.wav']); end
[y, info] = voice_changer(tin, '--preset', 'child', nm, '--quiet');
fprintf('asked for "%s" -> wrote "%s" (%d bytes), %d samples\n', nm, info.outfile, ...
        dir(info.outfile).bytes, numel(y));

fprintf('\n--- part 5: stereo downmix on a native 44.1 kHz file ---\n');
% The 44.1 kHz signal is generated AT 44.1 kHz.  An earlier version of this probe
% resampled the 16 kHz signal up with VC_RESAMPLE and read that back, which
% reported 413 Hz for a 150 Hz source; regenerating natively gives 150.0 Hz, so
% that was an artifact of the stretched test signal and not of the sample rate.
% Nothing in the pipeline cares about 44.1 kHz - the child presets are tested on
% real 44.1 kHz recordings elsewhere in this project.
for fr = [44100 48000]
    tt = (0:round(fr * 1.2) - 1)' / fr;
    xs = zeros(size(tt));
    for k = 1:60
        fk = 150 * k;
        if fk > 7000, break; end
        g = 0;
        for F = [700 1220 2600 3400]
            g = g + 1 / (1 + ((fk - F) / 180) ^ 2);
        end
        xs = xs + (g / k) * sin(2 * pi * fk * tt);
    end
    xs = xs .* (0.6 + 0.4 * sin(2 * pi * 2.5 * tt));
    xs = xs(round(0.05 * fr):end - round(0.05 * fr));
    xs = [xs, 0.6 * xs];                       % stereo, second channel quieter
    xs = xs / max(abs(xs(:))) * 0.5;
    fname = fullfile(tempdir, sprintf('FMT_native%d.wav', fr));
    audiowrite(fname, xs, fr);
    [y, info] = voice_changer(fname, '--preset', 'child', '--quiet');
    fprintf('%d Hz stereo in -> mono out %d samples, %g Hz, F0 %.1f -> %.1f Hz, ratio %.3f\n', ...
            fr, numel(y), info.fs, info.f0_in, info.f0_out, info.pitch_ratio);
    delete(fname);
end

fprintf('\n--- part 6: m4a / mp4 failed on the SAMPLE RATE, so try others ---\n');
fprintf('%-7s %-9s %s\n', 'ext', 'fs', 'audiowrite');
for e = {'.m4a', '.mp4'}
    for fr = [16000 22050 32000 44100 48000 96000]
        fn = [tempdir 'FMT_rate' e{1}];
        if exist(fn, 'file') == 2, delete(fn); end
        try
            audiowrite(fn, x, fr);
            st = 'OK';
        catch err
            st = oneline(err.message);
        end
        fprintf('%-7s %-9d %s\n', e{1}, fr, st);
        if exist(fn, 'file') == 2, delete(fn); end
    end
end

fprintf('\n--- cleaning up ---\n');
% Guarded: a missing temporary must not turn a finished run into an error.
for f = [made, arrayfun(@(e) {[tempdir 'FMT_out' e{1}]}, exts), ...
         {tin, fullfile(tempdir, 'FMT_stereo.wav'), [nm '.wav']}]
    try
        if exist(f{1}, 'file') == 2, delete(f{1}); end
    catch
    end
end
fprintf('done\n');
diary off
end

function s = shorten(m)
s = oneline(m);
if numel(s) > 90, s = [s(1:87) '...']; end
end

function s = oneline(m)
% error messages contain newlines, which would break the table layout
m = char(string(m));
m = regexprep(m, '\s+', ' ');
m = strtrim(m);
if numel(m) > 68, m = [m(1:65) '...']; end
s = m;
end

function f0 = f0_ac(x, fs)
% plain autocorrelation over 60..500 Hz, as an independent check on VC_ANALYZE
x = double(x(:));
x = x - mean(x);
n = numel(x);
lo = max(2, floor(fs / 500));
hi = min(n - 2, ceil(fs / 60));
c = zeros(hi + 1, 1);
for L = 0:hi
    a = x(1:n - L);
    b = x(1 + L:n);
    c(L + 1) = sum(a .* b) / sqrt(sum(a .^ 2) * sum(b .^ 2));
end
c(1) = 0;
[~, im] = max(c(lo + 1:hi + 1));
L = lo + im - 1;
if L > lo && L < hi
    y0 = c(L); y1 = c(L + 1); y2 = c(L + 2);
    den = y0 - 2 * y1 + y2;
    if abs(den) > 1e-12
        L = L + max(-0.5, min(0.5, 0.5 * (y0 - y2) / den));
    end
end
f0 = fs / L;
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end

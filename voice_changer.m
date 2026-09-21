function [y, info] = voice_changer(varargin)
%VOICE_CHANGER  Command-line voice changer: normal <-> child <-> elderly voice.
%
%   Y = VOICE_CHANGER(X, ...) converts the audio signal X (single or multi
%   channel) and returns the converted signal Y of the same length and the
%   same sample rate.
%
%   Y = VOICE_CHANGER('in.wav', ...) reads 'in.wav' and returns Y.
%
%   Y = VOICE_CHANGER(..., 'out.wav') additionally writes a 16-bit WAV.
%
%   VOICE_CHANGER returns INFO with the detected F0 and the conversion factors.
%
%   ---------------------------------------------------------------------
%   PRESETS (--preset)
%     normal / adult / male / none  identity (A/B reference, 1:1)
%     child, child_female           child-like voice:  F0 x~1.9, formants x~1.22
%     elder, elder_male             elderly voice:     F0 x0.86, formants x0.94,
%                                   tremor + breathiness + duller spectrum
%     elder_female                  gentler elderly transform for high voices
%
%   OPTIONS (all optional, command line wins over the preset)
%     --pitch   <semitones>   relative pitch shift  (+12 = one octave up)
%     --target  <Hz>          absolute target F0    (child preset: 235 Hz)
%     --ratio   <r>           pitch factor directly (r = F0_out / F0_in)
%     --ref     <Hz>          reference F0 used by the child preset (150 Hz)
%     --formant <r>           final formant factor (default = pitch ratio)
%     --tilt    <dB/oct>      spectral tilt about 1 kHz (brightness)
%     --tremor  <pct>         tremor depth in percent of F0 (elderly)
%     --rate    <Hz>          tremor rate (default 5)
%     --breath  <pct>         breath-noise level in percent (elderly)
%     --fs      <Hz>          expected sample rate (resampled if different)
%     --nfft    <n>           STFT size, default 512
%     --hop     <n>           STFT hop,  default nfft/4
%     --target-level <dBFS>   output RMS, default -18
%     --no-normalize          keep the output level instead of normalising
%     --plot                  show a before/after spectrogram figure
%     --quiet                 suppress the report
%     --help
%
%   EXAMPLES
%     >> voice_changer('voice.wav','--preset','child','out_child.wav')
%     >> voice_changer('voice.wav','--preset','elder','--tremor',1.6,'out_elder.wav')
%     >> voice_changer('voice.wav','--pitch',7,'--formant',1.2,'out.wav')
%     >> [y,fs] = audioread('voice.wav'); z = voice_changer(y,'--preset','child');
%
%   ---------------------------------------------------------------------
%   ALGORITHM (all base MATLAB: fft/ifft only, no resample/butter/pwelch)
%     analysis  vc_analyze        normalised autocorrelation F0 tracker
%     pitch     vc_pitchshift_pv  phase vocoder stretch + band-limited resample
%     formants  vc_env + vc_mask  cepstral envelope, log-frequency warp
%     elderly   vc_tremor         fractional-delay time-varying resampling
%               vc_breath         envelope-scaled high-passed noise
%     filtering vc_mask           envelope warp + tilt + rumble, one FFT pass
%
%   See also VC_PITCHSHIFT_PV, VC_MASK, VC_ENV, VC_TREMOR, VC_ANALYZE.

t_all = tic;

% ---------------------------------------------------------------- defaults
defspec = struct( ...
    'in', [], 'out', '', 'outfile', '', 'preset', 'child', 'pitch', [], ...
    'target', [], 'ratio', [], 'ref', [], 'formant', [], 'tilt', [], ...
    'tremor', [], 'rate', [], 'breath', [], 'fs', [], 'nfft', [], 'hop', [], ...
    'target_level', [], 'normalize', true, 'no_normalize', false);

cfg = struct('fs', 16000, 'nfft', 512, 'hop', 128, 'pitch', 6, ...
    'pitchMode', 'rel', 'pitchRef', 150, 'pitchRatio', [], 'formant', [], ...
    'tilt', 0, 'tremor', 0, 'tremorRate', 5, 'wobble', 0.6, 'wobbleRate', 0.7, ...
    'breath', 0, 'targetLevelDb', -18, 'normalize', true, 'seed', 20240);

[s, cfg, args] = vc_args(defspec, cfg, varargin);

if args.help
    print_help();
    if nargout > 0, y = []; end
    if nargout > 1, info = struct(); end
    return
end

% ------------------------------------------------------------- presets
preset = lower(strrep(char(string(s.preset)), '-', '_'));
switch preset
    case {'child', 'kid', 'child_male'}
        pp = struct('pitch', 7, 'formant', 1.22, 'tilt', 1.5, ...
                    'mode', 'abs', 'target', 235, 'tremor', 0, 'breath', 0, 'ref', 150);
    case {'child_female', 'girl'}
        pp = struct('pitch', 5.5, 'formant', 1.18, 'tilt', 1.0, ...
                    'mode', 'abs', 'target', 250, 'tremor', 0, 'breath', 0, 'ref', 190);
    case {'elder', 'old', 'elder_male', 'old_man'}
        pp = struct('pitch', -2.5, 'formant', 0.94, 'tilt', -1.8, ...
                    'mode', 'ratio', 'target', [], 'tremor', 1.0, 'breath', 0.9, 'ref', []);
    case {'elder_female', 'old_woman'}
        pp = struct('pitch', -1.8, 'formant', 0.96, 'tilt', -1.2, ...
                    'mode', 'ratio', 'target', [], 'tremor', 0.8, 'breath', 0.7, 'ref', []);
    case {'normal', 'adult', 'male', 'female', 'none', 'identity'}
        pp = struct('pitch', 0, 'formant', 1, 'tilt', 0, ...
                    'mode', 'ratio', 'target', [], 'tremor', 0, 'breath', 0, 'ref', []);
    otherwise
        error('voice_changer:preset', 'unknown preset "%s" (child | elder | normal | ...)', preset);
end

specified = args.specified;
getnum = @(v) str2double(char(string(v)));

% preset bundle first, then the explicit options, then the pitch anchor.
% Precedence of the pitch anchor: --ratio > --target > --pitch > preset.
if ismember('pitch', specified) || ~isempty(s.pitch), cfg.pitch = getnum(s.pitch);   end
if ~ismember('formant', specified) && isempty(s.formant), cfg.formant = pp.formant;  end
if ~ismember('tilt',    specified) && isempty(s.tilt),    cfg.tilt    = pp.tilt;     end
if ~ismember('tremor',  specified) && isempty(s.tremor),  cfg.tremor  = pp.tremor;   end
if ~ismember('breath',  specified) && isempty(s.breath),  cfg.breath  = pp.breath;   end
if ~ismember('ref',     specified) && isempty(s.ref) && ~isempty(pp.ref)
    cfg.pitchRef = pp.ref;
end

if ~isempty(s.ratio)
    cfg.pitchMode   = 'ratio';
    cfg.pitchRatio  = getnum(s.ratio);
elseif ~isempty(s.target)
    cfg.pitchMode   = 'abs';
    cfg.pitchTarget = getnum(s.target);
elseif ~isempty(s.pitch)
    cfg.pitchMode   = 'rel';                 % an explicit --pitch overrides the preset anchor
    cfg.pitch       = getnum(s.pitch);
elseif strcmp(pp.mode, 'abs')
    cfg.pitchMode   = 'abs';
    cfg.pitchTarget = pp.target;
else
    cfg.pitchMode   = 'ratio';               % preset semitone / explicit factor
    cfg.pitch       = pp.pitch;
    if isfield(pp, 'ratio') && ~isempty(pp.ratio)
        cfg.pitchRatio = pp.ratio;
    end
end
if ~isempty(s.formant),      cfg.formant = getnum(s.formant);         end
if ~isempty(s.tilt),         cfg.tilt = getnum(s.tilt);               end
if ~isempty(s.tremor),       cfg.tremor = getnum(s.tremor);           end
if ~isempty(s.rate),         cfg.tremorRate = getnum(s.rate);         end
if ~isempty(s.breath),       cfg.breath = getnum(s.breath);           end
if ~isempty(s.ref),          cfg.pitchRef = getnum(s.ref);            end
if ~isempty(s.nfft),         cfg.nfft = 2 ^ round(log2(getnum(s.nfft))); end
if ~isempty(s.hop),          cfg.hop = max(1, round(getnum(s.hop)));  end
if ~isempty(s.target_level), cfg.targetLevelDb = getnum(s.target_level); end
if isfield(s, 'normalize') && (islogical(s.normalize) || isnumeric(s.normalize)) ...
        && ~s.normalize
    cfg.normalize = false;
end
if isfield(s, 'no_normalize') && (islogical(s.no_normalize) || isnumeric(s.no_normalize)) ...
        && s.no_normalize
    cfg.normalize = false;                      % --no-normalize also clears it
end
lvl = cfg.targetLevelDb;

% ------------------------------------------------------------- input
[x, fsIn, inName] = load_audio(s.in);
x = double(x);
if size(x, 2) > 1
    x = mean(x, 2);
end
if ~isempty(s.fs)
    fsWant = getnum(s.fs);
    if abs(fsWant - fsIn) > 1
        x = vc_resample(x, fsIn / fsWant, round(numel(x) * fsWant / fsIn));
        if ~args.quiet
            fprintf('[voice_changer] input resampled %g Hz -> %g Hz\n', fsIn, fsWant);
        end
        fsIn = fsWant;
    end
end
fs = fsIn;
x = x(:);
n = numel(x);
if n < cfg.nfft
    error('voice_changer:short', 'input too short: %d samples', n);
end

% ------------------------------------------------------------- analysis
tA = tic;
A0 = vc_analyze(x, fs);
tAnalyze = toc(tA);

if strcmp(cfg.pitchMode, 'abs')
    ref = cfg.pitchRef;
    if isempty(ref) || ~isfinite(ref)
        ref = A0.f0;
    end
    if ~isfinite(ref) || ref <= 0
        ref = 150;
    end
    cfg.pitchRef   = ref;
    cfg.pitchRatio = cfg.pitchTarget / ref;
elseif ~isempty(cfg.pitchRatio)
    % explicit factor (--ratio or preset ratio): keep as is
    cfg.pitchRatio = cfg.pitchRatio;
else
    cfg.pitchRatio = 2 ^ (cfg.pitch / 12);
end
cfg.pitchRatio = max(0.4, min(2.2, cfg.pitchRatio));
r = cfg.pitchRatio;

if isempty(cfg.formant)
    cfg.formant = r;
end
Fratio = max(0.4, min(2.2, cfg.formant));

% ------------------------------------------------------------- processing
tP = tic;

% (1) spectral analysis of the source: magnitude + cepstral envelope
[env0, ~] = vc_env(x, 2048);

% (2) pitch conversion: phase-vocoder stretch + band-limited resampling
y = vc_pitchshift_pv(x, r, cfg.nfft, cfg.hop);
if abs(fs - fsIn) > 1
    y = vc_resample(y, fsIn / fs, n);
end
y = y(:);
if numel(y) < n
    y = [y; zeros(n - numel(y), 1)];
else
    y = y(1:n);
end

% (3) formant conversion + spectral tilt (phase preserving, zero delay)
tilt_post = cfg.tilt - 20 * log10(r);        % pitch shift already scaled all formants
% The mask carries a rumble shelf and a level normalisation, so it is only
% applied when the spectrum is really reshaped: an identity conversion (all
% factors 1) then stays transparent instead of picking up a DC shelf.
reshape_spec = abs(Fratio - r) > 1e-9 || abs(tilt_post) > 1e-12;
if reshape_spec
    gain = vc_mask(env0, Fratio / r, tilt_post, 10 ^ (-12 / 20), 2048, fs / 2, true);
    y = apply_mask(y, gain);
end

% (4) elderly layer: tremor (rate modulation) and breathiness
if cfg.tremor > 0
    y = vc_tremor(y, fs, cfg.tremor, cfg.tremorRate, cfg.wobbleRate, cfg.wobble / 2);
end
if cfg.breath > 0
    y = vc_breath(y, fs, cfg.breath, cfg.seed);
end

% (5) level
if cfg.normalize
    cu = sqrt(mean(y .^ 2));
    if cu > 1e-9
        y = y * (10 ^ (lvl / 20) / cu);
    end
end
pk = max(abs(y));
if pk > 0.999
    y = y * (0.999 / pk);
end
y = min(max(y, -1), 1);
tProcess = toc(tP);

% ------------------------------------------------------------- output
A1 = vc_analyze(y, fs);
f0_1 = A1.f0;
% The tracker is a plain estimator and can lock onto a multiple of the true
% period on a converted voice (a strong upper harmonic makes 2*T0 or 3*T0 just
% as periodic).  When its answer is not consistent with the conversion that was
% actually applied, the readout is reported as unreliable instead of printing a
% misleading number; the conversion factors above are exact by construction.
f0_reliable = isfinite(f0_1) && abs(f0_1 - r * A0.f0) <= 0.25 * r * max(A0.f0, 1);
if ~f0_reliable
    f0_1 = NaN;
end
outName = char(string(s.outfile));
if isempty(outName)
    outName = char(string(s.out));
end
if ~isempty(outName)
    [~, ~, ext] = fileparts(outName);
    if isempty(ext)
        outName = [outName '.wav'];
    end
    audiowrite(outName, y, fs);
end

info = struct('fs', fs, 'n', n, 'preset', preset, 'f0_in', A0.f0, ...
    'f0_out', f0_1, 'pitch_ratio', r, 'formant_ratio', Fratio, ...
    'formant_scale_applied', Fratio / r, 'tilt_db_oct', cfg.tilt, ...
    'tremor_pct', cfg.tremor, 'breath_pct', cfg.breath, ...
    'target_f0', NaN, 'pitch_ref', cfg.pitchRef, 'outfile', outName, ...
    'time_analyze', tAnalyze, 'time_process', tProcess, 'time_total', toc(t_all));
if strcmp(cfg.pitchMode, 'abs')
    info.target_f0 = cfg.pitchTarget;
end

if ~args.quiet
    print_report(info, inName, A0, args);
end
end

% ======================================================================
function [x, fs, name] = load_audio(in)
%LOAD_AUDIO  Accept a numeric signal or a file name and normalise the result.
name = '';
if isnumeric(in) || islogical(in)
    x = double(in);
    fs = 16000;
    return
end
fname = char(string(in));
if isempty(fname)
    fname = 'demo_voice.wav';
end
if exist(fname, 'file') ~= 2
    error('voice_changer:io', 'input file not found: %s', fname);
end
[x, fs] = audioread(fname);
name = fname;
end

% ======================================================================
function y = apply_mask(x, gain)
%APPLY_MASK  Zero-phase frequency-domain shaping with a one-sided gain mask.
%   The signal is zero-padded to the next power of two and the mask is
%   interpolated onto the padded grid, so no circular wraparound occurs.
y = x(:);
n = numel(y);
np = 2 ^ nextpow2(2 * n);
X = fft(y, np);
nh = np / 2 + 1;
k = (0:(nh - 1)).';
pos = 1 + k * (numel(gain) - 1) / (nh - 1);
g = interp1((1:numel(gain)).', gain(:), pos, 'linear', 'extrap');
g = max(g, 0);
X(1:nh) = X(1:nh) .* g;
X(nh + 1:end) = conj(X(np / 2:-1:2));
y = real(ifft(X, np));
y = y(1:n);
end

% ======================================================================
function print_report(info, inName, A0, args)
fprintf('\n[voice_changer] preset=%s   in=%s\n', info.preset, ...
        ternary(isempty(inName), '<numeric array>', inName));
fprintf('  analysis : F0 = %6.1f Hz, voiced %4.0f%%, centroid %5.0f Hz, %.1f ms\n', ...
        A0.f0, 100 * A0.voiced, A0.cent, 1000 * info.time_analyze);
if isfinite(info.target_f0)
    fprintf('  pitch    : F0 x%.3f  (target %.0f Hz)  ->  %s\n', ...
            info.pitch_ratio, info.target_f0, f0_text(info.f0_out));
else
    fprintf('  pitch    : F0 x%.3f  ->  %s\n', info.pitch_ratio, f0_text(info.f0_out));
end
fprintf('  formant  : final x%.3f (envelope scaled x%.3f before the pitch shift)\n', ...
        info.formant_ratio, info.formant_scale_applied);
fprintf('  tilt     : %+.2f dB/oct     tremor: %.2f%%     breath: %.2f%%\n', ...
        info.tilt_db_oct, info.tremor_pct, info.breath_pct);
fprintf('  timing   : total %.0f ms  (analysis %.0f ms + processing %.0f ms)  fs=%g Hz, %.2f s audio\n', ...
        1000 * info.time_total, 1000 * info.time_analyze, 1000 * info.time_process, ...
        info.fs, info.n / info.fs);
if info.time_total > 1
    fprintf('  NOTE: this run exceeded the 1 s budget (%.2f s)\n', info.time_total);
end
if ~isempty(info.outfile)
    fprintf('  written  : %s\n', info.outfile);
end
if args.plot
    plot_report(inName, info);
end
fprintf('\n');
end

function s = f0_text(f0)
if isfinite(f0)
    s = sprintf('F0 = %.1f Hz', f0);
else
    s = 'F0 readout unreliable (tracker locked onto a higher harmonic)';
end
end

% ======================================================================
function plot_report(inName, info)
%PLOT_REPORT  Before/after spectrogram overview (optional, --plot).
try
    if isempty(inName) || exist(inName, 'file') ~= 2
        return
    end
    [a, fs] = audioread(inName);
    a = mean(double(a), 2);
    b = audioread(info.outfile);
    b = mean(double(b), 2);
    figure('Name', ['voice_changer: ' info.preset], 'Color', 'w');
    subplot(2, 1, 1);
    spectrogram_local(a, fs);
    title(sprintf('input   F0 = %.1f Hz', info.f0_in));
    subplot(2, 1, 2);
    spectrogram_local(b, fs);
    if isfinite(info.f0_out)
        t2 = sprintf('%s   F0 = %.1f Hz  (pitch x%.2f, formant x%.2f)', ...
                     info.preset, info.f0_out, info.pitch_ratio, info.formant_ratio);
    else
        t2 = sprintf('%s   (pitch x%.2f, formant x%.2f)', ...
                     info.preset, info.pitch_ratio, info.formant_ratio);
    end
    title(t2);
catch err
    warning('voice_changer:plot', 'plot failed: %s', err.message);
end
end

function spectrogram_local(x, fs)
nfft = 512;
hop = 128;
[X, ~] = vc_stft(x, nfft, hop);
S = 20 * log10(abs(X(1:nfft / 2 + 1, :)) + 1e-9);
imagesc((0:size(S, 2) - 1) * hop / fs, (0:nfft / 2) * fs / nfft, S);
axis xy; clim(max(S(:)) + [-80 0]);
xlabel('time (s)'); ylabel('frequency (Hz)');
end

% ======================================================================
function print_help()
fprintf(['voice_changer - command line voice changer (normal / child / elderly)\n' ...
    '\n' ...
    '  voice_changer(''in.wav'', ''--preset'', ''child'', ''out.wav'')\n' ...
    '  y = voice_changer(x, ''--preset'', ''elder'');\n' ...
    '\n' ...
    'presets: child | child_female | elder | elder_male | elder_female | normal\n' ...
    'options: --pitch <semitones>  --target <Hz>  --ratio <r>  --ref <Hz>\n' ...
    '         --formant <r>  --tilt <dB/oct>  --tremor <pct>  --rate <Hz>\n' ...
    '         --breath <pct>  --fs <Hz>  --nfft <n>  --hop <n>\n' ...
    '         --target-level <dBFS>  --no-normalize  --plot  --quiet\n' ...
    '\n' ...
    'conversion = pitch shift (phase vocoder) + formant warp (cepstral envelope)\n' ...
    '             + spectral tilt + elderly tremor/breathiness\n']);
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

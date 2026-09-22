function info = run_voice_changer(varargin)
%RUN_VOICE_CHANGER  Command line entry point for the voice changer.
%
%   Shell usage (no MATLAB window needed):
%
%       matlab -batch "run_voice_changer('child','in.wav','out.wav')"
%       matlab -batch "run_voice_changer('elder','in.wav','out.wav','--tremor',1.5)"
%       matlab -batch "run_voice_changer('in.wav','out.wav')"
%       matlab -batch "run_voice_changer --help"
%       matlab -batch "run_voice_changer --selftest"
%
%   ARGUMENTS (in this order, all optional)
%       1. preset        one of the presets, or an input file name (see below)
%       2. in.wav        input audio file
%       3. out.wav       output audio file; defaults to out_<preset>.wav
%       ...              any option accepted by VOICE_CHANGER, e.g. --target,
%                        --formant, --tilt, --tremor, --breath, --plot, --quiet
%
%   The preset may be omitted: then the first argument that is not an option is
%   taken as the input file and the next one as the output file.  --out FILE
%   sets the output explicitly.
%
%   EXIT CODE: 0 on success, 1 on failure (bad file, bad option, write error),
%   which is what makes this usable from a batch file or a shell script.
%
%   Examples
%       run_voice_changer('child', 'voice.wav', 'kid.wav', '--target', 300)
%       run_voice_changer('voice.wav', 'kid.wav', '--formant', 1.15, '--tilt', 1)
%       run_voice_changer('elder', 'voice.wav', '--out', 'old.wav', '--plot')
%
%   See also VOICE_CHANGER, DEMO_VOICE_CHANGER.

% ---------------------------------------------------------------- setup
here = fileparts(mfilename('fullpath'));
if ~isempty(here)
    addpath(here);
end
info = struct();                       % so the output is always assigned

% ------------------------------------------------------------- --help etc.
raw = varargin;
if isempty(raw) && ~isempty(strtrim(getenv('VOICE_CHANGER_ARGS')))
    raw = strsplit(strtrim(getenv('VOICE_CHANGER_ARGS')));   % allow env-var style calls
end
for k = 1:numel(raw)
    if ischar(raw{k}) || (isstring(raw{k}) && isscalar(raw{k}))
        a = lower(strtrim(char(string(raw{k}))));
        switch a
            case {'--help', '-h', 'help', '/?'}
                print_help();
                info = struct();
                return
            case {'--selftest', '-t', 'selftest', '--test'}
                try
                    okAll = demo_voice_changer();
                catch err
                    fail(err);
                end
                if okAll
                    fprintf('\nrun_voice_changer: self test PASSED\n');
                    info = struct('selftest', true);
                    return
                else
                    fprintf(2, '\nrun_voice_changer: self test FAILED\n');
                    exit(1);
                end
        end
    end
end

% ------------------------------------------------- parse preset / in / out
presets = {'child', 'child_bright', 'child_soft', 'child_female', 'elder', 'elder_male', ...
           'elder_female', 'normal', 'adult', 'male', 'female', 'kid', 'kid_bright', ...
           'kid_soft', 'child2', 'girl', 'old', 'old_man', 'old_woman', 'none', 'identity'};

preset = '';
inFile = '';
outFile = '';
opts   = {};
posSeen = 0;

k = 1;
while k <= numel(raw)
    a = raw{k};
    isStr = ischar(a) || (isstring(a) && isscalar(a));
    if ~isStr
        k = k + 1;
        continue
    end
    tok = char(string(a));
    key = lower(strrep(tok, '-', ''));

    if strcmpi(key, 'out') && (k + 1) <= numel(raw)          % --out FILE
        outFile = char(string(raw{k + 1}));
        k = k + 2;
        continue
    end
    if startsWith(tok, '-')                                  % option passthrough
        opts{end + 1} = tok;                                  %#ok<AGROW>
        if (k + 1) <= numel(raw) && looks_like_value(raw{k + 1})
            opts{end + 1} = raw{k + 1};                       %#ok<AGROW>
            k = k + 2;
        else
            k = k + 1;
        end
        continue
    end

    % positional argument
    posSeen = posSeen + 1;
    if posSeen == 1 && any(strcmpi(tok, presets)) && isempty(preset)
        preset = tok;
    else
        % A first positional that is neither a preset nor an existing audio
        % file is almost always a mistyped preset, so say that instead of the
        % confusing "input file not found: nosuchpreset".
        if isempty(inFile) && posSeen <= 2 && exist(tok, 'file') ~= 2 && ~has_audio_ext(tok)
            fprintf(2, '[run_voice_changer] ''%s'' is neither a known preset nor an existing audio file\n', tok);
            fprintf(2, '  presets: %s\n', strjoin({'child', 'child_female', 'elder', 'elder_female', 'normal'}, ' | '));
            fprintf(2, '  audio  : %s\n', strjoin({'.wav', '.mp3', '.flac', '.m4a', '.ogg', '.aac'}, ' '));
            fprintf(2, '  run "run_voice_changer --help" for usage\n');
            exit(1);
        end
        if isempty(inFile)
            inFile = tok;
        elseif isempty(outFile)
            outFile = tok;
        else
            opts{end + 1} = tok;                              %#ok<AGROW>
        end
    end
    k = k + 1;
end

if isempty(preset), preset = 'child'; end
if isempty(inFile), inFile = fullfile(here, 'demo_voice.wav'); end
if isempty(outFile), outFile = fullfile(here, ['out_' preset '.wav']); end

% ------------------------------------------------------------- run
if exist(inFile, 'file') ~= 2
    if strcmp(inFile, fullfile(here, 'demo_voice.wav'))
        fprintf('[run_voice_changer] no input given, generating a synthetic test voice\n');
        [xt, fsx] = vc_synthvoice(16000, 2.0, 120, [700 1220 2600 3400]);
        audiowrite(inFile, xt, fsx);
    else
        fprintf(2, '[run_voice_changer] input file not found: %s\n', inFile);
        exit(1);
    end
end

fprintf('[run_voice_changer] preset=%s\n  in : %s\n  out: %s\n', preset, inFile, outFile);
try
    [~, info] = voice_changer(inFile, '--preset', preset, opts{:}, outFile);
catch err
    fail(err);
end

fprintf('[run_voice_changer] done: F0 %s -> %s, pitch x%.3f, formant x%.3f, %.0f ms\n', ...
        num2str(info.f0_in, '%.1f'), f0_txt(info), info.pitch_ratio, ...
        info.formant_ratio, 1000 * info.time_total);
end

% ======================================================================
function tf = has_audio_ext(s)
%HAS_AUDIO_EXT  True when the name ends in a known audio extension.
[~, ~, ext] = fileparts(s);
tf = any(strcmpi(ext, {'.wav', '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.aiff', '.w64'}));
end

% ======================================================================
function tf = looks_like_value(v)
%LOOKS_LIKE_VALUE  True when V is a number or a string that is not an option.
if isnumeric(v) || islogical(v)
    tf = true;
elseif ischar(v) || (isstring(v) && isscalar(v))
    tf = ~startsWith(char(string(v)), '-');
else
    tf = false;
end
end

% ======================================================================
function s = f0_txt(info)
%F0_TXT  The F0 readout for the one-line summary, or why there is none.
%   When the confirmation search finds no periodicity where the conversion must
%   have put it, the designed value is still worth printing - the conversion
%   factors are exact by construction - but it must not look like a measurement.
if isfinite(info.f0_out)
    s = sprintf('%.1f Hz', info.f0_out);
    return
end
if isfield(info, 'f0_expected') && isfinite(info.f0_expected)
    s = sprintf('%.0f Hz-designed-not-verified', info.f0_expected);
else
    s = 'not measurable (no voiced frame found)';
end
end

% ======================================================================
function fail(err)
fprintf(2, '[run_voice_changer] ERROR: %s\n', err.message);
if ~isempty(err.stack)
    fprintf(2, '  at %s line %d\n', err.stack(1).name, err.stack(1).line);
end
exit(1);
end

% ======================================================================
function print_help()
fprintf([ ...
'run_voice_changer - command line voice changer (normal / child / elderly)\n' ...
'\n' ...
'USAGE\n' ...
'  matlab -batch "run_voice_changer(''PRESET'',''IN.WAV'',''OUT.WAV'' [OPTIONS])"\n' ...
'  matlab -batch "run_voice_changer(''IN.WAV'',''OUT.WAV'' [OPTIONS])"      %% preset=child\n' ...
'  matlab -batch "run_voice_changer --help"\n' ...
'  matlab -batch "run_voice_changer --selftest"\n' ...
'\n' ...
'ARGUMENTS\n' ...
'  1  preset     child | child_bright | child_female | elder | elder_female | normal\n' ...
'  2  in.wav     input audio (wav/mp3/flac/m4a, any sample rate, mono or stereo)\n' ...
'  3  out.wav    output file (default out_<preset>.wav); --out FILE also works\n' ...
'     OPTIONS    passed straight to voice_changer, see below\n' ...
'\n' ...
'OPTIONS\n' ...
'  --target <Hz>      absolute output pitch           --pitch <semitones>  relative\n' ...
'  --ratio <r>        pitch factor directly           --ref <Hz>  reference pitch\n' ...
'  --formant <r>      formant factor (default: preset factor, see voice_changer)\n' ...
'  --formant-track    scale the child factor with the pitch (experimental, off)\n' ...
'  --tilt <dB/oct>    brightness                       --breath <pct>  breathiness\n' ...
'  --tremor <pct>     tremor depth                     --rate <Hz>  tremor rate\n' ...
'  --fs <Hz>          sample rate for ARRAY input only --nfft <n>  --hop <n>\n' ...
'  --target-level <dBFS>  output level                 --no-normalize\n' ...
'  --plot             show input/output spectra        --quiet  no report\n' ...
'\n' ...
'EXIT CODE  0 = success, 1 = failure (usable from .bat / shell / python subprocess)\n' ...
'\n' ...
'EXAMPLES\n' ...
'  run_voice_changer(''child'',''voice.wav'',''kid.wav'')\n' ...
'  run_voice_changer(''child'',''voice.wav'',''kid.wav'',''--target'',300,''--formant'',1.15)\n' ...
'  run_voice_changer(''elder'',''voice.wav'',''--out'',''old.wav'',''--tremor'',1.5,''--plot'')\n' ...
'  run_voice_changer(''voice.wav'',''kid.wav'')\n' ...
'\n' ...
'NOTE  this is a wrapper around voice_changer for shell use; in MATLAB you can\n' ...
'      call voice_changer directly with the same options.\n']);
end

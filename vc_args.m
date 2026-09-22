function [spec, cfg, args] = vc_args(defspec, cfg0, c)
%VC_ARGS  Minimal command-line parser + preset expansion for the voice changer.
%
%   [SPEC, CFG, ARGS] = VC_ARGS(DEFSPEC, CFG0, C) parses the cell array C with
%   NAME/VALUE options in any order.  No toolbox (inputParser) is required.
%
%   Supported forms (case-insensitive, one or two leading dashes):
%       --preset child | elder | normal ...      preset bundle
%       --pitch <semitones>                      relative pitch shift
%       --target <hz> | --ratio <r>              alternative pitch anchoring
%       --formant <r>   --tilt <db/oct>          spectral envelope controls
%       --tremor <pct> --rate <hz>               elderly tremor
%       --breath <pct>  --ref <hz>               noise / reference pitch
%       --fs <hz>  --nfft <n>  --hop <n>         analysis parameters
%       --target-level <db>  --no-normalize      output level
%       --plot, --quiet, --help
%
%   Options given on the command line always win over the preset bundle; the
%   list of explicitly given option names is returned in ARGS.specified.

spec = defspec;
cfg  = cfg0;
args = struct('plot', false, 'quiet', false, 'help', false, 'specified', {{}});
if nargin < 3 || isempty(c)
    return
end
if ~iscell(c)
    c = {c};
end

i = 1;
npos = 0;
if ~isempty(c) && (isnumeric(c{1}) || islogical(c{1}))
    spec.in = c{1};                              % numeric signal given directly
    i = 2;
    npos = 1;
elseif ~isempty(c) && (ischar(c{1}) || (isstring(c{1}) && isscalar(c{1}))) && ...
        ~is_argname(c{1}, spec)
    % A bare leading string is the INPUT FILE and it must count as positional
    % argument 1.  It used to be recorded as the input without advancing the
    % positional counter, so the next bare string was also treated as
    % positional 1 and overwrote the input, leaving the output file unset:
    %   voice_changer('in.wav','--preset','child','out.wav')            worked
    %   voice_changer('in.wav','--preset','child','--no-formant-track','out.wav')
    %   ran the conversion and wrote NOTHING, because 'out.wav' landed on spec.in.
    % Whether it broke depended on which options happened to precede it, which is
    % why it looked intermittent.
    spec.in = char(string(c{1}));
    i = 2;
    npos = 1;
end

flds = fieldnames(spec);
while i <= numel(c)
    if ~(ischar(c{i}) || (isstring(c{i}) && isscalar(c{i})))
        i = i + 1;
        continue
    end
    key = char(string(c{i}));
    key = lower(strrep(key, '-', ''));
    hit = '';
    for fi = 1:numel(flds)
        cand = lower(strrep(flds{fi}, '_', ''));
        if strcmpi(key, cand)
            hit = flds{fi};
            break
        end
    end

    if ~isempty(hit)                             % ---- known option ----
        % Whether an option takes a value is decided by the TYPE of its default in
        % SPEC: a logical default (false) means a flag, anything else means it
        % takes a value.  The previous test - "the next token does not start with
        % --" - silently let a FLAG swallow the following positional argument:
        %   voice_changer('in.wav','--preset','child','--no-formant-track','out.wav')
        % set spec.no_formant_track = 'out.wav' and left the output file unset, so
        % the run converted the audio and wrote nothing at all.  It looked
        % intermittent because '--quiet' placed after the filename is recognised
        % as an option name, which happened to put the parse back on track.
        isFlag = islogical(spec.(hit)) && isscalar(spec.(hit));
        hasval = false;
        if ~isFlag && (i + 1) <= numel(c) && ~isempty(c{i + 1}) && ...
                ~is_argname(c{i + 1}, spec)
            nxt = c{i + 1};
            if isnumeric(nxt) || islogical(nxt)
                hasval = true;
            elseif ischar(nxt) || (isstring(nxt) && isscalar(nxt))
                hasval = true;
            end
        end
        if hasval
            spec.(hit) = c{i + 1};
            i = i + 2;
        else
            spec.(hit) = true;
            i = i + 1;
        end
        args.specified{end + 1} = hit;
    elseif any(strcmpi(key, {'h', 'help', '?'}))
        args.help = true;
        i = i + 1;
    elseif strcmpi(key, 'plot')
        args.plot = true;
        i = i + 1;
    elseif strcmpi(key, 'quiet')
        args.quiet = true;
        i = i + 1;
    else
        % Positional argument: 1st = input file, 2nd = output file.  This is
        % what makes  voice_changer('in.wav','--preset','child','out.wav')
        % work without any extra syntax.
        npos = npos + 1;

        if npos == 1
            spec.in = char(string(c{i}));
        elseif isfield(spec, 'outfile')
            spec.outfile = char(string(c{i}));
        end
        i = i + 1;
    end
end
end

% ======================================================================
function tf = is_argname(tok, spec)
%IS_ARGNAME  True when TOK names an option (or a flag) rather than a file.
%   Uses the same normalisation as the option matcher: lower case, dashes and
%   underscores removed.  \'plot\', \'--plot\' and \'help\' all count as names; a
%   path like \'out.wav\' does not.
key = lower(strrep(char(string(tok)), '-', ''));
key = strrep(key, '_', '');
flds = fieldnames(spec);
tf = any(strcmpi(key, {'h', 'help', '?', 'plot', 'quiet'}));
for k = 1:numel(flds)
    if strcmp(key, lower(strrep(flds{k}, '_', '')))
        tf = true;
        return
    end
end
end

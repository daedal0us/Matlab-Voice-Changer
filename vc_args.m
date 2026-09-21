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
        hasval = false;
        if (i + 1) <= numel(c) && ~isempty(c{i + 1})
            nxt = c{i + 1};
            if isnumeric(nxt) || islogical(nxt)
                hasval = true;
            elseif ischar(nxt) || (isstring(nxt) && isscalar(nxt))
                hasval = isempty(strfind(char(string(nxt)), '--')); %#ok<STREMP>
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

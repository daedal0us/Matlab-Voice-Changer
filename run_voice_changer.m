function results = run_voice_changer(preset, inFile, outFile)
%RUN_VOICE_CHANGER  One-shot command line entry point with a single preset.
%
%   RUN_VOICE_CHANGER(PRESET, INFILE, OUTFILE) is a thin wrapper around
%   VOICE_CHANGER so the conversion can be started straight from the shell:
%
%       matlab -batch "run_voice_changer('child','demo_voice.wav','out_child.wav')"
%
%   Defaults: PRESET='child', INFILE='demo_voice.wav' (generated if missing),
%   OUTFILE='out_<preset>.wav'.  Returns the INFO struct from VOICE_CHANGER.

here = fileparts(mfilename('fullpath'));
if ~isempty(here)
    addpath(here);
end

if nargin < 1 || isempty(preset), preset = 'child'; end
if nargin < 2 || isempty(inFile), inFile = fullfile(here, 'demo_voice.wav'); end
if nargin < 3 || isempty(outFile), outFile = fullfile(here, ['out_' preset '.wav']); end

if exist(inFile, 'file') ~= 2
    fprintf('[run_voice_changer] %s not found - generating a synthetic test voice\n', inFile);
    [x, fs] = vc_synthvoice(16000, 2.0, 120, [700 1220 2600 3400]);
    audiowrite(inFile, x, fs);
end

[~, info] = voice_changer(inFile, '--preset', preset, outFile);
results = info;
end

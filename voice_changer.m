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
%   FILE FORMATS - the extension decides, not the code
%
%   The pipeline never opens a file itself: it reads through AUDIOREAD and writes
%   through AUDIOWRITE, so the set of usable formats is exactly what this MATLAB
%   install's codecs accept, and it is not limited to WAV.  Measured on R2024b
%   (Windows) by FMT_PROBE.M, which tries every extension end to end:
%
%     write (output)  .wav  .flac  .mp3  .m4a  .mp4  .ogg  .oga  .opus
%                     ... of which .m4a / .mp4 accept only 44.1 or 48 kHz, so a
%                     16 kHz conversion cannot be written as AAC ("SampleRate
%                     值不受支持"); use .wav / .flac / .ogg, or resample first.
%     read  (input)   the same set.  MP4/M4A makes video files usable as input.
%     rejected        .aiff .aif .au .w64 .caf .webm .mkv .avi .mov - R2024b's
%                     AUDIOWRITE does not know these extensions at all and errors
%                     before looking at the data.
%
%   An output name with no extension gets '.wav' appended (the only place the
%   format is chosen for you), --fs resamples the input to a requested rate
%   instead of preserving it, and a multi-channel input is averaged to mono.
%
%   Use WAV or FLAC for anything you intend to MEASURE.  MP3/OGG/OPUS/M4A are
%   lossy: the codec's own lowpass and its encoder delay shift the waveform (a
%   1.100 s file came back as 1.155 s through MP3), which is fine for listening
%   but moves the F0 estimate and every timing figure.
%
%   ---------------------------------------------------------------------
%   PRESETS (--preset)
%     normal / adult / male / none  identity (A/B reference, 1:1)
%     child                         child-like voice:  F0 -> 210 Hz, formants x1.15
%                                   (the default; child_soft is an alias)
%     child_bright                  the same idea, more tract change and higher:
%                                   F0 -> 235 Hz, formants x1.22 (see the FORMANTS
%                                   note: the two factors have to move together)
%     child_female                  child-like voice for a female input: F0 -> 250 Hz
%     elder, elder_male             elderly voice:     F0 x0.86, formants x0.94,
%                                   tremor + breathiness + duller spectrum
%     elder_female                  gentler elderly transform for high voices
%
%   OPTIONS (all optional, command line wins over the preset)
%     --pitch   <semitones>   relative pitch shift  (+12 = one octave up)
%     --target  <Hz>          absolute target F0    (child preset: 210 Hz)
%     --ratio   <r>           pitch factor directly (r = F0_out / F0_in)
%     --ref     <Hz>          reference F0 used by the child preset (150 Hz)
%     --max-f0  <Hz>          ceiling on the OUTPUT F0.  The absolute presets
%                             derive their ratio from target/ref, which assumes
%                             the input is near ref; a higher input (a female
%                             voice under --preset child) would otherwise be
%                             pushed proportionally higher and thin out.  The
%                             ceiling only ever lowers the ratio.  Use 0 to
%                             disable it.
%     --formant <r>           final formant factor.  Default: the preset's fixed
%                             design factor for the child presets (1.15 / 1.18 /
%                             1.22), the pitch ratio for everything else.
%     --formant-track         opt in to scaling the child preset's design factor
%                             with the pitch factor (see FORMANTS below).
%                             Off by default; --no-formant-track is accepted as a
%                             no-op so existing command lines keep working, and it
%                             never beats an explicit --formant-track.
%     --tilt    <dB/oct>      spectral tilt about 1 kHz (brightness)
%     --tremor  <pct>         tremor depth in percent of F0 (elderly)
%     --rate    <Hz>          tremor rate (default 5)
%     --breath  <pct>         breath-noise level in percent (elderly)
%     --fs      <Hz>          expected sample rate (resampled if different)
%     --nfft    <n>           STFT size, default 512
%     --hop     <n>           STFT hop,  default nfft/4
%     --target-level <dBFS>   accepted for compatibility only; the output level
%                             now follows the INPUT RMS, not this value
%     --no-normalize          keep the converted level instead of matching the
%                             input RMS
%     --no-phase-lock         disable identity phase locking (it is ON by default;
%                             see VC_PITCHSHIFT_PV for why, and --phase-lock is
%                             accepted as the explicit opposite)
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
%   ---------------------------------------------------------------------
%   FORMANTS (the child presets use a FIXED design factor by default)
%   Each child preset carries a fixed formant factor - 1.15 for the default child,
%   1.18 for child_female, 1.22 for child_bright, i.e. the roughly 15..22 % shorter
%   vocal tract that makes an adult voice sound child-like - and that fixed value is
%   the DEFAULT.  The design point is a 150 Hz input (190 Hz for child_female), but
%   the factor itself does not move with the ratio: it is a vocal tract shape, so it
%   stays put.
%
%   DECISION: an experimental --formant-track mode scaled the factor with the
%   pitch (formant = formant0 * (ratio / r0), clamped to [1.00, 1.30], applied
%   only for ratio >= r0) so that the tract would follow the pitch when the
%   automatic reference moved the ratio.  It is NOT the default and is opt-in:
%   on real speech a fixed 1.22 tracked to 1.235, i.e. 1.2 % away, with 0.26..0.43
%   dB band-energy differences - the pitch already dominates the perceived age, so
%   the scaling bought nothing audible.  What it did buy was instability: the
%   tracking test compares the RAW pitch ratio against the preset's design ratio
%   r0, and on a 138 s male recording (F0 148.2 Hz, raw ratio 1.5856 vs
%   r0 = 1.5667 for that preset, only +1.2 % above it) the per-4 s-window ratios
%   ranged 1.068..1.785 with 2 of 5 windows above the threshold, so the decision
%   flipped the factor between the design value and the 1.30 clamp (F1 854 vs
%   910 Hz) from run to run.
%   The fixed factor has no such decision to get wrong.  --formant-track opts
%   back in, --no-formant-track is accepted as a no-op for old command lines, and
%   an explicit --formant always wins over both.
%   When tracking is on it reads the RAW pitch ratio, before the ratio ceiling
%   clamps it: reading the clamped value made a female input's true 0.94 look like
%   1.567 and produced a factor of 1.000, i.e. no tract change at all.
%
%   WHY THE PITCH TARGET AND THE FORMANTS MUST BE CHOSEN TOGETHER.  A child has
%   BOTH a higher voice and a shorter vocal tract, but not by the same amount: the
%   tract length ratio between an adult male and a 5..8 year old is roughly
%   1.14..1.25, while the F0 ratio is roughly 1.5..2.0.  The formant factor must
%   therefore be SMALLER than the pitch factor - that is why 1.22 belongs to ratio
%   1.567 and 1.15 to 1.400, and never something near the pitch ratio itself.
%   Turning the pitch target down without turning the formant factor down as well
%   leaves the tract sounding smaller than the pitch implies, which is heard as thin
%   and synthetic, i.e. the opposite of what was wanted.  Measured on a male
%   recording (F0 148.9 Hz):
%       target 210, formant 1.15 -> F0 210 Hz, centroid ~1244 Hz  (preset child)
%       target 235, formant 1.22 -> F0 235 Hz, centroid ~1356 Hz  (preset child_bright)
%   The gentler pair is the DEFAULT, which is why the preset is a pair of factors
%   rather than a --target override: the two numbers have to move together.
%
%   ---------------------------------------------------------------------
%   TIMING (decision recorded here because it used to be enforced as a rule)
%   This started life as a command line exercise with a "every run must finish
%   in under 1 s" requirement, and the code used to warn when a run went over.
%   That 1 s figure was a guard against accidentally writing a non-terminating
%   loop, NOT a property of the algorithm, and it is no longer enforced or
%   reported as a problem.  Legitimate cost scales with the number of samples:
%   the same 30 s recording takes about 3x longer at 44.1 kHz than at 16 kHz,
%   and the stages that dominate are ordinary O(number of output samples) work
%   (vc_resample, apply_mask), not anything pathological.
%
%   Measured breakdown for 30 s at 44.1 kHz (2.0 s of work in the DSP stages):
%       vc_resample 600 ms | apply_mask 400 | vc_analyze 430 | vc_istft 225
%       vc_mask 210 | vc_env 190 | vc_stft 130   (all ms)
%   For calibration the practical sizes people actually use: 2 s of audio is
%   0.1..0.35 s, 10 s is ~0.4 s, 60 s at 16 kHz is ~1.2 s.  The per-stage times
%   are printed in the report, so a regression is still visible without a hard
%   threshold.  If a budget is ever needed again, apply it per audio second
%   (roughly 20 ms per second at 16 kHz) rather than as an absolute limit.
%
%   See also VC_PITCHSHIFT_PV, VC_MASK, VC_ENV, VC_TREMOR, VC_ANALYZE.

t_all = tic;

% ---------------------------------------------------------------- defaults
defspec = struct( ...
    'in', [], 'out', '', 'outfile', '', 'preset', 'child', 'pitch', [], ...
    'target', [], 'ratio', [], 'ref', [], 'ref_auto', false, 'max_f0', [], ...
    'ratio_max', [], 'allow_down', [], 'formant_track', false, 'no_formant_track', false, ...
    'phase_lock', false, 'no_phase_lock', false, ...
    'formant', [], 'tilt', [], ...
    'formant_map', [], 'env_lifter', [], ...
    'tremor', [], 'rate', [], 'breath', [], 'fs', [], 'nfft', [], 'hop', [], ...
    'target_level', [], 'normalize', true, 'no_normalize', false);

cfg = struct('fs', 16000, 'nfft', 512, 'hop', 128, 'pitch', 6, ...
    'pitchMode', 'rel', 'pitchRef', 150, 'pitchRefFallback', 150, ...
    'formantTrack', false, 'formantMin', 1.00, 'formantMax', 1.30, 'formantDamp', 1, ...
    'pitchRatio', [], 'pitchRawRatio', [], 'maxF0', [], ...
    'pitchAsked', [], 'pitchCapped', false, 'pitchDownLimited', false, ...
    'allowDown', true, 'formant', [], ...
    'phaseLock', true, ...
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
% 'maxf0' is an OUTPUT PITCH CEILING, in Hz.  The absolute-target presets derive
% their ratio as target/ref, which assumes the input sits near 'ref' (150 Hz for
% child).  A higher input then gets pushed proportionally higher, and because the
% pitch stage moves every frequency by that factor the result piles energy into
% the top of the band and thins out.  Measured on a real 44.1 kHz female voice
% (F0 = 249.9 Hz): the child preset drove it to 391 Hz and multiplied the
% 2-5 kHz energy share by 8.17, against 3.41 for child_female.  The ceiling caps
% the output at maxF0 regardless of the input, so one preset behaves sensibly
% over the whole input range.  It only ever lowers the ratio, so presets are
% unaffected on the inputs they were designed for.
%
% 'ratiomax' is the RATIO CEILING, and it is NOT the preset's design ratio
% target/ref.  It used to be written that way (1.400 for child = 210/150) and that
% is a bug, because the absolute-target mode only requests target/ref when the
% input happens to sit AT the reference:
%
%     requested ratio = target / detected_F0      (--ref auto)
%
% so for every input BELOW the reference the request is LARGER than target/ref and
% the ceiling binds.  All of 测试2.wav (detected 148.5 Hz) hit it, and because the
% preset with the LOWEST target also carried the LOWEST ceiling (child_female
% 1.316 = 250/190 against child 1.400 = 210/150) the ceilings INVERTED the
% presets: the 210 Hz preset came out at 207.9 Hz and the 250 Hz preset at only
% 195.5 Hz, i.e. "child" sounded higher and thinner than "child_female", which is
% the opposite of the design.  The female recording never showed it because its
% detected 240.5 Hz is above the reference, so the request is below 1 and the
% ceiling never engages - which is exactly why the four presets behaved as
% intended on that file and not on the male one.
%
% The ceiling is now target/floor, where 'floor' is the lowest input F0 the preset
% is meant to handle, so the ceiling no longer depends on where the reference
% happens to sit:
%
%     child         210/100 = 2.100    (was 1.400)
%     child_bright  235/100 = 2.350    (was 1.567)
%     child_female  250/100 = 2.500    (was 1.316, reffallback 190 -> 150)
%
% THE FLOORS MUST BE ORDERED LIKE THE TARGETS, and that is not cosmetic.  With
% child_female's floor left at 150 Hz (its old design reference) its ceiling bound
% harder than child_bright's at 120 Hz, so on a 130 Hz voice child_female still
% came out at 217 Hz against child_bright's 235 Hz - the same inversion as before,
% just moved from the middle of the range to the bottom.  Equal floors cannot
% invert anything, because the applied factor is then min(target/F0, target/floor)
% and the target is the only thing that differs.  The floor alone decides where the
% clamp starts; which pitch each preset aims at is still the target's job.
%
% The ceiling still does its real job - bounding the ratio for an unusually deep
% voice, where target/F0 would otherwise exceed an octave - while the output
% ceiling above owns the opposite end.  The two knobs now act on opposite ends of
% the input range instead of fighting over the middle.
preset = lower(strrep(char(string(s.preset)), '-', '_'));
switch preset
    % Tilt values are calibrated so the formant stage does not change the overall
    % brightness relative to the pitch-only result.  Measured on a real 44.1 kHz
    % recording by matching the energy spectral centroid: child +1.00,
    % child_female +0.50, elder/elder_female -0.25 dB/oct (each within 7 % of the
    % pitch-only centroid).  Before this the values were 1.5 / 1.0 / -1.8 / -1.2
    % on top of a -20*log10(r) compensation, which measured 35..39 % too dark.
    %
    % The two child presets ask for nfft 1024 / hop 256 instead of the 512/128
    % default.  This is the one parameter that measurably reduces the phase
    % vocoder's metallic character: on a real recording at ratio 1.567 the
    % harmonic-to-total ratio in voiced frames improves from -1.44 to -0.96 dB
    % (i.e. ~10 % more of the frame energy stays in the harmonics instead of
    % smearing between them), the energy spectral centroid drops 1128 -> 1112 Hz
    % and the crest factor 14.5 -> 12.5.  A longer window also means fewer frames
    % and less phase error accumulated per unit time, which is what "metallic"
    % actually is.  The elderly presets keep 512/128: measured, they get worse
    % with the longer window (their pitch movement is downward and smaller, so the
    % extra smearing is not paid for by any coherence gain).
    case {'child', 'kid', 'child_male', 'child_soft', 'kid_soft', 'child2'}
        % THE DEFAULT CHILD PRESET (it used to be the 235 Hz one, which is now
        % 'child_bright').  F0 target 210 Hz with formant factor 1.15.
        %
        % The pair has to move TOGETHER - see the FORMANTS note in the header -
        % because the formant factor that belongs to a 1.57x pitch shift (1.22) is
        % too large for a 1.42x one: it would leave the tract sounding smaller than
        % the pitch suggests, which is heard as thin and synthetic.  Measured on the
        % male test recording: F0 148 -> 210 Hz, formant peaks x1.15, energy
        % spectral centroid 1244 Hz against 1356 Hz for the 235 Hz preset, i.e. 8 %
        % less bright, with the same harmonic-to-total ratio.
        %
        % 'ratiomax' history: this preset inherited 1.567 from the preset it was
        % split off from while it was still the alternative, and that clamped a
        % 148.9 Hz input straight back up to x1.567 = 235 Hz - i.e. it produced
        % exactly the preset it was supposed to be the gentler alternative to.
        % Caught by the demo check that asserts the design-point ratio, which is why
        % that check is written against the design point rather than against the
        % test signal.
        %
        % It is now target/floor = 210/100, because writing it as the design ratio
        % 210/150 made the ceiling bind for every voice below the 150 Hz reference -
        % which is most male voices, and it made a x1.400 ceiling beat the x1.414 the
        % preset actually needs at 148.5 Hz.  The floor is shared with the other two
        % child presets on purpose.  See the note above the switch.
        pp = struct('pitch', 5, 'formant', 1.15, 'tilt', 0.5, ...
                    'mode', 'abs', 'target', 210, 'tremor', 0, 'breath', 0, ...
                    'ref', 'auto', 'reffallback', 150, 'maxf0', 320, ...
                    'ratiomax', 210 / 100, 'allowdown', false, ...
                    'pitch0', 210 / 150, 'formant0', 1.15, ...
                    'nfft', 1024, 'hop', 256);
    case {'child_bright', 'kid_bright'}
        % The previous default, kept for A/B and for inputs that want more of a
        % child-like tract change: F0 target 235 Hz, formant x1.22 (ratio 1.567).
        % Same nfft/hop reasoning as above.
        pp = struct('pitch', 7, 'formant', 1.22, 'tilt', 1.0, ...
                    'mode', 'abs', 'target', 235, 'tremor', 0, 'breath', 0, ...
                    'ref', 'auto', 'reffallback', 150, 'maxf0', 320, ...
                    'ratiomax', 235 / 100, 'allowdown', false, ...
                    'pitch0', 235 / 150, 'formant0', 1.22, ...
                    'nfft', 1024, 'hop', 256);
    case {'child_female', 'girl'}
        % For a female input.  Its DESIGN reference is 190 Hz (the reffallback),
        % which is where x1.316 comes from, but the ceiling is target/floor =
        % 250/100, the same floor the other two child presets use.  With the old
        % 1.316 the ceiling bound for every input below 190 Hz, so this preset
        % delivered less pitch than the 210 Hz child preset on the male recording.
        % The reffallback stays 190 Hz: that is the input this preset is built
        % around when detection fails.
        pp = struct('pitch', 5.5, 'formant', 1.18, 'tilt', 0.5, ...
                    'mode', 'abs', 'target', 250, 'tremor', 0, 'breath', 0, ...
                    'ref', 'auto', 'reffallback', 190, 'maxf0', 340, ...
                    'ratiomax', 250 / 100, 'allowdown', false, ...
                    'pitch0', 250 / 190, 'formant0', 1.18, ...
                    'nfft', 1024, 'hop', 256);
    case {'elder', 'old', 'elder_male', 'old_man'}
        pp = struct('pitch', -2.5, 'formant', 0.94, 'tilt', -0.25, ...
                    'mode', 'ratio', 'target', [], 'tremor', 1.0, 'breath', 0.9, ...
                    'ref', [], 'reffallback', [], 'maxf0', [], 'ratiomax', [], ...
                    'pitch0', [], 'formant0', [], 'nfft', [], 'hop', []);
    case {'elder_female', 'old_woman'}
        pp = struct('pitch', -1.8, 'formant', 0.96, 'tilt', -0.25, ...
                    'mode', 'ratio', 'target', [], 'tremor', 0.8, 'breath', 0.7, ...
                    'ref', [], 'reffallback', [], 'maxf0', [], 'ratiomax', [], ...
                    'pitch0', [], 'formant0', [], 'nfft', [], 'hop', []);
    case {'normal', 'adult', 'male', 'female', 'none', 'identity'}
        pp = struct('pitch', 0, 'formant', 1, 'tilt', 0, ...
                    'mode', 'ratio', 'target', [], 'tremor', 0, 'breath', 0, ...
                    'ref', [], 'reffallback', [], 'maxf0', [], 'ratiomax', [], ...
                    'pitch0', [], 'formant0', [], 'nfft', [], 'hop', []);
    otherwise
        error('voice_changer:preset', 'unknown preset "%s" (child | elder | normal | ...)', preset);
end

specified = args.specified;
getnum = @(v) str2double(char(string(v)));

% preset bundle first, then the explicit options, then the pitch anchor.
% Precedence of the pitch anchor: --ratio > --target > --pitch > preset.
if ismember('pitch', specified) || ~isempty(s.pitch), cfg.pitch = getnum(s.pitch);   end
% Presets that carry a design formant factor (formant0) are handled by the
% tracking block further down, which owns both the fixed default and the opt-in
% --formant-track scaling - so they must not be assigned here.
if ~ismember('formant', specified) && isempty(s.formant) && ...
        (~isfield(pp, 'formant0') || isempty(pp.formant0))
    cfg.formant = pp.formant;
end
if ~ismember('tilt',    specified) && isempty(s.tilt),    cfg.tilt    = pp.tilt;     end
if ~ismember('tremor',  specified) && isempty(s.tremor),  cfg.tremor  = pp.tremor;   end
if ~ismember('breath',  specified) && isempty(s.breath),  cfg.breath  = pp.breath;   end
if ~ismember('ref',     specified) && isempty(s.ref) && ~isempty(pp.ref)
    cfg.pitchRef = pp.ref;                     % a number, or 'auto'
end
if isfield(pp, 'reffallback') && ~isempty(pp.reffallback)
    cfg.pitchRefFallback = pp.reffallback;     % used only when detection fails
end
% Direction policy of the preset: may the pitch ratio go below 1?  The CHILD
% presets say no - see the note where it is applied below.
if isfield(pp, 'allowdown') && ~isempty(pp.allowdown)
    cfg.allowDown = pp.allowdown;
end
% A preset may ask for a different frame size (the child presets do, see above);
% an explicit --nfft / --hop still wins, and the hop is only taken from the preset
% when the preset also names the nfft it belongs to.
if isfield(pp, 'nfft') && ~isempty(pp.nfft) && isempty(s.nfft)
    cfg.nfft = pp.nfft;
    if isfield(pp, 'hop') && ~isempty(pp.hop) && isempty(s.hop)
        cfg.hop = pp.hop;
    end
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
if ~isempty(s.ref)
    refArg = char(string(s.ref));
    if strcmpi(refArg, 'auto')
        cfg.pitchRef = 'auto';                 % --ref auto
    else
        cfg.pitchRef = getnum(s.ref);
    end
end
if ~isempty(s.ref_auto) && (islogical(s.ref_auto) || isnumeric(s.ref_auto)) ...
        && s.ref_auto
    cfg.pitchRef = 'auto';                     % --ref-auto
end
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
% ------------------------------------------------------ phase locking switch
% Identity phase locking is ON by default: A/B listening on a real recording
% found it removes most of the metallic character, which is the phase vocoder's
% phasiness and the defect this project has been chasing since its first
% conversions.  The objective metrics do NOT show the improvement (see the long
% note in VC_PITCHSHIFT_PV), so the listening result is what the default rests
% on - stated here so nobody re-derives the numbers and "fixes" the default back.
% --no-phase-lock restores the plain per-bin recursion.
if isfield(s, 'no_phase_lock') && (islogical(s.no_phase_lock) || isnumeric(s.no_phase_lock)) ...
        && s.no_phase_lock
    cfg.phaseLock = false;
end
if isfield(s, 'phase_lock') && (islogical(s.phase_lock) || isnumeric(s.phase_lock)) ...
        && s.phase_lock
    cfg.phaseLock = true;
end

lvl = cfg.targetLevelDb;
% THE CEILING IS NOW A CLIPPING GUARD, NOT A LEVEL.  When the level rule was
% "normalise to a fixed -18 dBFS", the ceiling and the level were the same
% number, so --target-level made sense as a loudness control.  The rule is now
% "match the input RMS" (see stage 5), and a fixed level would fight it: for the
% project's test recording (RMS 0.151, peak 1.000) matching the RMS puts the
% peaks at 1.0, so an -18 dBFS ceiling would have compressed everything above
% 0.126 - 1.9 % of the samples at a 0.5 knee.  What is left is the value that
% actually matters: 0.999, just short of full scale.  --target-level is still
% accepted so old command lines keep running, but it no longer sets the level.
ceil_lin = 0.999;
L_KNEELIN = 0.9;                 % knee: measured 0.046 % of samples sit above it

% ------------------------------------------------------------- input
[x, fsIn, inName] = load_audio(s.in, array_fs(varargin));
x = double(x);
% Average the channels only for a GENUINE multichannel matrix.  Testing
% size(x,2) > 1 alone also catches a row vector, which is a monophonic signal
% stored as 1xN, and mean(x,2) then collapses it to a single sample - the call
% dies in the length check below with "input too short: 1 samples" instead of
% saying anything about the shape.  audioread always returns a column, so this
% only bites a caller who passes a signal in memory (a GUI, or voice_changer(x,fs)).
if ~isvector(x)
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

% 'auto' as the reference is the documented way for a preset to scale to the
% speaker, and it is the default for the child presets.  It also decides whether
% the output pitch ceiling may act at all - see the note on it below.
autoRef = (ischar(cfg.pitchRef) || isstring(cfg.pitchRef)) && ...
          strcmpi(char(string(cfg.pitchRef)), 'auto');

if strcmp(cfg.pitchMode, 'abs')
    % The reference is either a number, or 'auto' meaning "use the measured F0 of
    % this recording".  Auto is what makes one preset scale to the speaker: an
    % absolute target with a FIXED reference assumes the input sits near that
    % reference (150 Hz for child), so a higher voice is pushed up by the same
    % ratio.  With the reference measured instead, a 250 Hz input gets
    % 235/250 = 0.94 - almost no pitch change - which is what a real child
    % conversion of a female voice should do, since adult female and child F0
    % ranges overlap heavily and the difference is mostly the vocal tract.
    % Measured: the same recording gives F0 x1.567 with a fixed 150 Hz reference
    % and x0.94 with auto.
    %
    % The estimator is reliable enough for this: on a real 44.1 kHz female
    % recording it returns 249.9 Hz over 8..15 s, within 0.05 % of an independent
    % autocorrelation measurement.  It is still an estimate, so the pitch ceiling
    % above stays in place as the safety net, and if it finds no voiced frames at
    % all (A0.f0 = NaN) the preset's fallback reference is used.
    ref = cfg.pitchRef;
    autoRef = (ischar(ref) || isstring(ref)) && strcmpi(char(string(ref)), 'auto');
    if autoRef
        ref = cfg.pitchRefFallback;                % used only if detection fails
        if isfinite(A0.f0) && A0.f0 > 0
            ref = A0.f0;
        end
    end
    if isempty(ref) || ~isfinite(ref)
        ref = A0.f0;                               % empty reference means auto too
    end
    if ~isfinite(ref) || ref <= 0
        ref = 150;
    end
    cfg.pitchRef   = ref;
    cfg.pitchRatio = cfg.pitchTarget / ref;
    cfg.pitchAsked = cfg.pitchRatio;           % before either ceiling, for tests
elseif ~isempty(cfg.pitchRatio)
    % explicit factor (--ratio or preset ratio): keep as is
    cfg.pitchRatio = cfg.pitchRatio;
else
    cfg.pitchRatio = 2 ^ (cfg.pitch / 12);
end

% Output pitch ceiling.  target/ref assumes the input is near 'ref'; a higher
% input would otherwise be pushed proportionally higher and the result piles
% energy at the top of the band (measured: 391 Hz and 8.17x the 2-5 kHz share
% for a 250 Hz female input under the child preset).  Capping the OUTPUT rather
% than the ratio keeps one preset sensible over the whole input range, and it
% only ever reduces the ratio, so an input near 'ref' is untouched.
% The ceiling needs a usable F0 estimate; if the tracker did not find voiced
% frames (A0.f0 = NaN) there is nothing to cap against and it is skipped, with
% the ratio still bounded by the absolute limit below.
%
% IT IS DISABLED WHEN THE REFERENCE IS 'auto', AND THAT IS THE POINT OF AUTO.
% The ceiling exists to stop a FIXED reference from driving a high input too far:
% with ref pinned at 150 Hz, a 250 Hz speaker asks for x1.567 = 391 Hz, which is
% why a ceiling was needed at all.  Auto reference asks for target/detected, so
% the output IS the target by construction and there is no runaway to cap - the
% ceiling can only take the preset away from its own target.  Measured on the
% 148.5 Hz male recording: with the ceiling active, 'child' stopped at 207.9 Hz
% and 'child_female' at 195.5 Hz - the preset with the HIGHER target came out
% LOWER, because its ceiling (340 Hz) is reached sooner than child's (320 Hz).
% Both now land on their targets.  --max-f0 still overrides explicitly, and the
% ratio ceiling below still bounds the low end in both modes.
cfg.maxF0 = [];
if isfield(s, 'max_f0') && ~isempty(s.max_f0)
    cfg.maxF0 = getnum(s.max_f0);              % --max-f0 overrides the preset
elseif isfield(pp, 'maxf0') && ~isempty(pp.maxf0) && ~autoRef
    cfg.maxF0 = pp.maxf0;
end
capped = false;
if ~isempty(cfg.maxF0) && isfinite(cfg.maxF0) && cfg.maxF0 > 0 && ...
        isfinite(A0.f0) && A0.f0 > 0
    ratio_cap = cfg.maxF0 / A0.f0;
    if cfg.pitchRatio > ratio_cap
        cfg.pitchRatio = ratio_cap;
        capped = true;
    end
end
cfg.pitchCapped = capped;

% Ratio ceiling, which is a different knob from the output ceiling above and is
% what --ref auto needs.  Auto makes the ratio target/detected_f0, so the ratio
% GROWS as the input gets lower: measured for the child preset, a 250 Hz input
% gives x0.94 (almost no pitch change, which is right - adult female and child F0
% ranges overlap) but a 110 Hz male input gives x2.14, i.e. more than an octave,
% far more than the preset was designed to do.  --ratio-max bounds that end while
% leaving the gentle end intact.  0 disables it.
%
% It is applied ONLY when the pitch request came from the preset.  An explicit
% --pitch / --target / --ratio is an instruction and must be honoured exactly:
% applied unconditionally, --pitch 12 (one octave) was silently reduced to the
% preset's 1.567, which the self test caught as "--pitch mapping wrong" and
% "absolute target missed".  The output ceiling above is deliberately NOT disabled
% that way, since it protects the output from being unusably thin; --max-f0 0
% removes it when the caller really wants the raw result.
explicitPitch = ismember('pitch', specified) || ismember('target', specified) || ...
                ismember('ratio', specified);
cfg.ratioMax = [];
if isfield(s, 'ratio_max') && ~isempty(s.ratio_max)
    cfg.ratioMax = getnum(s.ratio_max);
elseif ~explicitPitch && isfield(pp, 'ratiomax') && ~isempty(pp.ratiomax)
    cfg.ratioMax = pp.ratiomax;
end
cfg.ratioCapped = false;
cfg.pitchRawRatio = cfg.pitchRatio;            % before the ratio ceiling
if ~isempty(cfg.ratioMax) && isfinite(cfg.ratioMax) && cfg.ratioMax > 0 && ...
        cfg.pitchRatio > cfg.ratioMax
    cfg.pitchRatio = cfg.ratioMax;
    cfg.ratioCapped = true;
end

% Absolute guard on the factor.  It used to be 2.2, which is a THIRD ceiling and
% the tightest of the three: with the shared 100 Hz floor the child presets ask
% for up to 2.50 (250/100), so 2.2 would have cut the 250 Hz preset to 220 Hz on a
% 100 Hz voice - below child_bright's 235 Hz, i.e. the same inversion again, just
% further down.  The preset floors are the intended bound; this is only a
% sanity guard against a nonsense request, so it sits at the widest factor the
% resampler and the FFT stages were tested over.
cfg.pitchRatio = max(0.4, min(4, cfg.pitchRatio));

% DIRECTION GUARD: a child conversion must never LOWER the fundamental.
% A child's F0 is higher than any adult's, so a "child" preset that takes a
% 240.5 Hz female voice DOWN to 183.5 Hz is producing the opposite of a child -
% a heavier adult - however exactly it hits its target.  That is a real risk
% because the absolute targets (210 / 235 / 250 Hz) OVERLAP the adult female
% range: --ref auto asks for target/detected, and that expression has no notion of
% direction, so for an input above the target it faithfully scales down.
%
% Measured on 测试1.wav (240.5 Hz, 60 s): the child preset applied x0.873 and
% produced 183.5 Hz with a x1.15 tract - i.e. it made the speaker sound like a
% larger adult, and the run looked entirely successful in the report.  With the
% guard the same input gets x1.000 and only the vocal tract changes, which is what
% "child" can honestly offer a voice that is already above its target;
% child_female is the preset that keeps going up (target 250 Hz, x1.040).
%
% The floor of 1 is applied only where the inversion can happen - the automatic
% reference.  With a numeric --ref the caller has stated the assumption the ratio
% is built on, so a fixed conversion that goes down stays allowed, and --pitch /
% --ratio / --target are instructions that are honoured exactly.  --allow-down
% removes the floor when the caller really wants the raw result.
hasRatio = ismember('ratio', specified) || ~isempty(s.ratio);
hasPitch = ismember('pitch', specified) || ~isempty(s.pitch);
hasTarget = ismember('target', specified) || ~isempty(s.target);
if isfield(s, 'allow_down') && ~isempty(s.allow_down) && ...
        (islogical(s.allow_down) || isnumeric(s.allow_down)) && s.allow_down
    cfg.allowDown = true;                      % --allow-down
end
if autoRef && ~cfg.allowDown && ~hasRatio && ~hasPitch && ~hasTarget && ...
        cfg.pitchRatio < 1
    cfg.pitchRatio = 1;
    cfg.pitchDownLimited = true;
end
r = cfg.pitchRatio;

% Formant factor.  DEFAULT IS FIXED: the child presets use their design factor
% (1.15 / 1.18 / 1.22) unchanged, no matter what the automatic reference did to the
% pitch ratio, because that factor is a vocal tract shape and the pitch already
% carries the perceived age.  --formant-track opts in to scaling it with the
% pitch factor:
%
%     formant = formant0 * (r / r0)^damping        clamped to [min, max]
%
% damping 1 means the vocal tract follows the pitch exactly; 0 reproduces the
% default fixed behaviour.  The clamp keeps the result inside the range a real
% child's vocal tract can produce (roughly 15..35 % shorter than an adult's).
%
% WHY FIXED IS THE DEFAULT - it is not a numerical preference but a stability one:
% the tracking test compares the RAW pitch ratio against the preset's design ratio
% r0, and that comparison has almost no margin on real speech.  Measured on a
% 138 s male recording (detected F0 148.2 Hz, raw ratio 1.5856, preset r0 1.5667,
% i.e. only +1.2 % above the threshold) the ratio computed over 4 s windows ranged
% 1.068..1.785 with 2 of 5 windows above r0, so the factor flipped between the
% design value and the 1.30 clamp (F1 854 vs 910 Hz) depending on the window and
% the run.  Where tracking did engage it moved the factor 1.220 -> 1.235, i.e.
% 1.2 %, for 0.26..0.43 dB of band energy - inaudible next to the phase
% vocoder's own colouration, and paid for with a run-to-run decision that can
% change the result.  The fixed factor has no decision to get wrong; it also
% removes one place where the formant stage and the pitch stage could disagree.
% Details and the full measurement are in the FORMANTS header block.
trackWanted = false;
if isfield(s, 'formant_track') && ~isempty(s.formant_track)
    v = s.formant_track;
    if ischar(v) || isstring(v)
        trackWanted = any(strcmpi(char(string(v)), {'on', 'true', '1', 'yes'}));
    elseif islogical(v) || isnumeric(v)
        trackWanted = logical(v);
    end
end
if isfield(s, 'no_formant_track') && ~isempty(s.no_formant_track)
    v = s.no_formant_track;
    noTrack = false;
    if ischar(v) || isstring(v)
        noTrack = any(strcmpi(char(string(v)), {'on', 'true', '1', 'yes'}));
    elseif islogical(v) || isnumeric(v)
        noTrack = logical(v);
    end
    if noTrack
        % kept so old command lines ("--no-formant-track") still parse and mean
        % what they always meant; it is now the default, so it is a no-op
        if trackWanted
            % Contradictory request.  --formant-track wins because it is the only
            % one of the two that asks for something other than the default; the
            % warning exists so the run is not silently surprising.
            warning('voice_changer:formantTrack', ...
                    ['--formant-track and --no-formant-track both given; ' ...
                     '--formant-track wins']);
        end
        trackWanted = false;
    end
end
formantArgGiven = ismember('formant', specified) || ~isempty(s.formant);

cfg.formantTrack = false;
cfg.formantMin   = 1.00;
cfg.formantMax   = 1.30;
cfg.formantDamp  = 1;
if formantArgGiven
    % an explicit --formant always wins, tracking or not
    cfg.formant = getnum(s.formant);
elseif isfield(pp, 'formant0') && ~isempty(pp.formant0)
    if trackWanted && abs(pp.pitch0) > 0 && cfg.pitchRawRatio >= abs(pp.pitch0)
        ftr = pp.formant0 * (cfg.pitchRawRatio / abs(pp.pitch0)) ^ cfg.formantDamp;
        cfg.formant = max(cfg.formantMin, min(cfg.formantMax, ftr));
        cfg.formantTrack = true;
    else
        cfg.formant = pp.formant0;             % the default: fixed design factor
    end
end

if isempty(cfg.formant)
    cfg.formant = r;
end
Fratio = max(0.4, min(2.2, cfg.formant));

% ------------------------------------------------------------- processing
tP = tic;

% (1) spectral analysis of the source: magnitude + cepstral envelope
% The lifter length matters: 2.5 ms (the old fixed value) smoothed F2/F3 away
% entirely, which left the formant stage with nothing to act on.  See VC_ENV.
env_lift = 12;                                  % ms
if isfield(s, 'env_lifter') && ~isempty(s.env_lifter)
    env_lift = getnum(s.env_lifter);
end
[env0, ~] = vc_env(x, 2048, env_lift);

% (2) pitch conversion: phase-vocoder stretch + band-limited resampling
y = vc_pitchshift_pv(x, r, cfg.nfft, cfg.hop, cfg.phaseLock);
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
% til_oct is applied as given.  It used to be  cfg.tilt - 20*log10(r), a
% compensation for the way the pitch stage moves every formant: with r = 1.567
% that made the effective tilt -3.9 dB/oct darker than requested, which measured
% 35..39 % too dark on real speech (energy spectral centroid 0.83 of the
% pitch-shifted signal, where 1.0 means "the formant stage does not change the
% brightness").  It was only ever hiding the broken formant map; with the map
% fixed, the stage is brightness neutral at tilt = 0 (measured 0.97..1.03 across
% the four presets), so the compensation is gone and --tilt means dB/oct.
til_oct = cfg.tilt;
% The mask carries a rumble shelf and a level normalisation, so it is only
% applied when the spectrum is really reshaped: an identity conversion (all
% factors 1) then stays transparent instead of picking up a DC shelf.
reshape_spec = abs(Fratio - r) > 1e-9 || abs(til_oct) > 1e-12;
if reshape_spec
    fmap = 'exact';
    if isfield(s, 'formant_map') && ~isempty(s.formant_map)
        fmap = lower(char(string(s.formant_map)));
        if ~any(strcmp(fmap, {'exact', 'legacy'}))
            error('voice_changer:formantmap', ...
                  'unknown --formant-map "%s" (use exact | legacy)', fmap);
        end
    end
    gain = vc_mask(env0, Fratio / r, til_oct, 10 ^ (-12 / 20), 2048, fs / 2, true, fmap);
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
% THE DEFAULT IS TO MATCH THE INPUT RMS, not a fixed target.  A voice changer's
% job is to change the voice, not the loudness: an A/B comparison where one side
% is 5 dB quieter reads as "worse" no matter how good the conversion is, and the
% difference is loudness, not quality.  The previous rule normalised to a FIXED
% -18 dBFS, so the output level followed the setting rather than the input.
%
% The peak ceiling is the one thing that can override it.  Measured on the
% project's 139 s male test recording: input RMS 0.1510, peak 1.000.  Matching
% that RMS with the default -18 dBFS ceiling (0.126) applies -1.6 dB and the
% output lands at RMS 0.126 / peak 0.835.  Without a ceiling the output would
% peak at 1.07 and clip, so the ceiling is kept and the report says when it
% bound.  Pass --target-level to set it explicitly; it is now a CEILING, so a
% quiet input is no longer boosted up to it.
rms_in = sqrt(mean(x .^ 2));
level_knee = NaN;  level_ratio = 1;
if cfg.normalize
    cu = sqrt(mean(y .^ 2));
    if cu > 1e-9
        y = y * (rms_in / cu);                    % match the input loudness
        % THE CEILING MUST NOT SCALE THE WHOLE FILE.  Measured: the converted
        % signal can carry a single sample at 2.45x the RMS-target scale (crest
        % 24.5 dB, at 42.27 s of the 139 s test file).  Scaling everything down
        % to fit that one sample cut the output by 19 dB and produced
        % RMS 0.151 -> 0.0075, i.e. the level rule defeated by one outlier.  A
        % soft knee above 0.9 leaves everything below it bit-identical and
        % rounds off only what would have clipped.
        pk = max(abs(y));
        if pk > ceil_lin
            level_knee = min(L_KNEELIN, ceil_lin);
            y = softclip(y, level_knee);
        end
        rms_out = sqrt(mean(y .^ 2));
        if rms_in > 1e-9
            level_ratio = rms_out / rms_in;
        end
    else
        rms_out = 0;
    end
else
    rms_out = sqrt(mean(y .^ 2));
    if rms_in > 1e-9
        level_ratio = NaN;                        % nothing was targeted
    end
end
% Hard safety clamp.  Only reachable with --no-normalize or a signal that was
% already over full scale: with normalisation on, the block above has already
% brought the peak to the ceiling.
pk = max(abs(y));
if pk > 1
    y = y / pk;
end
y = min(max(y, -1), 1);
tProcess = toc(tP);

% ------------------------------------------------------------- output
% THE FREE-RUNNING ESTIMATE IS REPLACED BY A NARROW-BAND SEARCH.  Re-analysing
% the result with the tracker's normal band gives numbers that are wrong more
% often than right on converted audio: measured on the project's test recording,
% the SAME child conversion reads 177.7 / 190.9 / 287.4 / 347.7 Hz depending on
% the search band, against a designed output near 210-235 Hz.
%
% What is done instead: search with the band centred on the value this
% conversion must have produced (r * measured input F0) and only +-6 % wide, and
% report that answer.  A narrow band makes the answer stable - measured across
% +-12 %, +-6 % and +-3 % bands the three answers agree within a few percent on
% the real recording and on synthetic vowels, while the free-running answer moved
% by a factor of two - at the cost of assuming the expected value is roughly
% right.  The uncertainty statement in the report says exactly that.
%
% THIS IS NOT INDEPENDENT VERIFICATION and the report does not claim it is: the
% band is derived from the same tracker that then looks inside it.  It is a
% statement that the waveform does contain the periodicity the conversion asked
% for, which the free-running search was failing to report.
%
% THE OBVIOUS FIXES FOR THE ARTIFACT WERE TESTED AND DO NOT WORK; do not spend
% time re-running them.  Measured on a controlled harmonic vowel at ratio 1.417:
%   * forcing hop_out onto an integer grid: -66.7 dB against -67.8 dB for the
%     fractional value, i.e. no change (and a half-sample offset made it worse);
%   * adding +-0.5*pi of random phase per frame per bin: -28.6 dB against
%     -28.7 dB, no change, at the cost of a slightly lower output RMS.
% Stage isolation puts the artifact in VC_PITCHSHIFT_PV itself: the STFT/ISTFT
% round trip leaves -90 dB and the resampler -90..-125 dB, while the pitch shift
% leaves -28..-48 dB at the frame-rate family (86/172/258/344 Hz for hop 256).
% That is the phase vocoder's loss of vertical coherence between partials, and
% the documented mitigation is phase locking (identity phase locking around
% spectral peaks) - a substantial algorithmic change that was attempted once
% before and rejected for breaking the output level, so it needs its own session.
% Two ways of judging the F0 estimate were also tried and FAILED, and they are
% written up here so they are not re-attempted: BAND STABILITY (re-analysis with
% a wider band) gave a 4.49 relative spread on a clean synthetic 120 Hz vowel
% against 0.006 on a converted signal whose answer was 67 % wrong, so it
% describes the difference function rather than the answer; and HARMONIC-COMB
% SUPPORT scored every candidate within 0.6 dB of every other, while the product
% -spectrum variant was worse still - it read a clean 120 Hz vowel as 110 Hz.
f0_expected = r * A0.f0;
f0_measured = NaN;
f0_reliable = false;
if isfinite(f0_expected) && f0_expected > 0
    Ac = vc_analyze(y, fs, 0.94 * f0_expected, 1.06 * f0_expected);
    if isfinite(Ac.f0)
        f0_measured = Ac.f0;
        f0_reliable = true;
    end
end
if f0_reliable
    f0_1 = f0_measured;
else
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
    'rms_in', rms_in, 'rms_out', rms_out, ...
    'level_ratio', level_ratio, 'level_knee', level_knee, ...
    'level_ceiling_db', ceil_lin, ...
    'f0_expected', f0_expected, 'f0_measured', f0_measured, ...
    'f0_reliable', f0_reliable, ...
    'formant_scale_applied', Fratio / r, 'tilt_db_oct', cfg.tilt, ...
    'tremor_pct', cfg.tremor, 'breath_pct', cfg.breath, ...
    'target_f0', NaN, 'pitch_ref', cfg.pitchRef, 'outfile', outName, ...
    'max_f0', cfg.maxF0, 'pitch_capped', cfg.pitchCapped, ...
    'pitch_asked', cfg.pitchAsked, ...
    'pitch_down_limited', cfg.pitchDownLimited, 'allow_down', cfg.allowDown, ...
    'pitch_raw_ratio', cfg.pitchRawRatio, ...
    'ratio_max', cfg.ratioMax, 'ratio_capped', cfg.ratioCapped, ...
    'formant_tracked', cfg.formantTrack, 'phase_locked', cfg.phaseLock, ...
    'time_analyze', tAnalyze, 'time_process', tProcess, 'time_total', toc(t_all));
if strcmp(cfg.pitchMode, 'abs')
    info.target_f0 = cfg.pitchTarget;
end

if ~args.quiet
    print_report(info, inName, A0, args);
end
end

% ======================================================================
function fs = array_fs(c)
%ARRAY_FS  Sample rate supplied alongside a numeric input array.
%   Two accepted forms, both resolved from the raw argument list because the
%   option parser deliberately drops stray numeric tokens:
%       voice_changer(x, fs, ...)          second argument, before any option
%       voice_changer(x, '--fs', fs, ...)  as an option
fs = [];
if nargin < 1 || isempty(c) || ~iscell(c)
    return
end
if numel(c) >= 2 && isnumeric(c{2}) && isscalar(c{2}) && c{2} > 0
    fs = c{2};
    return
end
for k = 1:(numel(c) - 1)
    if ischar(c{k}) && strcmpi(strrep(c{k}, '-', ''), 'fs') && ...
            isnumeric(c{k + 1}) && isscalar(c{k + 1}) && c{k + 1} > 0
        fs = c{k + 1};
        return
    end
end
end

% ======================================================================
function [x, fs, name] = load_audio(in, varargin)
%LOAD_AUDIO  Accept a numeric signal or a file name and normalise the result.
%   An array input carries no sample rate, so an optional second argument (or
%   the --fs option) supplies it; a file name is read with audioread, which
%   reports the rate itself.
name = '';
if isnumeric(in) || islogical(in)
    x = double(in);
    % An array carries no sample rate, so it has to be given explicitly:
    %   voice_changer(x, fs, ...)          positional, like audioread
    %   voice_changer(x, '--fs', fs, ...)  as an option
    % Getting this wrong is silent and fatal - a 44.1 kHz recording treated as
    % 16 kHz comes out with every frequency 2.76x off, so the pitch conversion
    % is applied to the wrong part of the spectrum.
    if nargin >= 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} > 0
        fs = varargin{1};
    else
        fs = 16000;
    end
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
fprintf('  analysis : %s, voiced %4.0f%%, centroid %5.0f Hz, %.1f ms\n', ...
        f0_text(A0.f0, [], true), 100 * A0.voiced, A0.cent, 1000 * info.time_analyze);
if isfinite(info.target_f0)
    fprintf('  pitch    : F0 x%.3f  (target %.0f Hz)%s  ->  %s\n', ...
            info.pitch_ratio, info.target_f0, capnote(info), ...
            f0_text(info.f0_out, info, false));
else
    fprintf('  pitch    : F0 x%.3f%s  ->  %s\n', ...
            info.pitch_ratio, capnote(info), f0_text(info.f0_out, info, false));
end
fprintf('  formant  : final x%.3f (%s, envelope scaled x%.3f before the pitch shift)\n', ...
        info.formant_ratio, tracknote(info), info.formant_scale_applied);
fprintf('  tilt     : %+.2f dB/oct     tremor: %.2f%%     breath: %.2f%%\n', ...
        info.tilt_db_oct, info.tremor_pct, info.breath_pct);
if isfield(info, 'phase_locked') && ~info.phase_locked
    fprintf('  lock     : OFF (--no-phase-lock: plain per-bin phase recursion)\n');
end
fprintf('  level    : RMS %.4f -> %.4f%s\n', info.rms_in, info.rms_out, levelnote(info));
fprintf('  timing   : total %.0f ms  (analysis %.0f ms + processing %.0f ms)  fs=%g Hz, %.2f s audio\n', ...
        1000 * info.time_total, 1000 * info.time_analyze, 1000 * info.time_process, ...
        info.fs, info.n / info.fs);
% NOTE: there used to be a "this run exceeded the 1 s budget" warning here.
% It is gone on purpose (see the timing note in the header of this file): the
% 1 s figure was a development guard against accidental non-termination, not a
% requirement, and legitimate work scales with the number of samples - a 30 s
% file at 44.1 kHz does about 3x the work of the same file at 16 kHz.  The
% measured times are still printed above so a regression is still visible.
if ~isempty(info.outfile)
    fprintf('  written  : %s\n', info.outfile);
end
if args.plot
    plot_report(inName, info);
end
fprintf('\n');
end

function s = capnote(info)
%CAPNOTE  "" or " [capped at N Hz]" / " [direction limited]" for the pitch line.
%   The direction note is the visible half of the guard that stops a child preset
%   from lowering the pitch: without it a run that was silently converted from
%   x0.873 to x1.000 would look like the target had simply been missed.
if isfield(info, 'pitch_down_limited') && info.pitch_down_limited
    s = '  [direction limited: a child''s F0 is not lower than the input; --allow-down removes this]';
elseif isfield(info, 'pitch_capped') && info.pitch_capped && isfield(info, 'max_f0') ...
        && ~isempty(info.max_f0)
    s = sprintf('  [capped at %.0f Hz]', info.max_f0);
else
    s = '';
end
end

% ======================================================================
function y = softclip(y, knee)
%SOFTCLIP  Rounds off samples above KNEE instead of scaling or hard clipping.
%   Below the knee the signal is unchanged sample for sample, so the RMS match
%   is preserved; above it the excess is compressed into the remaining headroom,
%   continuously in value and slope at the knee (no audible corner), and the
%   result cannot leave [-1, 1].  Scaling the whole file down would have been
%   simpler but lets one outlier decide the loudness of everything.
if knee <= 0 || knee >= 1
    return
end
a = abs(y);
m = a > knee;
if ~any(m)
    return
end
room = 1 - knee;
y(m) = sign(y(m)) .* (knee + room * tanh((a(m) - knee) / room));
end

% ======================================================================
function s = levelnote(info)
%LEVELNOTE  Says what the level rule actually achieved.
%   The default is to match the input RMS so that an A/B comparison is not
%   decided by a loudness difference.  A verdict ("matched" / "given up") hides
%   how close it got, so the ratio is reported instead: it is 1.000 when nothing
%   was in the way, and slightly under 1 when peaks had to be softened.
if ~isfield(info, 'level_ratio') || ~isfinite(info.level_ratio)
    s = '  [--no-normalize: level left as converted]';
    return
end
s = sprintf('  [target = input RMS, achieved x%.3f', info.level_ratio);
if isfield(info, 'level_knee') && isfinite(info.level_knee)
    s = [s sprintf(', peak held at %.3f by a soft knee from %.2f', ...
        info.level_ceiling_db, info.level_knee)];
end
s = [s ']'];
end

function s = f0_text(f0, info, isInput)
%F0_TEXT  How a measured F0, or the absence of one, is worded in the report.
%   The conversion factors are exact by construction, so when the tracker cannot
%   confirm the designed output the useful thing to print is the DESIGNED value -
%   with a clear statement that it was not independently verified.  The message
%   used to claim the tracker had "locked onto a higher harmonic"; that was never
%   verified and the measurements do not support it (the answers scatter, they do
%   not sit on a harmonic).  What is certain is that the confirmation search
%   found nothing in the band where the output must be.
if isfinite(f0)
    s = sprintf('F0 = %.1f Hz  (narrow-band estimate, +-6 %%; see VC_ANALYZE)', f0);
    return
end
if isInput
    s = 'F0 not measurable (no frame passed the voicing test)';
    return
end
exp_ = NaN;
if nargin >= 2 && isstruct(info) && isfield(info, 'f0_expected')
    exp_ = info.f0_expected;
end
if isfinite(exp_)
    s = sprintf(['F0 = %.0f Hz by construction (x%.3f of %.1f Hz); no periodicity ' ...
        'found where it should be - see VC_ANALYZE'], exp_, info.pitch_ratio, info.f0_in);
else
    s = 'F0 not verifiable (no usable estimate of the input F0 either)';
end
end

function s = tracknote(info)
%TRACKNOTE  Says which formant behaviour produced the factor in the report.
%   "fixed" is the default (the preset's design factor); "tracked" only appears
%   when --formant-track actually engaged, so a run that used the experimental
%   mode is never mistaken for a default one.
if isfield(info, 'formant_tracked') && info.formant_tracked
    s = 'tracked with the pitch';
else
    s = 'fixed';
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
    'presets: child | child_bright | child_female | elder | elder_male | elder_female | normal\n' ...
    'options: --pitch <semitones>  --target <Hz>  --ratio <r>  --ref <Hz|auto>\n' ...
    '         --max-f0 <Hz>  --ratio-max <r>  --allow-down\n' ...
    '         --formant <r>  --formant-track  --tilt <dB/oct>  --tremor <pct>\n' ...
    '         --rate <Hz>  --breath <pct>  --fs <Hz>  --nfft <n>  --hop <n>\n' ...
    '         --target-level <dBFS>  --no-normalize  --no-phase-lock\n' ...
    '         --plot  --quiet\n' ...
    '\n' ...
    'conversion = pitch shift (phase vocoder, phase-locked by default)\n' ...
    '             + formant warp (cepstral envelope)\n' ...
    '             + spectral tilt + elderly tremor/breathiness\n' ...
    'the child presets never LOWER the fundamental (--allow-down lifts that)\n']);
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

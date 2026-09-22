function y = vc_pitchshift_pv(x, ratio, nfft, hop, phaselock)
%VC_PITCHSHIFT_PV  Phase vocoder pitch shifter (duration preserving).
%
%   Y = VC_PITCHSHIFT_PV(X, RATIO, NFFT, HOP, PHASELOCK) shifts the fundamental
%   by the factor RATIO while keeping the original length:
%
%       1) analysis STFT with hop HOP (full, NFFT-row spectrum),
%       2) phase-vocoder time stretch by RATIO  (hop_out = HOP*RATIO),
%       3) band-limited resampling by 1/RATIO  -> pitch up, duration restored.
%
%   The two time-scale operations cancel exactly (RATIO then 1/RATIO), so the
%   output has numel(X) samples while the whole spectrum - formants included -
%   has been scaled by RATIO; the caller compensates that with a formant
%   correction filter.
%
%   DIRECTION (this was wrong once, and the symptom is easy to misread): the
%   stretch must be by RATIO and the resampling by 1/RATIO.  vc_resample maps
%   output sample i to input position i*RATIO, so a factor > 1 there SHORTENS
%   the signal.  Passing RATIO to both stages squares the conversion: a 5 s
%   file then came out 2.24x too fast at RATIO = 1.567, and at RATIO = 0.866
%   the resampled signal was too short to fill the output, so its tail was
%   silence.
%
%   PHASE RECURSION.  Bin k of an NFFT-point DFT has centre frequency
%   omega_k = 2*pi*min(k, NFFT-k)/NFFT, so its phase advances by omega_k*hop per
%   analysis frame.  The measured advance is wrapped, so the deviation from the
%   centre is unwrapped into [-pi, pi] before it can be used as a frequency:
%
%       dphi_k(m) = wrap(angle_k(m) - angle_k(m-1) - omega_k*hop)
%       angle_k(m) = angle_k(m-1) + omega_k*hop_out + dphi_k(m)
%
%   Measured accuracy of this implementation on pure tones (peak-frequency
%   error of the output): <= 0.4 % for 500 Hz and 1 kHz over ratios 0.87..2.0,
%   and <= 3 % at 200 Hz, where the partials fall between FFT bins.  That is
%   well inside what a voice conversion needs (the smallest preset step is
%   ~1.3 semitones = 7 %).  Peak-based phase locking was tried as an
%   improvement and rejected: it multiplied the output level by ~100x on an
%   identity test, i.e. it was not phase coherent.
%
%   The recursion is evaluated as one cumulative sum over frames (each wrapped
%   increment differs from the unwrapped one by a multiple of 2*pi, so the
%   cumulative sum is exact for a stationary sinusoid), which removes the frame
%   loop entirely.

%   IDENTITY PHASE LOCKING (the PHASELOCK argument), ON BY DEFAULT.
%
%   WHAT IT IS FOR.  Advancing every bin independently destroys the phase
%   RELATIONSHIP between the partials of one frame - the phase vocoder's loss of
%   "vertical coherence" - and that is heard as the smeared, metallic quality
%   this project has been complaining about since its first listening tests.  It
%   is NOT mainly a loss of harmonics: measured here, the harmonic share of the
%   energy only falls from -0.24 dB to -1.44 dB while the "metal" complaint is
%   severe.  The partials are still there; they wander.
%
%   The fix is the standard one (Laroche & Dolson, ICMC-1997 eq. 8, "Phase-vocoder:
%   about this phasiness business"): keep the bins of a region phase-locked to
%   the region's spectral peak,
%       angle_Y(m,k) = angle_Y(m,p) + angle_X(m,k) - angle_X(m,p)
%   so the peak's phase ROTATION is shared while each bin keeps its analysis
%   phase.  Regions are Voronoi around peaks found with the paper's 4-neighbour
%   rule; the peak's own phase tracks its own frequency through the ordinary PV
%   recursion driven by the ANALYSIS phase.
%
%   WHY IT IS THE DEFAULT (listening, not metrics).  A/B renders of the elder and
%   child presets on a real recording were judged clearly better with the lock on
%   - a large reduction in metallic character.  The objective metrics did NOT
%   show it, and the reason matters for anyone revisiting this:
%     * frame-rate artifact lines DO drop a lot on a controlled vowel (0.5/1.0/
%       1.5/2.0 x frame rate: -40/-45/-27/-44 dB -> -88/-91/-73/-56 dB) but on
%       real speech they move around rather than vanish;
%     * harmonic-to-noise ratio gets WORSE (+4.5 -> -0.7 dB), because the metric
%       counts everything off the harmonic grid as noise and cannot tell
%       concentrated artifact lines (small energy, very audible) from diffuse
%       phase smearing (larger energy, much less audible);
%     * per-partial phase wandering - the metric that DOES correspond to phasiness
%       - falls 2.3x on a synthetic vowel (median sd 8.78 -> 3.85 Hz, coherence
%       0.950 -> 0.991) but on real speech it is swamped by the signal's own pitch
%       movement (median sd 20..40 Hz either way), so it cannot confirm the
%       improvement there.
%   Five physical metrics were tried and none reproduced the listening verdict.
%   If you are here to re-litigate the default, listen first.
%
%   WHAT IT COSTS.  Frequency accuracy: on the controlled vowel the locked output
%   places partials up to 39 Hz from k*f0*ratio where the unlocked one stays
%   within 8 Hz.  That was measured while the implementation still had the
%   region-assignment bugs listed below, so it is an upper bound, not a promise;
%   the listening tests did not find the result detuned.
%
%   Bugs found on the way, each producing valid-looking audio that was merely
%   worse, and each invisible without a metric or an ear:
%     * a self-contradictory peak test (symmetric "greater than both neighbours"
%       against padding that duplicated the ends) matched nothing, so the lock
%       was a silent no-op and the output was bit-identical to unlocked;
%     * regions from record maxima of the magnitude, which is monotone by
%       construction, so one region spanned several partials and collapsed them;
%     * sharing the peak's ADVANCE instead of its ROTATION, which rotates the
%       intra-region relation by |k-p|*2*pi*hop_out/N per frame;
%     * a per-bin drift clamp, which clips two bins of one region differently and
%       breaks the relation the lock exists to preserve (made a per-region clamp);
%     * driving the peak's recursion from the SYNTHESIS phase instead of the
%       analysis phase, which makes the rotation circular;
%     * a peak-frequency claim blamed on "resolution": the estimate is in fact
%       accurate to <1 Hz (100 % of estimates within 5 Hz of a true partial, the
%       fundamental at 148.51 Hz against a true 148.50), so raising nfft would
%       have fixed nothing.
%
%   Two cheaper fixes for the same artifact were tried and do NOT work; they are
%   recorded in README section 7 (forcing hop_out onto an integer grid, and random
%   phase per frame).

x = x(:);
n = numel(x);
ratio = max(0.25, min(4, ratio));

if nargin < 3 || isempty(nfft), nfft = 512;       end
if nargin < 4 || isempty(hop),  hop  = nfft / 4;   end
% Default ON: see the note above.  VOICE_CHANGER passes its own switch, so
% --no-phase-lock reaches this argument as false.
if nargin < 5 || isempty(phaselock), phaselock = true; end
hop = max(1, round(hop));

if abs(ratio - 1) < 1e-6 || n < nfft + hop         % nothing to do / too short
    y = x;
    return
end

[M, P, win] = vc_stft(x, nfft, hop);
% Time stretch by RATIO (longer for RATIO > 1) ...
stretch = ratio;
hop_out = hop * stretch;
nout_stretch = round(n * stretch);

% ---------------------------------------------------------- phase propagation
kb = (0:(nfft - 1)).';                             % full spectrum: 0..NFFT-1
omega = 2 * pi * min(kb, nfft - kb) / nfft;        % symmetric bin frequencies

dphi = diff(P, 1, 2) - omega * hop;                % deviation from the bin centre
dphi = dphi - 2 * pi * round(dphi / (2 * pi));     % wrap to [-pi, pi]

if phaselock
    % Identity phase locking builds the synthesis phase itself (see LOCK_PHASE
    % for why rewriting the advance alone is not enough).  The ANALYSIS phase
    % must survive as its own copy: P is overwritten in place frame by frame, so
    % by the time a later frame is locked, P(:,m-1) is no longer the analysis
    % phase - and eq. (8) is defined in terms of the analysis phase.
    Xang = P;
    P = lock_phase(M, P, Xang, omega, hop, hop_out, nfft);
else
    P(:, 2:end) = P(:, 1) + cumsum(omega * hop_out + dphi, 2);
end

ys = vc_istft(M, P, win, hop_out, nout_stretch);
% ... then compress the duration back, which raises the pitch by RATIO.
% vc_resample maps output sample i to source position i*K, so for the n output
% samples to span the whole stretched signal (length n*RATIO) the factor has to
% be K = RATIO, not 1/RATIO.  With K = 1/RATIO the resampler reads only the
% first 1/RATIO of the stretched signal and time-expands that fragment instead,
% which is how a 5 s file ended up 2.4x too fast with its tail silent.
% (Verified with a ramp: the output only spans the full source iff K*n = length.)
y = vc_resample(ys, ratio, n);
y = y(:);
end
% ======================================================================
function P = lock_phase(M, P, Xang, omega, hop, hop_out, nfft)
%LOCK_PHASE  Identity phase locking: one phase rotation per spectral region.
%
%   P = LOCK_PHASE(M, P, XANG, OMEGA, HOP, HOP_OUT, NFFT) returns the synthesis
%   phase for the time-stretched signal.  M is the magnitude, XANG the ANALYSIS
%   phase (a copy the caller keeps untouched - P itself is overwritten frame by
%   frame and cannot serve as the analysis reference), OMEGA the bin centre
%   frequencies, HOP the analysis hop and HOP_OUT = HOP*ratio the synthesis hop.
%
%   WHY THE PHASE IS REBUILT RATHER THAN THE ADVANCE REWRITTEN.  The unlocked
%   recursion is
%       phase(:,m) = phase(:,m-1) + omega*hop_out + dphi(:,m)
%   and omega*hop_out + dphi is that bin's own phase advance over the synthesis
%   hop.  Sharing that advance across a region is NOT sufficient: the phase
%   RELATIONSHIP between two bins has to be carried from the ANALYSIS frame,
%       phase_k(m+1) - phase_j(m+1) = phase_k(m) - phase_j(m)
%                                 + (omega_k - omega_j) * hop_out
%   and rewriting the advance throws the analysis-phase term away, re-deriving
%   every frame from frame 1.  Measured cost of getting this wrong: the artifact
%   improved a uniform 3.2 dB but the harmonic-to-noise ratio LOST 0.5 dB on the
%   child preset and 4.9 dB on the elder one - the harmonics were being smeared,
%   which is the opposite of the point.
%
%   Regions are delimited by record maxima of the magnitude spectrum: the
%   strongest bin seen so far in the frame, "the loudest thing to my left, or me
%   if I am louder".  That is the Laroche & Dolson rule - a weak bin between two
%   partials follows the louder of the two rather than the nearer one - so a
%   region does not split at a shallow valley.  Only the harmonic half
%   (bins 2..nfft/2+1) is touched: bin 1 (DC) and the Nyquist bin are real in a
%   real-input STFT, so they carry no phase to lock.
%
%   Fallbacks, both deliberate: a frame with no peak above the threshold keeps
%   the plain unlocked recursion, and a bin whose region has no peak keeps its
%   own advance.  Without them, unvoiced and silent stretches get locked onto
%   partials they do not belong to, which is exactly where frame-rate lines
%   become audible.

peakthr = 0.03;                      % a peak must reach 3 % of the frame maximum
lo = 2;                              % first bin with a meaningful phase
hi = nfft / 2 + 1;                   % Nyquist bin, excluded
if hi - lo < 2
    return
end

% Local maxima of the magnitude spectrum, and above peakthr so that noise-floor
% ripples do not anchor real bins to numerically random rotations (the timestretch
% implementation notes exactly this failure).  The peak test uses TWO neighbours
% on each side, which is the definition in Laroche & Dolson 1997: "a channel whose
% amplitude is larger than its 4 nearest neighbors is said to be a peak".  An
% earlier version used one neighbour each side and, worse, in a form that was
% self-contradictory against duplicated padding - it matched nothing at all and
% the entire lock silently became a no-op (0 peaks per frame at nfft 1024, 2048
% and 4096), which is a failure mode worth remembering because the output is then
% perfectly valid, just unlocked.
seg = M(lo:hi, :);
% neighbours on each side, edges duplicated (bins outside the band cannot be
% compared, so the edge bins simply need to beat the ones that do exist)
left1  = [seg(1, :);     seg(1:end - 1, :)];
left2  = [seg(1, :);     seg(1, :);         seg(1:end - 2, :)];
right1 = [seg(2:end, :); seg(end, :)];
right2 = [seg(3:end, :); seg(end, :);       seg(end, :)];
peaks = (seg > left1) & (seg > left2) & (seg >= right1) & (seg >= right2) & ...
        (seg > peakthr * max(seg, [], 1));

rowseg = (lo:hi).';
nb = numel(rowseg);
L_MAXDEV = pi / 4;                    % drift clamp, see the note below
for m = 2:size(M, 2)
    % INDEPENDENT phase-vocoder phase: the plain per-bin recursion, for every
    % bin.  It is not the answer where a region is locked, but it stays the
    % reference those regions are clamped against (below).
    Pind = P(:, m - 1) + omega * hop_out + wrap_pi(P(:, m) - P(:, m - 1) - omega * hop);
    P(:, m) = Pind;

    keep = peaks(:, m);
    if ~any(keep)
        continue
    end
    % nearest peak BY BIN INDEX (Voronoi at the midpoint between peaks, the
    % reference rule in Laroche & Dolson 1997; the trough-bounded variant is an
    % accepted alternative but changes little here)
    pidx = find(keep);
    own = zeros(nb, 1);
    cur = 1;
    for k = 1:nb
        while cur < numel(pidx) && ...
                abs(k - pidx(cur + 1)) < abs(k - pidx(cur))
            cur = cur + 1;
        end
        own(k) = pidx(cur);
    end
    kb = rowseg;                      % every bin adopts a peak
    kp = rowseg(own);
    % A REGION MUST STOP AT THE NEXT UNDETECTED PARTIAL.  This is the bug that
    % made the lock drag partials off frequency: measured on the controlled
    % vowel, the peak detector finds only 13 of the 33 partials, and Voronoi
    % assignment - which knows nothing about the partials it never found - then
    % gives the median bin a peak 173 BINS away (harmonic spacing is 3.4 bins),
    % so 88 % of bins were locked to a peak that lies on the far side of several
    % undetected partials.  The whole spectrum was effectively being locked to a
    % handful of frequencies: partials landed up to 39 Hz from k*f0*ratio, where
    % the unlocked output stays within 8 Hz.
    % Bins further from their peak than LOCKMAX are therefore left UNLOCKED,
    % which is the reference behaviour for bins outside every region.  Note that
    % the peak FREQUENCY estimates themselves are not at fault: measured, 100 %
    % of them are within 5 Hz of a true partial and the fundamental's own
    % estimate is 148.51 Hz against a true 148.50 Hz, so better frequency
    % resolution would not have helped.
    LOCKMAX = 2;                      % bins either side of a peak that may lock
    far = abs(kb - kp) > LOCKMAX;
    if any(far)
        kb = kb(~far);
        kp = kp(~far);
    end
    if isempty(kb)
        continue
    end
    % IDENTITY PHASE LOCKING (Laroche & Dolson 1997, eq. 8):
    %     angle_Y(m,k) = angle_Y(m,p) + angle_X(m,k) - angle_X(m,p)
    % i.e. the peak's phase ROTATION is shared while each bin keeps its ANALYSIS
    % phase, so the invariant phase_k - phase_p = angle_k - angle_p holds exactly.
    % The peak's own synthesis phase tracks its own frequency with the standard
    % recursion.  An earlier version shared the peak's phase ADVANCE instead and
    % re-derived every frame from the previous one, which rotates the
    % intra-region relation by |k-p|*2*pi*hop_out/N every frame - it merged the
    % partials inside a region (harmonic energy 1.67e7 -> 1.57e7, broadband
    % noise 5.97e6 -> 1.27e7) and cost 0.5..5 dB of HNR.
    % THE PEAK'S PHASE ADVANCE COMES FROM THE ANALYSIS PHASE, NOT FROM THE
    % SYNTHESIS PHASE.  This is eq. (8) solved for the rotation:
    %     theta_p(m) = angle_Y(m,p) - angle_X(m,p)
    %     angle_Y(m,p) = angle_Y(m-1,p) + omega_p*hop_out
    %                    + wrap(angle_X(m,p) - angle_X(m-1,p) - omega_p*hop)
    % The second line is the ordinary PV recursion driving the PEAK's own phase
    % from how its analysis phase actually advanced.  An earlier version fed it
    % the difference of the synthesis phases (P(kp,m) - P(kp,m-1)), which makes
    % theta_p circular - it measures the rotation against a phase that the same
    % expression is about to overwrite - and the region then walks away from the
    % signal.  Measured symptom: the artifact is suppressed 22..114 dB but the
    % harmonic energy drops 1.8..2.5 dB and HNR with it, i.e. the partials are
    % being de-phased rather than locked.
    dphi_p = wrap_pi(Xang(kp, m) - Xang(kp, m - 1) - omega(kp) * hop);
    ph_p = P(kp, m - 1) + omega(kp) * hop_out + dphi_p;
    % locked(m,k) = angle_X(m,k) + [ph_p(m) - angle_X(m,p)], i.e. eq. (8).
    % Only the region rows (kb) take part, so every term has the same length.
    locked = wrap_pi(Xang(kb, m)) + wrap_pi(ph_p - wrap_pi(Xang(kp, m)));
    % DRIFT CLAMP - AND IT MUST BE PER REGION, NOT PER BIN.
    % Identity locking carries no absolute phase reference, so a region can in
    % principle rotate away from the independent PV phase on a long file, and
    % implementations clamp that deviation (pi/4..pi/3 rad is typical).  Clamping
    % it PER BIN is wrong: two bins of one region then get clipped by different
    % amounts, which breaks the very phase relation the lock exists to preserve -
    % measured as HNR 4.47 -> -1.15 dB while the artifact was already gone.
    % The clamp is therefore ONE rotation for the whole region, taken from the
    % peak's own deviation and applied to every bin about the peak, so the
    % intra-region relations survive it exactly.
    dev_p = wrap_pi(ph_p - Pind(kp));
    dev_p = max(-L_MAXDEV, min(L_MAXDEV, dev_p));
    P(kb, m) = locked + (dev_p - wrap_pi(ph_p - Pind(kp)));
end
end

% ======================================================================
function d = wrap_pi(d)
d = d - 2 * pi * round(d / (2 * pi));
end

function y = vc_istft(M, P, win, hop_out, nout)
%VC_ISTFT  Weighted overlap-add synthesis (inverse of VC_STFT).
%
%   Y = VC_ISTFT(M, P, WIN, HOP_OUT, NOUT) rebuilds a time signal from a
%   magnitude/phase spectrogram using windowed overlap-add and explicit
%   division by the accumulated window energy (COLA normalisation).
%
%   HOP_OUT may differ from the analysis hop; that is what turns the
%   analysis/synthesis pair into a time-scale modification.
%
%   The window-energy normalisation is guarded against a near-zero divisor: with
%   a non-integer hop_out the accumulated window energy is not constant and
%   collapses at the buffer edges, and dividing by such a value amplified single
%   samples into spikes hundreds of times larger than the signal (measured peak
%   380..1152 for a signal whose peak was 0.9, at hop_out = 256*1.567).

nfft = size(M, 1);
nf   = size(M, 2);
hop_out = max(1, round(hop_out));

L = nfft + (nf - 1) * hop_out;
acc = zeros(L, 1);
wsum = zeros(L, 1);
w = win(:);
span = (0:(nfft - 1)).';

frames = real(ifft(M .* exp(1i * P), nfft, 1));   % cosine (phase-vocoder) synthesis

for k = 1:nf
    b = 1 + (k - 1) * hop_out;
    e = b + nfft - 1;
    seg = frames(:, k) .* w;
    acc(b:e)  = acc(b:e)  + seg;
    wsum(b:e) = wsum(b:e) + w .* w;               % window energy bookkeeping
end

% Cola normalisation.  The threshold matters: with a NON-integer hop_out the
% window-energy sum is not constant, and near the buffer ends it falls off.  A
% near-zero divisor there turns a tiny synthesis value into a spike - measured
% hundreds of times the signal level (peak 380..1152 where the signal peak was
% ~0.9) for hop_out values like 256*1.567 and 512*1.567.  Requiring a healthy
% fraction of the window energy rejects those points instead of amplifying them.
wmax = max(wsum);
if wmax <= 0
    wmax = 1;
end
ok = wsum > 0.1 * wmax;
acc(ok) = acc(ok) ./ wsum(ok);
acc(~ok) = 0;

if nargin >= 5 && ~isempty(nout)
    if nout <= numel(acc)
        y = acc(1:nout);
    else
        y = [acc; zeros(nout - numel(acc), 1)];
    end
else
    y = acc;
end
end

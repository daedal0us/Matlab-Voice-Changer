function y = vc_istft(M, P, win, hop_out, nout)
%VC_ISTFT  Weighted overlap-add synthesis (inverse of VC_STFT).
%
%   Y = VC_ISTFT(M, P, WIN, HOP_OUT, NOUT) rebuilds a time signal from a
%   magnitude/phase spectrogram using windowed overlap-add and explicit
%   division by the accumulated window energy (COLA normalisation).
%
%   HOP_OUT may differ from the analysis hop; that is what turns the
%   analysis/synthesis pair into a time-scale modification.

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

ok = wsum > 1e-8;
acc(ok) = acc(ok) ./ wsum(ok);

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

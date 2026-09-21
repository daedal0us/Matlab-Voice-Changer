function y = vc_localenv(x, fs, tau_ms)
%VC_LOCALENV  Fast smoothed amplitude envelope of a signal.
%
%   Y = VC_LOCALENV(X, FS, TAU_MS) returns the envelope of |X| smoothed over a
%   window of TAU_MS milliseconds.  The smoothing is done by reshaping the
%   signal into a block matrix and averaging over the block dimension, which
%   is far cheaper than a sliding convolution.

x = abs(double(x(:)));
n = numel(x);
if n == 0
    y = x;
    return
end
if nargin < 3 || isempty(tau_ms), tau_ms = 20; end

b = max(1, round(fs * tau_ms / 1000));
if b > n
    y = repmat(mean(x), n, 1);
    return
end
mb = floor(n / b);
e = mean(reshape(x(1:mb * b), b, mb), 1);      % block means
e = e(:);
y = interp1(((0:(mb - 1)).' + 0.5) * b, e, (1:n).', 'linear', 'extrap');
y = max(y, 0);
end

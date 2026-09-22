function app_check
%APP_CHECK  Fast structural check of voice_changer_app: code analyzer, object
%   construction, widget layout, and the display-envelope arithmetic.
%
%   Deliberately does NOT touch the converter: the slow, interactive path is
%   what the user tests by hand.  This only proves the app builds and that the
%   numbers behind the plot are right.
%
%   Run:  matlab -batch "app_check"

here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
addpath(here);
ok = true;

fprintf('\n=== app_check ===\n\n');

%% 1. code analyzer -----------------------------------------------------
msgs = checkcode(fullfile(here, 'voice_changer_app.m'), '-struct');
errs = msgs(arrayfun(@(s) ~isempty(strfind(lower(s.message), 'error')), msgs));
fprintf('checkcode: %d message(s)\n', numel(msgs));
for k = 1:numel(msgs)
    fprintf('  L%-4d %s\n', msgs(k).line, msgs(k).message);
end
if ~isempty(errs)
    ok = false;
    fprintf('  -> these look like real errors\n');
end

%% 2. construct and inspect the layout ---------------------------------
app = voice_changer_app;
fprintf('\nconstructed. pool ready: %d\n', app.isPoolReady());

g = app.Grid;
fprintf('grid: %d rows x %d cols\n', numel(g.RowHeight), numel(g.ColumnWidth));
names = {'PresetDrop','OpenButton','OutField','BrowseButton','Ax', ...
         'ProcessButton','PlayAButton','PlayBButton','StatusLabel'};
for k = 1:numel(names)
    c = app.(names{k});
    L = c.Layout;
    fprintf('  %-13s row %d  col %-6s %s\n', names{k}, L.Row, ...
        mat2str(L.Column), class(c));
end

% The row/column map the layout intends.  Anything else means a control moved.
want = struct('PresetDrop', [2 1], 'OpenButton', [2 3], 'OutField', [3 3], ...
              'BrowseButton', [3 4], 'Ax', [5 4], 'ProcessButton', [6 4], ...
              'PlayAButton', [7 2], 'PlayBButton', [7 4], 'StatusLabel', [8 4]);
for k = 1:numel(names)
    L = app.(names{k}).Layout;
    w = want.(names{k});
    if L.Row ~= w(1) || L.Column(end) ~= w(2)
        ok = false;
        fprintf('  !! %s is at row %d col %d, expected row %d col %d\n', ...
            names{k}, L.Row, L.Column(end), w(1), w(2));
    end
end

%% 2b. clutter check: is anything hidden UNDER another widget? -----------
% The exported screenshot shows NO preset dropdown in the top-left cell, even
% though the Layout claims it is there.  Two widgets in one cell stack on top of
% each other, and nothing in Layout reports it, so compare the occupied cells.
cells = struct();
for k = 1:numel(names)
    L = app.(names{k}).Layout;
    key = sprintf('r%dc%d', L.Row, L.Column(1));
    if isfield(cells, key)
        ok = false;
        fprintf('\n!! %s and %s share cell %s\n', cells.(key), names{k}, key);
    else
        cells.(key) = names{k};
    end
end
% Explicitly: the preset dropdown and the open button must not overlap.
pcol = app.PresetDrop.Layout.Column;
ocol = app.OpenButton.Layout.Column(1):app.OpenButton.Layout.Column(end);
fprintf('\npreset in column %d, open button spans %d..%d -> overlap: %d\n', ...
    pcol, ocol(1), ocol(end), any(ocol == pcol));
if any(ocol == pcol)
    ok = false;
    fprintf('  !! the open button covers the preset dropdown\n');
end

% The two labels that name the dropdown and the output field must own their
% cells too.  They are not in `names` above, so nothing else would catch a label
% landing on top of a control.
labels = findobj(app.UIFigure, 'Type', 'uilabel');
fprintf('labels: %d found\n', numel(labels));
for k = 1:numel(labels)
    if strcmp(labels(k).Text, app.StatusLabel.Text)
        continue                          % the status label was checked above
    end
    L = labels(k).Layout;
    if isempty(L.Row)
        continue
    end
    key = sprintf('r%dc%d', L.Row, L.Column(1));
    if isfield(cells, key)
        ok = false;
        fprintf('  !! label "%s" shares cell %s with %s\n', labels(k).Text, key, cells.(key));
    end
    fprintf('  label "%-6s" row %d col %d (own cell)\n', labels(k).Text, L.Row, L.Column(1));
end

%% 2c. underscore safety: preset names must not be TeX-interpreted ---------
% 'child_female' printed into a TeX-interpreted text object renders as
% child_female with an italic SUBSCRIPT f - a real bug reported from a
% screenshot.  Two text objects print a preset name: the status label and the
% axes title, and uiaxes text defaults to TeX.  Check both, with the preset that
% actually contains an underscore.
app.PresetDrop.Value = 'child_female';
app.PresetDrop.ValueChangedFcn(app.PresetDrop, struct());
fprintf('\npreset child_female -> status "%s"\n', app.StatusLabel.Text);
fprintf('  interpreters: status "%s", axes title "%s"\n', ...
    app.StatusLabel.Interpreter, app.Ax.Title.Interpreter);
if ~strcmp(app.StatusLabel.Interpreter, 'none')
    ok = false;
    fprintf('  !! the status label is TeX-interpreted: underscores become subscripts\n');
end
if ~strcmp(app.Ax.Title.Interpreter, 'none')
    ok = false;
    fprintf('  !! the axes title is TeX-interpreted: underscores become subscripts\n');
end
if ~contains(app.StatusLabel.Text, 'child_female')
    ok = false;
    fprintf('  !! the preset name did not reach the status label literally\n');
end
app.PresetDrop.Value = 'child';
app.PresetDrop.ValueChangedFcn(app.PresetDrop, struct());

%% 2d. the output-format rule behind the 输出路径 dialog -------------------
% uiputfile reports the chosen FILTER INDEX and returns a name carrying whatever
% extension it was given, so the dialog's handler must force the extension from
% the filter.  Not doing so was the "pick MP3, then pick WAV, nothing happens"
% bug: choosing a filter changed no text because the name kept its old extension.
% The dialog itself cannot be driven from here, so the rule it relies on is
% checked directly.
cases = {'x.wav','.mp3'; 'x.mp3','.wav'; 'x','.flac'; 'x.WAV','.ogg'; ...
         'name.with.dots.wav','.mp3'; 'noext','.m4a'};
allok = true;
for k = 1:size(cases, 1)
    got = voice_changer_app.replace_ext(cases{k, 1}, cases{k, 2});
    [~, ~, had] = fileparts(cases{k, 1});
    wantname = [erase(cases{k, 1}, had) cases{k, 2}];
    if ~strcmp(got, wantname)
        allok = false;
        fprintf('  !! replace_ext("%s","%s") -> "%s", wanted "%s"\n', ...
            cases{k, 1}, cases{k, 2}, got, wantname);
    end
end
fprintf('\noutput extension rule: %d cases, format follows the dialog filter ', size(cases, 1));
fprintf('rather than the typed name: %s\n', ternary(allok, 'OK', 'CHECK'));
if ~allok
    ok = false;
end

% 原始 and 变声 must render at the same width.
% Component Position is NOT usable here: -batch has no rendered layout, so every
% widget reports its default 100 px size.  What CAN be checked is the thing that
% actually determines the width - an equal number of columns of equal width.
cA = app.PlayAButton.Layout;  cB = app.PlayBButton.Layout;
nA = numel(cA.Column(1):cA.Column(end));
nB = numel(cB.Column(1):cB.Column(end));
fprintf('\n原始 spans %d columns, 变声 spans %d columns\n', nA, nB);
if nA ~= nB || mod(cA.Column(1), 2) ~= mod(cB.Column(1), 2)
    ok = false;
    fprintf('  !! unequal spans, or offsets of different parity\n');
end
cw = app.Grid.ColumnWidth;
isfixed = cellfun(@isnumeric, cw);            % 150 (px) vs '1x' (flexible)
fprintf('column spec: %d fixed (%.0f px), %d flexible\n', ...
    sum(isfixed), sum([cw{isfixed}]), sum(~isfixed));
minw = min([cw{isfixed}]);
if minw < 150
    ok = false;
    fprintf('  !! a fixed column is narrower than the preset dropdown needs\n');
end
% Arithmetic projection at the designed window width.  Grid padding is 10 px per
% side and the default gap is 10 px, so this is an estimate, not a promise - but
% it is the projection the column spec was chosen for.
gap = 10;  pad = 20;  win = 980;
free = win - pad - sum([cw{isfixed}]) - gap * (numel(cw) - 1);
each = free / sum(~isfixed);
span = @(c) numel(c.Column(1):c.Column(end));
wopen = minw + each + gap;
fprintf('projected at %d px window: each flexible column %.0f px\n', win, each);
fprintf('projected widths : 转换 %.0f, 原始/变声 %.0f each, 打开 %.0f\n', ...
    win - pad, span(cA) * each + (span(cA) - 1) * gap, wopen);
if wopen > 0.6 * win
    ok = false;
    fprintf('  !! the open button is still a full-width banner\n');
end
fprintf('axes y limits     : [%.2f %.2f] before any file is loaded\n', ...
    app.Ax.YLim(1), app.Ax.YLim(2));
fprintf('startup title     : %s\n', app.Ax.Title.String);

%% 3. what actually lands in the axes ------------------------------------
% This is the check that was missing.  A wrong plot call is invisible to every
% structural test: the app builds, the callbacks run, a line object exists - and
% the waveform is still wrong.  An earlier version passed the envelope as the
% ONLY argument to plot(), so the x axis became the bucket index instead of
% time and the preview came out as a row of dashes.  Assert on the line's data.
src = fullfile(here, '测试1.wav');
if ~exist(src, 'file')
    cand = dir(fullfile(here, '*.wav'));
    cand = cand(~startsWith({cand.name}, 'out_') & ~startsWith({cand.name}, 'AB_'));
    if ~isempty(cand), src = fullfile(here, cand(1).name); end
end
if exist(src, 'file')
    [xd, fsd] = audioread(src);
    if ~isvector(xd), xd = mean(xd, 2); end
    app.loadFile(src);
    L = findobj(app.Ax, 'Type', 'line');
    fprintf('\nplotted line from %s\n', src);
    if isempty(L)
        ok = false;
        fprintf('  !! nothing was plotted\n');
    else
        xr = [min(L(1).XData) max(L(1).XData)];
        yr = [min(L(1).YData) max(L(1).YData)];
        want_x = (numel(xd) - 1) / fsd;
        want_y = max(abs(xd));
        fprintf('  vertices : %d (expected 12000 for a long file)\n', numel(L(1).XData));
        fprintf('  x span   : [%.2f %.2f] s, expected [0 %.2f]\n', xr, want_x);
        fprintf('  y span   : [%.3f %.3f], expected about [-%.3f %.3f]\n', ...
            yr, want_y, want_y);
        if abs(xr(2) - want_x) > 0.05 * want_x + 0.1
            ok = false;
            fprintf('  !! the x axis is not time - the time vector is missing\n');
        end
        if abs(yr(2) - want_y) > 0.05 * want_y || abs(yr(1) + want_y) > 0.05 * want_y
            ok = false;
            fprintf('  !! the y data does not span the signal amplitude\n');
        end
        if numel(L(1).XData) ~= numel(L(1).YData)
            ok = false;
            fprintf('  !! x and y have different lengths\n');
        end
        fprintf('  ylim     : [%.3f %.3f] for a peak of %.3f\n', ...
            app.Ax.YLim(1), app.Ax.YLim(2), want_y);
        if abs(app.Ax.YLim(2) - 1.1 * want_y) > 0.02 * want_y
            ok = false;
            fprintf('  !! the amplitude axis was not scaled to the signal\n');
        end
    end
else
    fprintf('\nno wav file found, skipping the plot-data check\n');
end

%% 4. envelope arithmetic ----------------------------------------------
% The private method cannot be called from here, so the same arithmetic is
% repeated and compared against the invariants the plot depends on.
fs = 44100;  n = round(138.76 * fs);
y = zeros(n, 1);
y(1:1000:end) = 0.8;  y(2:1000:end) = -0.3;      % known extremes
nb = 4000;
per = floor(n / nb);
m = per * nb;
Y = reshape(y(1:m), per, nb);
lo = min(Y, [], 1);  hi = max(Y, [], 1);
ye = reshape([lo; hi; nan(1, nb)], [], 1);
te = reshape([(1 + (0:nb-1) * per + floor(per/2)) / fs; ...
              (1 + (0:nb-1) * per + floor(per/2)) / fs; nan(1, nb)], [], 1);
fprintf('\nenvelope: %d samples -> %d vertices (%.0f samples per pixel at 950 px)\n', ...
    n, numel(ye), n / 950);
fprintf('  bucket size     : %d samples (%.2f ms)\n', per, 1000 * per / fs);
fprintf('  monotonic t     : %d\n', all(diff(te(1:3:end)) > 0));
fprintf('  nan separators  : %d\n', sum(isnan(ye)));
fprintf('  extreme kept    : min %.2f, max %.2f (signal has -0.30..0.80)\n', ...
    min(ye), max(ye));
if numel(ye) ~= 3 * nb || ~all(diff(te(1:3:end)) > 0) || ...
        abs(min(ye) + 0.3) > 1e-12 || abs(max(ye) - 0.8) > 1e-12
    ok = false;
    fprintf('  !! envelope invariants violated\n');
end

% Short signals must pass through untouched.
if n <= 2 * nb
    fprintf('  short-signal path: raw when n <= %d\n', 2 * nb);
end

%% 5. a real conversion through the polling path -------------------------
% The bug this exists for: the worker finished and wrote its file while the
% window stayed on "转换中" with every control disabled, because completion was
% delivered by afterEach through the event queue.  Completion is now polled from
% a timer, so a real conversion is run here and the UI state is checked after.
% It costs one conversion (~4 s), which is worth it: this is the one failure the
% user actually hit.
if exist(src, 'file') && app.isPoolReady()
    % Load a COPY so the suggested output name cannot collide with a real
    % conversion result the user keeps on disk - the app derives the output
    % from the source name, and this deletes what it writes.
    scratch = fullfile(here, 'app_check_src.wav');
    copyfile(src, scratch);
    app.loadFile(scratch);
    out = app.OutField.Value;
    if exist(out, 'file'), delete(out); end
    t0 = tic;
    app.ProcessButton.ButtonPushedFcn(app.ProcessButton, struct());
    returned = toc(t0);
    fprintf('\nconversion submitted in %.2f s, ProcessButton.Enable = %s\n', ...
        returned, app.ProcessButton.Enable);
    if returned > 1.5
        ok = false;
        fprintf('  !! onProcess blocked the UI thread (synchronous path)\n');
    end
    if ~strcmp(app.ProcessButton.Enable, 'off')
        ok = false;
        fprintf('  !! the controls were not disabled while busy\n');
    end
    % Wait for the poll timer to notice.  pause() lets timer callbacks run.
    while ~strcmp(app.PlayBButton.Enable, 'on') && toc(t0) < 120
        pause(0.1);
    end
    el = toc(t0);
    fprintf('UI recovered after %.2f s\n', el);
    fprintf('status     : %s\n', app.StatusLabel.Text);
    if ~strcmp(app.PlayBButton.Enable, 'on')
        ok = false;
        fprintf('  !! the UI never came back (this is the stuck-at-转换中 bug)\n');
    end
    if contains(app.StatusLabel.Text, '转换中')
        ok = false;
        fprintf('  !! the status line is still the in-progress message\n');
    end
    if ~strcmp(app.ProcessButton.Enable, 'on')
        ok = false;
        fprintf('  !! the controls were not re-enabled\n');
    end
    if exist(out, 'file') ~= 2
        ok = false;
        fprintf('  !! no output file was written\n');
    else
        fprintf('output     : %s (%d bytes)\n', out, dir(out).bytes);
        delete(out);
    end
    if exist(scratch, 'file'), delete(scratch); end
    L = findobj(app.Ax, 'Type', 'line');
    fprintf('lines in the axes after conversion: %d (expect 2: dry + wet)\n', numel(L));
    if numel(L) ~= 2
        ok = false;
        fprintf('  !! the A/B overlay was not drawn\n');
    end
end

app.UIFigure.CloseRequestFcn(app.UIFigure, struct());
fprintf('\nclosed.\n');

fprintf('\n=== %s ===\n\n', ternary(ok, 'APP CHECK PASSED', 'APP CHECK FAILED'));
end

% ======================================================================
function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end

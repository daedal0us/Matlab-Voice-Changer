classdef voice_changer_app < matlab.apps.AppBase
%VOICE_CHANGER_APP  GUI for voice_changer: open a file, pick a preset, convert, A/B.
%
%   Run with:  voice_changer_app
%
%   DESIGN NOTES
%   * Presets only, no free parameter sliders.  Every number a preset carries
%     (target F0, formant factor, tilt, ratio ceiling, direction guard) was
%     tuned as a SET; exposing one of them alone lets the user build
%     combinations the presets were never tested in - e.g. a formant factor
%     above the pitch factor, which is the "small child with an adult-sized
%     mouth" case behind the old thin/metallic complaint.  --formant stays
%     available on the command line for experiments.
%   * The conversion runs on backgroundPool, so the window stays responsive and
%     the plot redraws while a long file is processed.  Falls back to a
%     synchronous call with a modal progress dialog if no pool can start.
%     Measured: parfeval output is bit-identical to the synchronous call.
%   * audioplayer objects live in object properties.  A local variable would be
%     collected and playback would stop after a few milliseconds.
%   * No file I/O on the conversion path: voice_changer takes the samples in
%     memory and returns the result array.  The file is written once, at the
%     end, to the path in the output field.

    % ---------------- UI components ----------------
    properties (Access = public)
        UIFigure      matlab.ui.Figure
        Grid          matlab.ui.container.GridLayout
        PresetDrop    matlab.ui.control.DropDown
        OpenButton    matlab.ui.control.Button
        OutField      matlab.ui.control.EditField
        BrowseButton  matlab.ui.control.Button
        Ax            matlab.ui.control.UIAxes
        ProcessButton matlab.ui.control.Button
        PlayAButton   matlab.ui.control.Button
        PlayBButton   matlab.ui.control.Button
        StatusLabel   matlab.ui.control.Label
    end

    % ---------------- State ----------------
    % This is the ONLY safe place for shared state.  Never guidata/handles:
    % those are figure-based and uifigure does not support them.
    properties (Access = private)
        FileA     = ''            % path of the loaded dry file
        Dry       = []            % dry samples, mono, at FsDry
        FsDry     = 44100
        Wet       = []            % converted samples
        FsWet     = 44100
        PlayerA   = []            % see the note above: keep these alive here
        PlayerB   = []
        Playing   = ''            % 'A' | 'B' | '': which player play() was called on
        Poller    = []            % timer that resets the buttons when sound ends
        PollT     = []            % timer that watches the conversion Future
        Future    = []            % parfeval Future when async
        FutureT0  = []            % tic at submit, for the watchdog
        Busy      = false         % a conversion is in flight
        PoolOk    = false         % set once at startup
        OutAuto   = true          % output path still tracks the source + preset
    end

    % ---------------- Construction ----------------
    methods (Access = private)

        function createComponents(app)
            app.UIFigure = uifigure('Name', 'Voice Changer', ...
                'Position', [100 80 980 640]);
            app.UIFigure.CloseRequestFcn = @(s,e) app.onClose();

            % COLUMN WIDTHS ARE DICTATED BY THE ACTION ROW.  The two playback
            % buttons each take half of the grid, so the halves have to be
            % equal: fixed pixel columns would have to be re-tuned by hand for
            % every window size.  An earlier version spanned columns 2..3
            % versus 4 and produced 470 px next to 190 px.  A nested grid in a
            % panel would also work in principle, but a panel placed in a grid
            % cell does not pick up the cell geometry (measured: a 410x44 cell
            % held a 260x221 panel), so the flat layout is used.
            app.Grid = uigridlayout(app.UIFigure, [8 4]);
            app.Grid.RowHeight   = {20, 40, 56, 32, '1x', 44, 44, 24};
            app.Grid.ColumnWidth = {150, '1x', '1x', '1x'};

            % Row 1 names the preset dropdown, so the choice is not an unlabelled
            % box.  A label needs its own row: two widgets in one cell stack on
            % top of each other - the failure mode that once hid this very
            % dropdown behind the open button, which is why app_check now
            % compares occupied cells.
            lblPreset = uilabel(app.Grid, 'Text', '预设', 'FontWeight', 'bold', ...
                'Interpreter', 'none');
            lblPreset.Layout.Row = 1;        lblPreset.Layout.Column = 1;

            app.PresetDrop = uidropdown(app.Grid, ...
                'Items', {'child','child_bright','child_female', ...
                          'elder','elder_female','normal'}, ...
                'Value', 'child', 'ValueChangedFcn', @(s,e) app.onPreset());
            app.PresetDrop.Layout.Row = 2;   app.PresetDrop.Layout.Column = 1;

            % Columns 2..3, NOT 1..2: two widgets in one grid cell simply stack
            % on top of each other, and the wider button sat on the preset
            % dropdown - the exported screenshot shows no dropdown at all, while
            % Layout still reports it in row 2 column 1.  Nothing warns about
            % this, so app_check compares the occupied cells.
            app.OpenButton = uibutton(app.Grid, 'push', ...
                'Text', '打开音频文件…', 'ButtonPushedFcn', @(s,e) app.onOpen());
            app.OpenButton.Layout.Row = 2;   app.OpenButton.Layout.Column = [2 3];

            % Output path.  Suggesting it (rather than asking every time) is
            % what makes "打开 -> 转换 -> 听" one click; the field exists so a
            % second take does not silently overwrite the first.  The button
            % opens a dialog that also PICKS THE FORMAT, so it is named for what
            % it edits rather than for "saving a copy".
            lblOut = uilabel(app.Grid, 'Text', '输出', 'Interpreter', 'none');
            lblOut.Layout.Row = 3;           lblOut.Layout.Column = 1;
            app.OutField = uieditfield(app.Grid, 'text', ...
                'Value', '', 'ValueChangedFcn', @(s,e) app.onOutEdited());
            app.OutField.Layout.Row = 3;     app.OutField.Layout.Column = [2 3];
            app.BrowseButton = uibutton(app.Grid, 'push', 'Text', '输出路径…', ...
                'ButtonPushedFcn', @(s,e) app.onBrowseOut());
            app.BrowseButton.Layout.Row = 3; app.BrowseButton.Layout.Column = 4;

            app.Ax = uiaxes(app.Grid);
            app.Ax.Layout.Row = 5;           app.Ax.Layout.Column = [1 4];
            xlabel(app.Ax, '时间 (s)');
            ylabel(app.Ax, '幅度');
            grid(app.Ax, 'on');
            % Preset names contain underscores ('child_female') and uiaxes text
            % objects are TeX by default, so the underscore is taken as a
            % SUBSCRIPT: the title rendered "child_female" with an italic f.  The
            % status label already had Interpreter 'none'; the axes title did not.
            % All three titles go through setTitle() so it cannot be lost again.
            app.setTitle('打开一个音频文件以查看波形（灰：原始，橙：变声）');
            % Full scale while empty.  The plotting methods switch YLimMode to
            % manual once there is a measured peak to scale to - on auto, the
            % next draw re-fits the axis and undoes any explicit ylim.
            set(app.Ax, 'YLimMode', 'manual');
            xlim(app.Ax, [0 1]);  ylim(app.Ax, [-1 1]);

            % Row 5: the primary action, full width.  Row 6: the two playback
            % toggles, each spanning half the grid so they match.
            app.ProcessButton = uibutton(app.Grid, 'push', 'Text', '转换', ...
                'ButtonPushedFcn', @(s,e) app.onProcess());
            app.ProcessButton.Layout.Row = 6;  app.ProcessButton.Layout.Column = [1 4];
            app.PlayAButton = uibutton(app.Grid, 'push', 'Text', '▶ 原始', ...
                'ButtonPushedFcn', @(s,e) app.playA());
            app.PlayAButton.Layout.Row = 7;    app.PlayAButton.Layout.Column = [1 2];
            app.PlayBButton = uibutton(app.Grid, 'push', 'Text', '▶ 变声', ...
                'ButtonPushedFcn', @(s,e) app.playB());
            app.PlayBButton.Layout.Row = 7;    app.PlayBButton.Layout.Column = [3 4];
            app.PlayAButton.Enable = 'off';     % nothing loaded yet
            app.PlayBButton.Enable = 'off';     % nothing converted yet

            app.StatusLabel = uilabel(app.Grid, 'Text', '就绪：先打开一个音频文件', ...
                'Interpreter', 'none');
            app.StatusLabel.Layout.Row = 8;
            app.StatusLabel.Layout.Column = [1 4];
        end
    end

    % ---------------- Callbacks ----------------
    methods (Access = private)

        function onOpen(app)
            [f, p] = uigetfile({'*.wav;*.flac;*.mp3;*.m4a;*.mp4;*.ogg;*.oga;*.opus', ...
                '音频文件 (*.wav, *.flac, *.mp3, *.m4a, *.ogg, *.opus)'; ...
                '*.*', '所有文件'}, '选择干声');
            if isequal(f, 0), return; end
            app.loadFile(fullfile(p, f));
        end

        function onPreset(app)
            % Preset and output name are two views of one choice: while the
            % user has not typed a path of their own, changing the preset
            % renames the suggestion (xxx_child.wav -> xxx_elder.wav).
            if app.OutAuto, app.suggestOut(); end
            app.setStatus(sprintf('预设 %s：%s', app.PresetDrop.Value, app.presetHint()));
        end

        function onOutEdited(app)
            % A manual edit means "I mean this path"; stop renaming it.  The
            % path is also not touched when it is what the user typed.
            app.OutAuto = false;
            app.setStatus(sprintf('输出：%s', app.OutField.Value));
        end

        function onBrowseOut(app)
            % Extensions offered, in the order of the filter list below.  The
            % filter INDEX is what tells us the format the user picked - the
            % returned file name carries the extension of the DEFAULT name, not
            % the chosen filter, and uiputfile does not append anything.  That was
            % the "switching to MP3 then back to WAV does nothing" bug: choosing a
            % filter changed no text, so the field still showed the old .wav path.
            exts = {'.wav', '.flac', '.mp3', '.m4a', '.ogg'};
            desc = {'WAV (*.wav)', 'FLAC (*.flac)', 'MP3 (*.mp3)', ...
                    'AAC (*.m4a)', 'OGG (*.ogg)'};
            filters = [strcat('*', exts.') desc.'];
            if isempty(app.FileA)
                defdir = pwd;
                defname = ['out_' app.PresetDrop.Value '.wav'];
            else
                [d, n] = fileparts(app.OutField.Value);
                if isempty(d), d = fileparts(app.FileA); end
                defdir = d;
                % offer the CURRENT name with the WAV extension rather than
                % whatever extension it happens to carry: the filter list starts
                % on WAV, and a default name of e.g. .mp3 next to a WAV filter is
                % what invited the mismatch in the first place.
                defname = [n '.wav'];
            end
            [f, p, idx] = uiputfile(filters, '输出路径', fullfile(defdir, defname));
            if isequal(f, 0), return; end
            % The chosen filter wins over whatever extension the name carries.
            if isnumeric(idx) && idx >= 1 && idx <= numel(exts)
                want = exts{idx};
            else
                [~, ~, want] = fileparts(f);
                if isempty(want), want = '.wav'; end
            end
            f = voice_changer_app.replace_ext(f, want);
            app.OutAuto = false;
            app.OutField.Value = fullfile(p, f);
            app.setStatus(sprintf('输出：%s', app.OutField.Value));
        end

        function onProcess(app)
            if isempty(app.Dry)
                uialert(app.UIFigure, '先打开一个音频文件', '提示');
                return
            end
            if app.Busy, return; end
            out = strtrim(app.OutField.Value);
            if isempty(out)
                app.OutAuto = true;  app.suggestOut();  out = app.OutField.Value;
            end
            [~, ~, ext] = fileparts(out);
            if isempty(ext)                      % same default as the CLI
                out = [out '.wav'];
                app.OutField.Value = out;
            end
            if exist(out, 'file') == 2
                sel = uiconfirm(app.UIFigure, ...
                    sprintf('已存在：\n%s\n\n覆盖它？', out), '覆盖确认', ...
                    'Options', {'覆盖','取消'}, 'DefaultOption', 1, ...
                    'CancelOption', 2);
                if ~strcmp(sel, '覆盖'), return; end
            end

            app.Busy = true;  app.setEnabled(false);
            app.setStatus(sprintf('转换中：预设 %s …', app.PresetDrop.Value));

            % voice_changer takes the samples in memory and returns the result
            % array, so nothing is written until the very end.
            x = app.Dry;  fs = app.FsDry;  preset = app.PresetDrop.Value;
            if app.PoolOk
                % parfeval keeps the UI thread free.  Completion is detected by
                % POLLING the Future from a timer, not by afterEach: afterEach
                % runs its callback through MATLAB's event queue, and when that
                % dispatch does not happen the worker finishes (the output file
                % is written) while the window stays on "转换中" forever with
                % every control disabled.  A timer callback is ordinary MATLAB
                % code and cannot be starved that way.
                app.Future = parfeval(backgroundPool, ...
                    @voice_changer, 2, x, fs, '--preset', preset, ...
                    '--out', out, '--quiet');
                app.FutureT0 = tic;
                app.startPollTimer();
            else
                d = uiprogressdlg(app.UIFigure, 'Title', '转换中', ...
                    'Message', '相位声码器 + 共振峰掩膜', 'Indeterminate', 'on');
                try
                    [y, info] = voice_changer(x, fs, '--preset', preset, ...
                        '--out', out, '--quiet');
                    close(d);
                    app.finish(y, info);
                catch err
                    close(d);
                    app.fail(err);
                end
            end
        end

        function startPollTimer(app)
            if isempty(app.PollT) || ~isvalid(app.PollT)
                app.PollT = timer('ExecutionMode', 'fixedSpacing', ...
                    'Period', 0.25, 'TimerFcn', @(~,~) app.pollProcess(), ...
                    'BusyMode', 'drop');
            end
            start(app.PollT);
        end

        function pollProcess(app)
            % Runs on the MATLAB thread every 250 ms while a conversion is out.
            if ~app.Busy
                app.stopPollTimer();      % already handled (or cancelled)
                return
            end
            f = app.Future;
            if isempty(f) || ~isvalid(f)
                app.stopPollTimer();
                app.fail(MException('voice_changer_app:future', ...
                    '后台任务句柄失效，无法取得结果'));
                return
            end
            switch f.State
                case 'finished'
                    app.stopPollTimer();
                    try
                        [y, info] = fetchOutputs(f);
                        app.finish(y, info);
                    catch err
                        app.fail(err);
                    end
                case 'error'
                    app.stopPollTimer();
                    try
                        fetchOutputs(f);      % rethrows the worker error
                    catch err
                        app.fail(err);
                    end
                otherwise
                    % watchdog: a worker can genuinely hang, and without this
                    % the window would look frozen with no way out.
                    if ~isempty(app.FutureT0) && toc(app.FutureT0) > 900
                        app.stopPollTimer();
                        app.fail(MException('voice_changer_app:timeout', ...
                            '转换超过 15 分钟仍未结束，已放弃等待（后台任务可能仍在运行）'));
                    end
            end
        end

        function stopPollTimer(app)
            if ~isempty(app.PollT) && isvalid(app.PollT)
                stop(app.PollT);
            end
        end

        function finish(app, y, info)
            app.stopPollTimer();
            app.Wet = y(:);  app.FsWet = info.fs;
            app.Busy = false;  app.setEnabled(true);
            app.PlayBButton.Enable = 'on';
            if isfinite(info.f0_out)
                f0txt = sprintf('%.1f Hz', info.f0_out);
            elseif isfield(info, 'f0_expected') && isfinite(info.f0_expected)
                % The confirmation search found no periodicity where the
                % conversion must have put it.  Print the DESIGNED value - the
                % conversion factors are exact by construction - but never as if
                % it had been measured.
                f0txt = sprintf('%.0f Hz（设计值，未直接验证）', info.f0_expected);
            else
                f0txt = '不可估计（输入基频也未测出）';
            end
            note = '';
            if isfield(info, 'pitch_down_limited') && info.pitch_down_limited
                note = '   [已按"童声不降基频"限制]';
            end
            if isfield(info, 'ratio_capped') && info.ratio_capped
                note = [note '   [已按比例上限限制]'];
            end
            % Peak and duration are in the axes title; this line carries the
            % conversion numbers and where the file went, plus any ceiling the
            % converter had to apply - a clamped run must never look like a
            % normal one.
            app.setStatus(sprintf(['转换完成（%s）｜ F0 %.1f → %s（×%.3f）｜ 共振峰 ×%.3f' ...
                ' ｜ %.2f s ｜ 已写入 %s%s'], info.preset, info.f0_in, f0txt, ...
                info.pitch_ratio, info.formant_ratio, info.time_total, ...
                app.shortName(info.outfile), note));
            app.plotBoth();
        end

        function fail(app, err)
            app.stopPollTimer();
            app.Busy = false;  app.setEnabled(true);
            app.setStatus(sprintf('转换失败：%s', err.message));
            uialert(app.UIFigure, err.message, '转换失败');
        end

        % ---------------- playback ----------------
        % One button per signal, each toggling: press while it plays to stop.
        % The poller exists because audioplayer has no "finished" callback in
        % base MATLAB; without it the button would stay stuck on 停止 after the
        % sound ends on its own.
        function playA(app)
            if isempty(app.Dry), return; end
            if strcmp(app.Playing, 'A')          % same button again = stop
                app.stopAll();
                return
            end
            app.stopAll();
            app.PlayerA = audioplayer(app.Dry, app.FsDry);
            app.Playing = 'A';
            app.startPlayback();
        end

        function playB(app)
            if isempty(app.Wet), return; end
            if strcmp(app.Playing, 'B')
                app.stopAll();
                return
            end
            app.stopAll();
            app.PlayerB = audioplayer(app.Wet, app.FsWet);
            app.Playing = 'B';
            app.startPlayback();
        end

        function startPlayback(app)
            % play() returns immediately (playback is asynchronous), so the
            % poller is what actually watches for the end of the sound.
            if strcmp(app.Playing, 'B')
                play(app.PlayerB);
                app.PlayBButton.Text = '■ 停止';
            else
                play(app.PlayerA);
                app.PlayAButton.Text = '■ 停止';
            end
            if isempty(app.Poller) || ~isvalid(app.Poller)
                app.Poller = timer('ExecutionMode', 'fixedSpacing', ...
                    'Period', 0.2, 'TimerFcn', @(~,~) app.pollPlayback(), ...
                    'BusyMode', 'drop');
            end
            start(app.Poller);
        end

        function pollPlayback(app)
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                stop(app.Poller);
                return
            end
            % audioplayer has no finished callback in base MATLAB, so poll it.
            finished = (strcmp(app.Playing, 'A') && ~app.isPlaying(app.PlayerA)) || ...
                       (strcmp(app.Playing, 'B') && ~app.isPlaying(app.PlayerB));
            if finished
                app.Playing = '';
                app.PlayAButton.Text = '▶ 原始';
                app.PlayBButton.Text = '▶ 变声';
                stop(app.Poller);
            end
        end

        function stopAll(app)
            % One player per call.  [PlayerA PlayerB] looks tidier but throws:
            % horzcat is not defined for audioplayer objects, so building the
            % array fails before any of them can be stopped.
            app.stopOne(app.PlayerA);
            app.stopOne(app.PlayerB);
            app.Playing = '';
            app.PlayAButton.Text = '▶ 原始';
            app.PlayBButton.Text = '▶ 变声';
        end

        function stopOne(~, p)
            if ~isempty(p) && isvalid(p)
                try
                    stop(p);     % a player that never started throws here;
                catch            % that is not an error worth reporting
                end
            end
        end

        function tf = isPlaying(~, p)
            % Named method rather than a direct isplaying() call so the empty
            % and deleted cases are handled in one place.
            tf = ~isempty(p) && isvalid(p) && isplaying(p);
        end

        % ---------------- plotting ----------------
        % A time preview: one line per signal.  Hand-rolled because
        % pwelch/spectrogram are Signal Toolbox and stay out of this project,
        % and a full-file FFT of a 139 s recording would cost more than the
        % conversion itself.
        function setTitle(app, s)
            %SETTITLE  Title text with the TeX interpreter OFF.
            %   All three titles go through here: the axes default interpreter is
            %   TeX, and the preset names contain underscores, so 'child_female'
            %   renders with an italic 'f' subscript unless this is set every
            %   time (a plain title(...) call with only a string leaves the
            %   interpreter at whatever the last call set - which is how the
            %   placeholder lost it).
            title(app.Ax, s, 'Interpreter', 'none');
        end

        function plotDryOnly(app)
            % plot() replaces the drawn content by itself; do not cla() here,
            % and do not keep a text object in the axes as a placeholder, or it
            % is deleted the moment anything is plotted.
            y = app.Dry;
            if isempty(y), return; end
            pk = max(abs(y));
            [te, ye] = app.envelope(tvec(app.FsDry, numel(y)), y);
            plot(app.Ax, te, ye, 'Color', [0.35 0.35 0.35]);
            app.setTitle(sprintf('原始   %.2f s @ %d Hz   ｜   RMS %.4f ｜ 峰值 %.3f', ...
                numel(y)/app.FsDry, app.FsDry, sqrt(mean(y.^2)), pk));
            xlabel(app.Ax, '时间 (s)');  ylabel(app.Ax, '幅度');
            xlim(app.Ax, [0 (numel(y)-1)/app.FsDry]);
            app.fitY(pk);
        end

        function plotBoth(app)
            if isempty(app.Dry), return; end
            nd = numel(app.Dry);
            [te, ye] = app.envelope(tvec(app.FsDry, nd), app.Dry);
            plot(app.Ax, te, ye, 'Color', [0.35 0.35 0.35]);
            hold(app.Ax, 'on');
            if ~isempty(app.Wet)
                [tw, yw] = app.envelope(tvec(app.FsWet, numel(app.Wet)), app.Wet);
                plot(app.Ax, tw, yw, 'Color', [0.85 0.33 0.10]);
            end
            hold(app.Ax, 'off');
            legend(app.Ax, {'原始', '变声'}, 'Location', 'northeast');
            app.setTitle(sprintf(['原始 %.2f s → 变声 %.2f s ｜ RMS %.4f → %.4f ' ...
                '｜ 峰值 %.3f → %.3f ｜ %s'], ...
                nd/app.FsDry, numel(app.Wet)/app.FsWet, ...
                sqrt(mean(app.Dry.^2)), sqrt(mean(app.Wet.^2)), ...
                max(abs(app.Dry)), max(abs(app.Wet)), app.PresetDrop.Value));
            xlabel(app.Ax, '时间 (s)');  ylabel(app.Ax, '幅度');
            xlim(app.Ax, [0 max((numel(app.Dry)-1)/app.FsDry, ...
                (numel(app.Wet)-1)/max(app.FsWet, 1))]);
            app.fitY(max(max(abs(app.Dry)), max(abs(app.Wet))));
        end

        function [te, ye] = envelope(~, t, y)
            %ENVELOPE  Min/max decimation for display.  138.76 s at 44.1 kHz is
            %   6.1e6 samples: plotted raw that is one ink block (6400 samples
            %   per pixel) and a redraw that takes seconds.  One vertical line
            %   per bucket - [min max nan] - keeps the shape intact at ~8000
            %   vertices, which is what an audio editor draws.
            nb = 4000;
            n = numel(y);
            if n <= 2 * nb
                te = t(:);  ye = y(:);
                return
            end
            per = floor(n / nb);
            m = per * nb;
            Y = reshape(y(1:m), per, nb);
            lo = min(Y, [], 1);  hi = max(Y, [], 1);
            ye = reshape([lo; hi; nan(1, nb)], [], 1);
            tc = t(1 + (0:nb-1) * per + floor(per/2));      % bucket centres
            te = reshape([tc; tc; nan(1, nb)], [], 1);
        end

        function fitY(app, pk)
            %FITY  Scale the amplitude axis to the signal.  YLimMode must be
            %   manual first: left on auto, the next draw re-fits the axis and
            %   silently undoes the ylim - which is exactly why an earlier
            %   version of this kept showing +/-1 for a signal peaking at 0.52.
            pk = max(pk, 0.01);
            set(app.Ax, 'YLimMode', 'manual');
            ylim(app.Ax, [-pk * 1.1, pk * 1.1]);
        end

        % ---------------- helpers ----------------
        function suggestOut(app)
            % Default output name: source name + preset + .wav, next to the
            % source.  This is the "xxx_child.wav" rule.
            if isempty(app.FileA)
                if isempty(app.OutField.Value)
                    app.OutField.Value = ['out_' app.PresetDrop.Value '.wav'];
                end
                return
            end
            [d, n] = fileparts(app.FileA);
            app.OutField.Value = fullfile(d, sprintf('%s_%s.wav', n, app.PresetDrop.Value));
        end

        function s = shortName(~, p)
            [~, n, e] = fileparts(char(p));
            s = [n e];
        end

        function s = presetHint(app)
            switch app.PresetDrop.Value
                case 'child',        s = 'F0 → 210 Hz，共振峰 ×1.15（童声，默认）';
                case 'child_bright', s = 'F0 → 235 Hz，共振峰 ×1.22，更高更亮';
                case 'child_female', s = 'F0 → 250 Hz，共振峰 ×1.18（女童声）';
                case 'elder',        s = 'F0 ×0.86，共振峰 ×0.94，加颤抖与气声';
                case 'elder_female', s = 'F0 ×0.90，共振峰 ×0.96，音高更高的老人音';
                otherwise,           s = '不变声，用于对照';
            end
        end

        function setStatus(app, s)
            app.StatusLabel.Text = s;
        end

        function setEnabled(app, tf)
            if tf
                st = 'on';
                if isempty(app.Dry), st = 'off'; end
            else
                st = 'off';
            end
            app.ProcessButton.Enable = st;
            app.OpenButton.Enable    = onoff(tf);
            app.PresetDrop.Enable    = onoff(tf);
            app.OutField.Enable      = onoff(tf);
            app.BrowseButton.Enable  = onoff(tf);
        end

        function onClose(app)
            app.stopAll();
            app.stopPollTimer();
            if ~isempty(app.Poller) && isvalid(app.Poller)
                stop(app.Poller);  delete(app.Poller);
            end
            if ~isempty(app.PollT) && isvalid(app.PollT)
                stop(app.PollT);  delete(app.PollT);
            end
            % Cancel a conversion that is still out.  Without this the worker
            % keeps running after the window is gone: it cannot update the UI,
            % and on a long file it keeps a pool worker busy for minutes.
            if ~isempty(app.Future) && isvalid(app.Future) && ...
                    ~any(strcmp(app.Future.State, {'finished', 'error'}))
                try
                    cancel(app.Future);
                catch
                end
            end
            delete(app.UIFigure);
        end
    end

    % ---------------- Startup / public entry points ----------------
    methods (Access = public)
        function app = voice_changer_app
            createComponents(app);
            % license('test','Parallel_Computing_Toolbox') is not a usable
            % probe here: it reports 0 while backgroundPool still starts 8
            % workers, so ask the pool itself.
            app.PoolOk = app.isPoolReady();
            app.suggestOut();
            if nargout == 0, clear app; end
        end

        function loadFile(app, path)
            %LOADFILE  Load a dry file into the app.  Public on purpose: the
            %   Open button is a thin wrapper, so scripting and tests drive the
            %   same code path instead of re-implementing it.
            try
                [x, fs] = audioread(path);
            catch err
                uialert(app.UIFigure, err.message, '读取失败');
                return
            end
            % Same rule as the command line: a genuine multichannel matrix is
            % averaged to mono.  isvector keeps a 1xN (or Nx1) signal, which is
            % already mono, out of mean(x,2) - that used to collapse it to a
            % single sample.
            x = double(x);
            if ~isvector(x), x = mean(x, 2); end
            app.stopAll();
            app.Dry = x(:);  app.FsDry = fs;  app.FileA = char(path);
            app.Wet = [];  app.PlayerB = [];
            app.OutAuto = true;
            app.suggestOut();
            app.PlayAButton.Enable = 'on';
            app.PlayBButton.Enable = 'off';
            [~, n, e] = fileparts(app.FileA);
            % The axes title already reports duration and sample rate, so the
            % status line says the things the title does not: which file, how
            % loud it is (whether the take is usable), and what to do next.
            app.setStatus(sprintf('已载入 %s%s ｜ 采样率 %d Hz ｜ 峰值 %.3f ｜ 可点“转换”', ...
                n, e, fs, max(abs(x))));
            app.plotDryOnly();
        end

        function tf = isPoolReady(~)
            %ISPOOLREADY  Can a background conversion be started?
            try
                backgroundPool;
                tf = true;
            catch
                tf = false;
            end
        end
    end

    % ---------------- Testable helper ----------------
    methods (Static, Access = public)
        function f = replace_ext(f, ext)
            %REPLACE_EXT  Force the extension of a file name, dropping any it had.
            %   PUBLIC AND STATIC on purpose: it is the one rule behind the
            %   输出路径 dialog that app_check can exercise without opening a
            %   dialog.  The chosen FILTER INDEX decides the format and the name
            %   must follow it even when the default name carried a different
            %   extension - ignoring that is what made "pick MP3, then pick WAV"
            %   look like it did nothing, because the name kept the old extension
            %   and uiputfile returns it unchanged.
            [~, n] = fileparts(f);
            f = [n ext];
        end
    end
end

% ======================================================================
function t = tvec(fs, n)
%TVEC  Time base for a signal of n samples at fs.  Row vector, so it matches
%   the shape of the envelope built by ENVELOPE.
t = (0:n-1) / fs;
end

% ======================================================================
function s = onoff(tf)
if tf, s = 'on'; else, s = 'off'; end
end

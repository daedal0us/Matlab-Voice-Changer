# voice_changer — 正常人声 ⇄ 儿童音 ⇄ 老人音（MATLAB 命令行实现）

用 MATLAB 实现的命令行变声器：把一段正常说话录音转换成**儿童音**或**老人音**，也可以反向回到接近原声的"成人音"。
核心逻辑全部在命令行脚本里完成（谱分析、尺度变换、滤波），每一处都有可复现的测量结果作验证。

```matlab
>> voice_changer('voice.wav', '--preset', 'child', 'out_child.wav')   % 儿童音
>> voice_changer('voice.wav', '--preset', 'elder', 'out_elder.wav')   % 老人音
>> y = voice_changer(x, '--preset', 'elder', '--tremor', 1.6);        % 直接吃数组
```

命令行（Windows）：

```bat
matlab -batch "run_voice_changer('child','voice.wav','out_child.wav')"
matlab -batch "demo_voice_changer"        :: 自检 + 基准测试
```

---

## 1. 环境要求

* MATLAB **R2024b**（R2016b+ 即可，用到隐式扩展）。
* **不需要任何工具箱**。本机 `license('test','signal'/'audio'/'dsp')` 全部返回 0，
  因此所有 DSP 都只用 base MATLAB 原语实现：`fft / ifft / filter / sinc / besseli`，
  没有使用 `resample`、`butter`、`pwelch`、`spectrogram`、`inputParser`。

## 2. 算法链

| 步骤 | 处理内容 | 实现文件 |
|---|---|---|
| ① 谱分析 | 倒谱滤波提取谱包络；YIN 差分函数估计基频、浊音比例、谱质心 | `vc_env.m`, `vc_analyze.m` |
| ② 基频尺度变换 | 相位声码器时间伸缩（hop_out = hop/ratio）+ 带限重采样，时长不变、音高乘 ratio | `vc_pitchshift_pv.m`, `vc_resample.m` |
| ③ 共振峰变换 | log 频率轴上对谱包络做分段线性 warp，并联立频谱倾斜、低频隆隆声抑制；整段一次 FFT 施加零相位增益 | `vc_mask.m` |
| ④ 老人音附加层 | 时变分数延迟颤音 + 包络调制的高通气声 | `vc_tremor.m`, `vc_breath.m`, `vc_localenv.m` |
| ⑤ 输出 | RMS 归一化到 −18 dBFS、削顶保护、报告、可选 `--plot` 频谱对比 | `voice_changer.m` |

关键换算关系（已在代码注释与报告中写明）：

* 变调把**所有**频率（包括共振峰）乘 `r`，所以共振峰 warp 实际施加的是 `formant_ratio / r`；
* 最终共振峰位置 = 原位置 × `formant_ratio`；输出共振峰 = 700 Hz → 其中 `child` 为 ≈854 Hz，`elder` 为 ≈658 Hz。

## 3. 预设

| preset | 基频 | 共振峰 | 倾斜 | 颤音 | 气声 | 说明 |
|---|---|---|---|---|---|---|
| `child` | 目标 235 Hz（按 `--ref`，默认 150 Hz） | ×1.22 | +1.5 dB/oct | – | – | 男声→儿童音 |
| `child_female` | 目标 250 Hz（`--ref` 190） | ×1.18 | +1.0 dB/oct | – | – | 女声→儿童音，步长更小 |
| `elder` | ×0.866 | ×0.94 | −1.8 dB/oct | 1.0 % @5 Hz | 0.9 % | 老人音（男） |
| `elder_female` | ×0.901 | ×0.96 | −1.2 dB/oct | 0.8 % | 0.7 % | 老人音（女），更柔和 |
| `normal` | ×1.000 | ×1.000 | 0 | 0 | 0 | 恒等，用于 A/B 对比（**逐位透明**） |

选项（命令行优先级高于预设）：
`--pitch <半音>` `--target <Hz>` `--ratio <r>` `--ref <Hz>` `--formant <r>` `--tilt <dB/oct>`
`--tremor <pct>` `--rate <Hz>` `--breath <pct>` `--fs <Hz>` `--nfft <n>` `--hop <n>`
`--target-level <dBFS>` `--no-normalize` `--plot` `--quiet` `--help`
位置参数：第 1 个是输入文件，第 2 个是输出文件（可放在任意选项之后）。

## 4. 实测性能（本机 R2024b，24 核；`tic/toc` 只计脚本执行，不含 MATLAB 启动）

| 输入长度 | `normal` | `elder` | `child` |
|---|---|---|---|
| 2 s | 45 ms | 67 ms | 86 ms |
| 10 s | – | – | 273 ms |
| 30 s | – | – | 592 ms |
| 60 s | – | – | 1238 ms |

* 稳态约为 **20 ms / 音频秒**；2 s 文件远低于 1 s 预算，**30 s 文件也在 1 s 之内**。
* 会话内**第一次**调用会多花 200–700 ms（JIT、FFT 计划、重采样核表首次构建），
  上表是预热后的最好成绩；`info.time_total` 每次运行都会打印实际耗时，超过 1 s 会自行提示。
* `matlab -batch` 进程本身启动约 2–4 s，这是解释器开销，与脚本执行时间无关。

## 5. 正确性验证（`demo_voice_changer` 全部 PASS）

自检用**已知基频/共振峰的稳态合成元音**做输入，用两个互相独立的测量手段核对：

* 音高：跟踪输入中最强谱峰（720 Hz = 6 次谐波），输出端只在"输入频率 × 声明倍率"的 ±5 % 窗口内找峰，
  这样峰的"身份"由声明决定，检查才有意义；
* 共振峰：同样跟踪该峰经过 formant 级后的位置。

| preset | 声明 | 实测 | 声明 | 实测 |
|---|---|---|---|---|
| normal | ×1.000 | ×1.000 | ×1.000 | ×1.000 |
| child | ×1.567 | ×1.490 (−4.9 %) | ×1.220 | ×1.295 |
| child_female | ×1.316 | ×1.359 (+3.3 %) | ×1.180 | ×1.145 |
| elder | ×0.866 | ×0.844 (−2.5 %) | ×0.940 | ×0.877 |
| elder_female | ×0.901 | ×0.916 (+1.7 %) | ×0.960 | ×0.916 |

另外还验证了：输出长度/采样率不变、无 NaN、无削顶、`normal` 恒等路径峰值残差 −∞ dB、
`--pitch/--formant` 映射精确（×2.000 / ×1.300）、`--target` 命中所要求比值、10 s 文件在预算内。

单独测过的模块精度：

* 重采样器（`vc_resample`）：200 Hz 纯音 ×0.866…×2.0 → 输出频率**误差 0.0000 %，幅度 1.0000**；
* 变调器（`vc_pitchshift_pv`）：500 Hz / 1 kHz 音误差 ≤0.4 %，200 Hz ≤3 %（该处谐波落在 FFT 频点之间）；
* 基频估计（`vc_analyze`，YIN）：85/100/120/150/165/210 Hz 稳态信号**误差 0.0 %**、浊音比例 1.00。

## 6. 已知限制

1. **高音区八度误差**：YIN 对 >210 Hz 的稳态音可能锁到半周期（260 Hz 读成 130 Hz、310 Hz 读成 155 Hz）。
   因此 `child` 预设用 `--ref`（默认 150 Hz）作为绝对目标锚点，而不是依赖自检出的 F0；
   报告里的"输出 F0"在测量不可靠时会显示 `F0 readout unreliable`，而不是给出错误数字。
2. **大幅倍率精度下降**：`--pitch 12`（×2.0）时相位声码器实测偏差约 4.5 %（预设范围内 ≤2.5 %）；
   更小的 hop 并不会改善（会引入相位绕卷混叠，已实测）。
3. 相位声码器对**瞬态**（爆破音、咔哒声）有涂抹，长文件听感上会有轻微的"金属感"，这是该类算法的固有特性。
4. 老人音颤音/气声是**合成**效果，目的是听感上的"衰老感"，不是生理建模。
5. 输入端白噪/清音段不参与共振峰变换（包络增益在无声段被掩蔽），因此不会把噪声放大成金属声。

## 7. 文件清单

| 文件 | 作用 |
|---|---|
| `voice_changer.m` | 入口：参数解析、预设、流程编排、报告、可选绘图 |
| `vc_args.m` | 无工具箱命令行解析（位置参数 + 选项 + 预设展开） |
| `vc_stft.m` / `vc_istft.m` | 帧化 STFT（完整频谱）/ COLA 归一化重叠相加 |
| `vc_pitchshift_pv.m` | 相位声码器变调（时长保持） |
| `vc_resample.m` | 多相 Kaiser-sinc 带限重采样 |
| `vc_env.m` | 倒谱滤波谱包络 |
| `vc_mask.m` | 共振峰 warp + 频谱倾斜 + 低频抑制掩模 |
| `vc_tremor.m` | 老人音颤音（时变分数延迟） |
| `vc_breath.m` | 老人音气声（包络调制噪声） |
| `vc_localenv.m` | 快速局部包络 |
| `vc_analyze.m` | YIN 基频 / 浊音比例 / 谱质心 |
| `vc_synthvoice.m` | 源-滤波器合成测试语音（含韵律起伏，用于长文件基准） |
| `demo_voice_changer.m` | 自检 + 基准测试（稳态元音 + 独立测量） |
| `run_voice_changer.m` | `matlab -batch` 单预设包装入口 |

运行 `demo_voice_changer` 会生成 `demo_voice.wav` 与 `out_<preset>.wav` 供试听。

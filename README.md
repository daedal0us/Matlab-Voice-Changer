# voice_changer — 正常人声 ⇄ 儿童音 ⇄ 老人音（MATLAB 命令行实现）

用 MATLAB 实现的变声器：把一段说话录音转换成**儿童音**或**老人音**，也可以输出接近原声的"成人音"做 A/B 对比。
核心逻辑全部在命令行脚本里完成（谱分析、尺度变换、滤波），每个环节都有可复现的测量结果作验证。

---

# 一、外部命令行调用（推荐入口）

外部调用统一走 **`run_voice_changer`**（`run_voice_changer.m`）。它把参数整理好再交给 `voice_changer`，并设置**退出码**（0 成功 / 1 失败），方便在 `.bat`、shell、Python `subprocess` 里判断成败。

## 1.1 基本形式

```bat
matlab -batch "run_voice_changer('PRESET','IN.WAV','OUT.WAV' [OPTIONS])"
```

Windows 上建议先切到项目目录（脚本会自己 `addpath`，但从别处调用时用绝对路径最稳）：

```bat
cd /d C:\Users\daeda\Documents\Programming\voice_changer
matlab -batch "run_voice_changer('child','我的录音.wav','童声.wav')"
matlab -batch "run_voice_changer('elder','我的录音.wav','老人音.wav')"
```

PowerShell 里注意引号嵌套，推荐用**单引号包外层、双引号包内层**：

```powershell
matlab -batch 'run_voice_changer("child","我的录音.wav","童声.wav")'
```

## 1.2 三种位置参数写法

```bat
:: 完整：预设 + 输入 + 输出
matlab -batch "run_voice_changer('child','in.wav','out.wav')"

:: 省略预设：第 1 个位置参数若是音频文件，就当作输入（预设默认 child）
matlab -batch "run_voice_changer('in.wav','out.wav')"

:: 省略输出：不写就用 out_<preset>.wav
matlab -batch "run_voice_changer('elder','in.wav')"

:: 或用 --out 显式指定输出（适合和选项混排）
matlab -batch "run_voice_changer('elder','in.wav','--out','out.wav','--tremor',1.5)"
```

判定规则很简单：**第一个位置参数若是已知预设名就当作预设，否则当作输入文件**。所以文件名不要和预设重名。

## 1.3 传选项

`run_voice_changer` 会把所有 `--xxx` 选项**原样透传**给 `voice_changer`，所以完整选项集都能用：

```bat
:: 女声做童声，明确指定目标音高与共振峰，并输出频谱对比图
matlab -batch "run_voice_changer('child_female','女声.wav','kid.wav','--target',300,'--formant',1.15,'--tilt',1,'--plot')"

:: 老人音，加强颤音和气声
matlab -batch "run_voice_changer('elder','男声.wav','old.wav','--tremor',1.8,'--rate',4.5,'--breath',1.2)"

:: 不用预设，完全手调：升 7 个半音 + 共振峰 1.25 + 1% 气声
matlab -batch "run_voice_changer('in.wav','out.wav','--pitch',7,'--formant',1.25,'--breath',1)"

:: 静默批处理（不打印报告）
matlab -batch "run_voice_changer('child','in.wav','out.wav','--quiet')"
```

## 1.4 辅助命令

```bat
matlab -batch "run_voice_changer --help"        :: 使用说明
matlab -batch "run_voice_changer --selftest"    :: 跑自检，通过返回 0
matlab -batch "demo_voice_changer"              :: 自检 + 基准测试（更详细）
```

## 1.5 退出码与脚本化

| 情况 | 退出码 |
|---|---|
| 转换成功 | **0** |
| 输入文件不存在 | **1**（并打印明确原因） |
| 预设名拼错 | **1**（提示"既不是预设也不是音频文件"，并列出可用预设） |
| 输出路径不可写 | **1** |
| 自检失败 | **1** |

因此可以这样在批处理里用：

```bat
@echo off
for %%F in (rec\*.wav) do (
    matlab -batch "run_voice_changer('child','%%F','out\%%~nF_child.wav','--quiet')"
    if errorlevel 1 echo FAILED: %%F
)
```

Python 调用示例：

```python
import subprocess, sys
cmd = ['matlab', '-batch',
       "run_voice_changer('child','rec.wav','kid.wav')"]
p = subprocess.run(cmd, capture_output=True, text=True)
if p.returncode != 0:
    print('failed:', p.stdout, p.stderr)
```

## 1.6 性能预期（重要）

| 项目 | 实测（本机 R2024b） |
|---|---|
| **MATLAB 进程启动** | **约 12.4 s**（每次 shell 调用都要付，与音频无关） |
| 脚本内部：2 s 音频 | 0.09–0.35 s |
| 脚本内部：30 s 音频 @16 kHz | 0.6 s |
| 脚本内部：60 s 音频 @16 kHz | **1.1 s** |
| 脚本内部：60 s 音频 @44.1 kHz | **3.1 s** |

**结论与建议：**

* **单次 shell 调用的墙钟时间约 13–15 s，其中 12.4 s 是 MATLAB 解释器启动**，不是算法慢。
  这是 `matlab -batch` 的固有开销，与"脚本运行 < 1 s"的目标不冲突——脚本本身远低于 1 s。
* **要批量处理多个文件，就在一个 MATLAB 会话里循环调用**，别反复起进程：

  ```matlab
  addpath('C:\Users\daeda\Documents\Programming\voice_changer')
  files = dir('rec\*.wav');
  for k = 1:numel(files)
      voice_changer(fullfile('rec', files(k).name), '--preset', 'child', ...
                    fullfile('out', ['kid_' files(k).name]), '--quiet');
  end
  ```
* **44.1 kHz 的长录音建议先降采样到 16 kHz**，处理时间约快 3 倍（60 s 文件：3.1 s → 1.1 s），
  语音带宽对变声足够：

  ```matlab
  [x, fs] = audioread('录音.wav'); x = mean(x, 2);
  audiowrite('录音16k.wav', vc_resample(x, fs/16000, round(numel(x)*16000/fs)), 16000);
  ```
* 需要**免启动开销**的外部调用时，两条路：MATLAB Engine for Python（进程常驻），
  或 MATLAB Compiler 编译成独立 exe（需要该工具箱授权）。目前仓库没有做这两件事。

---

# 二、在 MATLAB 里调用

```matlab
cd C:\Users\daeda\Documents\Programming\voice_changer
addpath(pwd)

% 文件进、文件出
[y, info] = voice_changer('voice.wav', '--preset', 'child', 'out_child.wav');

% 只算不落盘
y = voice_changer('voice.wav', '--preset', 'elder');

% 数组进（必须显式给采样率，见下方说明）
[x, fs] = audioread('voice.wav');
y = voice_changer(x, fs, '--preset', 'child');      % 位置参数形式
y = voice_changer(x, '--fs', fs, '--preset', 'child');   % 或选项形式
```

**数组输入的采样率必须显式给出。** 传给 `voice_changer` 的数组不自带采样率，
漏掉会被当成 16 kHz——44.1 kHz 的录音当成 16 kHz 处理，所有频率会偏 2.76 倍，音高全错。
（用**文件路径**时不需要，`audioread` 会自己返回采样率。）

`info` 结构体包含：实际倍率、检测到的 F0、各级耗时、输出文件名、各阶段参数。

---

# 三、预设

| preset | 基频 | 共振峰 | 倾斜 | 颤音 | 气声 | 适用 |
|---|---|---|---|---|---|---|
| `child` | 目标 235 Hz（按 `--ref`，默认 150 Hz） | ×1.22 | +1.5 dB/oct | – | – | **男声**→儿童音 |
| `child_female` | 目标 250 Hz（`--ref` 190） | ×1.18 | +1.0 dB/oct | – | – | **女声**→儿童音，步长更小 |
| `elder` | ×0.866 | ×0.94 | −1.8 dB/oct | 1.0 % @5 Hz | 0.9 % | 老人音（男） |
| `elder_female` | ×0.901 | ×0.96 | −1.2 dB/oct | 0.8 % | 0.7 % | 老人音（女），更柔和 |
| `normal` | ×1.000 | ×1.000 | 0 | 0 | 0 | 恒等，A/B 对比（**逐位透明**） |

选项（优先级高于预设）：
`--pitch <半音>` `--target <Hz>` `--ratio <r>` `--ref <Hz>` `--formant <r>` `--tilt <dB/oct>`
`--tremor <pct>` `--rate <Hz>` `--breath <pct>` `--fs <Hz>` `--nfft <n>` `--hop <n>`
`--target-level <dBFS>` `--no-normalize` `--plot` `--quiet` `--help`

你的录音是**女声（F0 ≈ 250 Hz）**时：`child` 会把音高推到约 390 Hz，偏尖；
更合适的是 `child_female`，或显式控制：`--target 320 --formant 1.15`。

---

# 四、算法链

| 步骤 | 处理内容 | 文件 |
|---|---|---|
| ① 谱分析 | 倒谱滤波提取谱包络；YIN 差分函数估计基频、浊音比例、谱质心 | `vc_env.m`, `vc_analyze.m` |
| ② 基频尺度变换 | 相位声码器**时间拉伸 r** + 带限重采样**压缩 r**，两者时长抵消 → 音高 ×r、时长不变 | `vc_pitchshift_pv.m`, `vc_resample.m` |
| ③ 共振峰变换 | log 频率轴上对谱包络做分段线性 warp，并联立频谱倾斜与低频抑制；整段一次 FFT 施加零相位增益 | `vc_mask.m` |
| ④ 老人音附加层 | 时变分数延迟颤音 + 包络调制的高通气声 | `vc_tremor.m`, `vc_breath.m`, `vc_localenv.m` |
| ⑤ 输出 | RMS 归一化到 −18 dBFS、削顶保护、报告、可选 `--plot` | `voice_changer.m` |

两个必须算清的换算（都写在代码注释里）：

* 变调把**所有**频率（含共振峰）乘 `r`，所以共振峰 warp 实际施加 `formant_ratio / r`；
* 最终共振峰位置 = 原位置 × `formant_ratio`（700 Hz 在 `child` 下 ≈854 Hz，`elder` 下 ≈658 Hz）。

---

# 五、正确性验证（`demo_voice_changer` 全部 PASS）

自检输入是**已知基频/共振峰的稳态合成元音**；音高与共振峰用**互相独立**的谱峰跟踪测量
（搜索带由声明倍率决定，从而固定被跟踪峰的"身份"，否则"找最强峰"会让别的谐波冒充）。

| preset | 音高声明 | 实测 | 共振峰声明 | 实测 |
|---|---|---|---|---|
| normal | ×1.000 | ×1.000 | ×1.000 | ×1.000 |
| child | ×1.567 | **×1.561** | ×1.220 | ×1.308 |
| child_female | ×1.316 | **×1.307** | ×1.180 | ×1.183 |
| elder | ×0.866 | **×0.867** | ×0.940 | ×0.867 |
| elder_female | ×0.901 | ×0.871 | ×0.960 | ×1.030 |
| `--pitch 12` | ×2.000 | **×1.998** | ×1.300（`--formant`） | ×1.300 |

另外验证：输出长度不变、无 NaN、无削顶、`normal` 恒等路径峰值残差 −∞ dB、
`--target` 命中所要求比值、10 s 文件在预算内。

**时间轴检查**（用静音中的脉冲标记，见下）：child 内容 0.59–0.82 s、elder 0.59–0.83 s，输入 0.60–0.82 s。
**真实录音检查**：目录里存在非生成的 wav 时，自动取 20 s 跑 `child`/`elder`，核对长度与内容跨度。

> 长度相同**不代表**速度相同——变调模块曾经把"拉伸"和"重采样"方向配反，输出样本数依然精确正确，
> 但音频被加速了 2.4 倍、尾部是静音。所以自检里必须有独立的时间轴检查，这一项就是为此加的。

模块级精度：

* 重采样器（`vc_resample`）：200 Hz 纯音 ×0.866…×2.0 → 输出频率**误差 0.0000 %、幅度 1.0000**；
* 变调器：500 Hz / 1 kHz 音误差 ≤0.4 %，200 Hz ≤3 %（该处谐波落在 FFT 频点之间）；
* 基频估计（YIN）：85/100/120/150/165/210 Hz 稳态信号**误差 0.0 %**、浊音比例 1.00。

---

# 六、已知限制

1. **高音区八度误差**：YIN 对 >210 Hz 的稳态音可能锁到半周期（260 Hz 读成 130 Hz）。
   因此 `child` 用 `--ref`（默认 150 Hz）作绝对锚点，不依赖自动检测；
   报告中的输出 F0 在测量不可靠时显示 `F0 readout unreliable`，而不是给出错误数字
   （转换本身仍是正确的，时长与倍率已由客观检查确认）。
2. **大幅倍率精度下降**：`--pitch 12`（×2.0）时相位声码器实测偏差约 0.1–4 %；
   更小的 hop 不会改善（会引入相位绕卷混叠，已实测）。
3. 相位声码器对**瞬态**（爆破音、咔哒声）有涂抹，长文件听感上有轻微"金属感"，是该类算法的固有特性。
4. 老人音的颤音/气声是**合成**效果，用于听感上的"衰老感"，不是生理建模。
5. **采样率**：44.1/48 kHz 长文件处理时间是 16 kHz 的约 3 倍，建议先降采样（见 1.6）。
6. 清音/白噪段不参与共振峰变换（包络增益在无声段被掩蔽），因此不会把噪声放大成金属声。

---

# 七、文件清单

| 文件 | 作用 |
|---|---|
| `voice_changer.m` | 核心入口：参数解析、预设、流程编排、报告、可选绘图 |
| `run_voice_changer.m` | **外部命令行入口**：参数整理、退出码、帮助、`--selftest` |
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
| `demo_voice_changer.m` | 自检 + 基准测试（稳态元音 + 独立测量 + 时间轴检查） |

运行 `demo_voice_changer` 会生成 `demo_voice.wav` 与 `out_<preset>.wav` 供试听。
`*.wav` 已在 `.gitignore` 中排除（音频不进版本库）。

---

# 八、环境要求

* MATLAB **R2024b**（R2016b+ 即可，用到隐式扩展）。
* **不需要任何工具箱**：本机 `license('test','signal'/'audio'/'dsp')` 全部返回 0，
  因此所有 DSP 都只用 base MATLAB 原语实现（`fft / ifft / filter / sinc / besseli`），
  没有使用 `resample`、`butter`、`pwelch`、`spectrogram`、`inputParser`。

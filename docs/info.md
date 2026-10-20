<!---
This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections. You can also include images in this folder and reference them in the markdown.
--->

## How it works

AquaFuse-1 is an always-on **fish-presence wake gate**. A camera sensor drives the chip's pins directly; the
chip scores every frame with a small integer neural network and raises a **wake** bit when fish are probably in
view, so that a power-hungry host can sleep the rest of the time. There is no companion chip and no frame
buffer.

* **Input:** one 96 x 54 greyscale frame (5,184 unsigned bytes, raster order, 8 bits on `ui[7:0]`) with a pixel
  clock on `uio[0]` and a frame-sync on `uio[1]`. At least 4 core clocks per pixel.
* **Stem and background.** An 8 x 8, stride-8 convolution turns the frame into a 7 x 13 x 4 map. An exponential
  moving average of the stem's *accumulator* (12-bit words, 91 x 4 of them) is subtracted before the next stage.
  Because the average and the convolution are both linear they commute, so the chip stores 364 words instead of
  5,184 pixels and the network sees "frame minus background".
* **Network.** Two 3 x 3 convolutions (6 and 6 channels), a 1 x 1 head, the maximum over positions, then a
  3-frame temporal convolution over the stored maps. About 40,000 multiply-accumulate equivalents per frame,
  INT8 weights in ROM.
* **Decision.** A raw per-frame comparator (`uo[0]`) and a **wake** bit (`uo[3]`): 3 of the last 11 raw alarms,
  held for 10 more frames. The host wakes on `uo[3]`.
* **Per-site calibration.** The decision offset and the two shaping constants are loadable through a 3-wire
  42-bit config port (`uio[2]` shift clock, `uio[3]` data, `uio[4]` load), committed at a frame boundary. The
  weights are fixed. **The shipped offset was calibrated on river-herring footage and does not travel: every
  installation must recalibrate on its own empty water.**

### Pins

| pin | function |
|---|---|
| `ui[7:0]` | sensor pixel byte, unsigned |
| `uio[0]` / `uio[1]` | PCLK (one pixel per rising edge) / VSYNC (high for the frame) |
| `uio[2]` / `uio[3]` / `uio[4]` | CFG_SCK / CFG_SDI / CFG_LOAD |
| `uo[0]` | raw alarm |
| `uo[1]` | result_valid (high for one clock when a frame has been scored) |
| `uo[2]` / `uo[4]` | overrun (sticky) / overrun_frame |
| `uo[3]` | **WAKE** |
| `uo[5]` / `uo[6]` | cfg_sdo (config read-back) / cfg_loaded |
| `uo[7]` | bg_resynced (sticky) |

The result for a frame appears about 1,000 clocks after its last pixel. The 42-bit config word is
`{SHAPE_M[5], SHAPE_N[5], CLS_OFFSET[32]}`, MSB first; the alarm is `logit + CLS_OFFSET >= 0`.

## How to test

The project ships known-answer vectors: 32 real held-out river-herring frames and, for each, the alarm and wake
bit the integer reference model produces (`test/vectors`). `test/test.py` runs them in simulation (RTL and, in
CI, the hardened netlist) and also exercises the config port.

On silicon (Tiny Tapeout demo board): copy `firmware/` from the project repository to the board's microcontroller (RP2350 on the ETR kit), enable the
project, and run `import bringup; bringup.main()`. It streams the 32 frames by manual clocking and compares the
wake and alarm bits with the oracle, then loads two extreme thresholds through the config port and checks the
decision follows. A pass means the silicon reproduces the reference; it does not measure accuracy.

## Claims and limits (read before quoting)

* Accuracy, measured on the integer part: visit-level A3 = min(event recall, wake precision) **0.874**
  (one-sided 95% lower bound 0.859) on 1,517 held-out river-herring events from rivers present in training, at
  wake duty <= 0.20. The claim is scoped to per-site calibrated, held-out-clip performance on river herring
  footage from rivers present in training (events held out by session). That matches the best published frame-level figure (F1 87%, one site) on a different metric;
  it does not beat it.
* Held out by whole river, the same recipe reads **0.63** (the older recipe 0.70). On a blind salmon-weir
  footage set (different species, camera and scale) it read 0.494 with every visit detected, but that test is
  confounded. Treat any new site as needing recalibration and measurement.
* The 0.874 is the recipe's figure (45 fold-models, nested). The one fold-model on this die reads 0.842 on its own 303 held-out events.
* Energy is **simulated, not measured**: an activity-annotated simulation of the routed netlist gives about 4.6 uJ per frame
  (3.7 uJ in the core, 0.9 uJ modelled for the sensor pads), which is 3.1-3.4x lower than waking an M2-class GPU host for every frame (host figure
  scaled to an M3); an earlier model said 3.5-3.8x. About 90% of the power is the clock, so this holds only if the chip is clocked at about
  four clocks per pixel (311-390 kHz at 15 fps), not at the 22.7 MHz timing limit. No silicon power measurement exists.
* Timing: the layout is signed off at **22.7 MHz (44 ns)** in every timing corner by Tiny Tapeout's flow. Slew and capacitance
  warnings remain (see `docs/RELEASE_AND_RISKS.md`). Above 22.7 MHz only typical conditions are supported by the analysis.
* Nothing has been fabricated yet; behaviour on silicon is unverified.

## External hardware

A camera that delivers 96 x 54 8-bit greyscale frames (or an RP2350/FPGA stage that downscales to that) with a
pixel clock and frame sync at 3.3 V logic levels; a host that wakes on `uo[3]`; the Tiny Tapeout demo board for
bring-up.

# Release notes and open risks (read before submitting)

Written 18 October 2026 alongside the project repository's `docs/TAPEOUT_RELEASE_2026-10-18.md`, which is the
master checklist. This copy travels with the submission.

## What this repository is

`src/` is a byte-identical copy of the RTL that the project hardened and verified: ROMs and header generated from the
DR0097 fallback recipe, checkpoint `fold0_seed2026102101` (the median fold-model by a written rule), fixed 12-bit EMA.
The verification evidence lives in the project repository (decisions 0102-0105), not here.

## Verified before this was assembled

* RTL equals the integer oracle on 32 real frames at 3 pixel rates (Verilator).
* The part computes its float model within the gate (own-fold A3 0.8416 integer vs 0.8482 float).
* Layout r9 under the project's OpenLane 2.0.0 config: DRC 0/0/0, LVS 0, setup +0.895 ns, hold +0.141 ns, worst
  slow-corner transition 1.407 ns; Tiny Tapeout precheck 15/15 on that GDS.
* The r8 and r9 netlists reproduce the RTL on every output pin and cycle over 32 frames (Icarus, sky130 functional
  models, unit delay), the same method the official `gl_test` uses.

## NOT verified (each is a way this can still fail)

1. **The official flow closes this design only with the settings in `src/config.json`, at a 44 ns (22.7 MHz) clock,
   and the signoff still carries slew and cap warnings.** r9 closed under OpenLane 2.0.0 at 38 ns. Tiny Tapeout's
   LibreLane 3.0.14 flow, given the r9 repair settings, failed at clock-tree legalization (the newer repair step
   inserted 10,544 buffers where r9 had 4,581 and the die overflowed). The recipe now in `config.json` (fanout limit
   50, repair slew margin 35, no wire-length repair, 44 ns) was measured on a GitHub runner on an experiment branch
   with the same RTL and settings (run 39241627806: `gds` 4 h 02 min, then `precheck` and `gl_test` passed): Magic
   DRC, LVS and antenna clean; setup slack positive in every corner (worst +0.575 ns, max_ss); hold clean (worst
   +0.180 ns). **Not clean:** max-slew violations remain (321 nets in max_ss, 225 in nom_ss, 132 in min_ss, 5-7 in
   the typical corners) and max-cap violations in every corner (5 to 46 nets per corner); the worst slew and cap
   values are not in the flow's artifacts. The same recipe at 38 ns (26.3 MHz) left setup misses of -1.6 to -2.8 ns in
   the three slow corners, and at 40 ns they remained, so **the rated clock is 22.7 MHz**. Above it, only typical
   conditions are supported by the analysis (the typical corners have about 2x headroom, the slow corners none).
   Check that this commit's own `gds`, `precheck` and `gl_test` runs are green before paying. The linter is ON, as in the template
   (an earlier draft switched it off, as every project layout run did, and that would have failed the official job:
   the action's "Linter output" step `cat`s a lint log that is only written when the linter runs). A Verilator `-Wall`
   lint of `src/` with LibreLane's own flags gives 0 errors and 57 untriaged warnings; warnings do not fail the flow.
   `LINTER_DEFINES` gives the lint step the behavioural clock gate so it never needs the sky130 cell. If the gds
   action fails at lint or on an unknown config key, look there first.
2. **DR010: shape confirmed, slots are the risk.** The SKY130 template's `info.yaml` text lists tiles only up to 8x2 (stale):
   8x4 projects were submitted on SKY 25a, 26a and 26b and the toolchain's tile table has our die (1378.16 x 511.36 um).
   32 tiles must still be free when you submit: SKY 26a, 26b and 26c all filled; SKY 26d had 255 of 512 free on
   18 Oct, deadline 2026-11-30. Submit early.
3. **The RTL cocotb test uses a sized-divisor copy of one file** (`test/compat/`) because Icarus 12 cannot compile the
   original; `src/` is untouched. It also drives only the first 12 of the 32 vector frames (`AQUAFUSE_FRAMES` in
   `test/Makefile`): Icarus simulates this RTL at about 260 s per frame, so the full clip plus the config test would
   take 3-5 hours against GitHub's 6-hour job limit. 12 frames reach the first alarm and the wake bit's rising edge;
   the project's Verilator run covers all 32 frames in RTL and the gate-level job keeps all 32.
4. **No silicon exists.** Energy is modelled, not measured; speed on silicon is unmeasured; the first power-on is the
   first real test (see the project's `docs/BOARD_AND_BRINGUP.md`).
5. **Accuracy claims are scoped** (see `docs/info.md`): per-site calibrated, held-out-clip, river-herring; held-out
   river 0.63; blind salmon-weir 0.494 (confounded). The accuracy bar was set by the owner as a parity bar (DR 0104),
   not met against the earlier lb95 > 0.90 bar.

## Steps for the owner (nothing here was done on your behalf)

1. Create a GitHub repository from this directory's contents (public repositories get unlimited Actions minutes) and
   push; Actions run `gds`, `precheck`, `gl_test`, `docs`, `test`.
2. Read the `gds` summary: utilisation, timing, DRC, cell count against 32 tiles.
3. Ask Tiny Tapeout (calculator "contact us" / Discord) to confirm an 8x4 project fits the open shuttle.
4. Then, and only then, create the submission on app.tinytapeout.com and pay (EUR 2,555 at the standard tier, 2,355
   individual tier if still available).

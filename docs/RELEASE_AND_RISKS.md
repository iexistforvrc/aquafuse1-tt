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

1. **The official GDS action has not been run on this repository.** r9 closed under OpenLane 2.0.0 with its own
   config; this submission is hardened by Tiny Tapeout's LibreLane flow with `src/config.json` (our r9 recipe on top of
   the template defaults, which differ: 20 ns clock, density 60, margins). Margins were thin (slew 0.09 ns under the
   limit, setup +0.9 ns). Run the `gds` workflow early and read the report. The linter is ON, as in the template
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

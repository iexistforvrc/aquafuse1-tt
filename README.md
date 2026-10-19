![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

# AquaFuse-1 — Tiny Tapeout submission (SKY130, 8x4)

A sensor-direct, always-on fish-presence wake gate: a streaming INT8 neural network with an accumulator-domain
background model, a temporal head and a held wake bit. See [docs/info.md](docs/info.md) for how it works, the
pins, the tests and, importantly, **what has and has not been measured**.

* `src/` is the RTL exactly as hardened (a byte-identical copy of `rtl/experimental/stream12c/` in the project
  repository at the commit named in `docs/RELEASE_AND_RISKS.md`), plus `config.json`, the hardening settings the
  design needs.
* `test/` is the Tiny Tapeout cocotb harness with known-answer vectors from the part's integer oracle.
* `info.yaml` is the project description. `tiles: "8x4"` (32 tiles) was accepted on earlier SKY130 shuttles; the
  risk is free slots at submission time (see `docs/RELEASE_AND_RISKS.md`, item DR010).

Created from the structure of the Tiny Tapeout SKY130 Verilog template. Apache-2.0.

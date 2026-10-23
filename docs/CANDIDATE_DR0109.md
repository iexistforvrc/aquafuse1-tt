# Experimental electrical-closure candidate — not a release

Base: verified `2bda787`. RTL, ROMs, test vectors and temporal rule are unchanged.
60 ns target, hot slow default and CTS corner, CTS clkbuf_16 only, hold repair
margins 0.35/0.30 ns. This permits more clock-tree power for electrical margin.
Older datasheet signoff claims describe the baseline and do not certify this
candidate. Preserve all nine signoff corners and all official checks. Candidate
must also have zero slew, capacitance, fanout, setup and hold violations, with
positive slack margins, before adoption. New activity-annotated energy is needed.
No viewer deployment is run from this experimental branch.

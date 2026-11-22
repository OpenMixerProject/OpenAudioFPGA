# WING V1 B-only CDC and timing audit

## Sampling and reset contract

| Crossing | Design contract |
| --- | --- |
| 49.152 MHz audio → 50 MHz RMII startup | The audio domain synchronously initializes all 768 routing words. It registers the ready level; only `rmii_started[0]` samples it asynchronously. The final stage releases the RMII-side reset. |
| RMII → audio and derived BCLK resets | RMII `core_rst` asynchronously presets both FFs of each local reset chain, even with the destination clock stopped. Once `core_rst` releases, each local reset stays asserted until its own clock shifts in two zeros on rising edges. Downstream logic that consumes reset synchronously still needs clock edges to clear its state. |
| Audio → AES BCLK, and return | BCLK is generated from inverted `phase(1)` (the vendor buffer carries the non-inverted net and uses inversion at consumers). It is not an unrelated clock. Data and FS launch through falling-audio-edge registers and keep normal related-clock STA; BCLK returns serialized data through the opposite edge. The ASSM toggle alone is a held, synchronized event. The ASSM generator samples the four-cycle WCLK pulse every audio cycle, not every 16th. |
| BCLK → RMII TX | A six-sample, 288-word block publishes `base` and `ASSM` with a toggle. TDM writes the descriptor before toggling at the end of its last slot and holds it until the next block. RMII captures the descriptor when it sees the two-stage synchronized toggle, then starts the framer with only local registers. Blocks are ~125 µs apart; the 48 kHz wire frame fits in that interval. |
| RMII → BCLK RX | The deframer publishes only a complete CRC-good block. RMII holds `base`/`page` until the next good block. BCLK captures into the pending context on the two-stage synchronized toggle. Page is optimized away with WING aux disabled. Both directions use inferred dual-clock sample RAM, not per-bit synchronizers; the held descriptors identify completed data. |
| RMII → audio status, RMII → BCLK link enable | These slow one-bit levels each have a two-stage receiver. Link health is latched at the audio frame boundary. Async external sync observations feed first-stage RMII watchdog samplers. |
| AES50 sync TX pins | As upstream, `mdix` and `core_rst` drive both TX enables and gate both TX clocks combinationally. MDI selects A TX / B RX; MDI-X selects B TX / A RX. Pair selection and pin reset take effect without an audio edge, even mid-pulse. The source is generated sync in master mode or the selected RX pin in slave mode. WING B uses master mode. |
| RMII pads | RXD/CRS_DV are captured together on a rising edge; TXD/TX_EN are registered together on a falling edge. No false path on these pads. SDC refers to forwarded REF at AB15 and assumes RX arrives 1…10 ns after REF; TX requires 4 ns setup and 2 ns hold at that pad reference. These are provisional budgets, not PHY specifications or board measurements. |
| SPORT and SPI | SPORT drives on the rising CKRE=0 edge and samples on the opposite edge. TX frame enable is folded into slot load, not a combinational pad gate. Half-bit STA and the prior provisional board budget remain. Control SPIBone and DSP DPI keep their existing oversampled or forwarded SPI paths; the WING control bus, routing scan, commands and status CSRs share the audio clock. No AES constraint cuts those clocks. |

The bundle receiver cannot sample a new descriptor until two destination
periods after the earliest first toggle sample: ≥40 ns for TX and ≥162.76 ns
for RX. The routed setup limits are 18 ns and 30 ns respectively, with
clock-tree offsets accounted for by Efinity. Only phase-based hold is cut
on the bundle D pins: the physical requirement is settle before capture and
remain stable until the following publication. Single-bit cuts end at
specific first-stage D pins; subsequent FF-to-FF and related-clock paths
remain timed. The reset exception is separate: it cuts `core_rst` to the
four asynchronous SR pins in the B-only build, not the local release paths
or downstream reset consumers. There is no fixed RMII-to-destination edge
relationship for those SR pins. No asynchronous clock groups are declared.
Audio data transfer relies on continuous clocks and the bounded 48 kHz
cadence, not on a queue between indefinitely rate-mismatched peers.

## Reproduce digital checks

Generate with `generate.py <stage> --aes50-ports 1`. Run
`bash platforms/wing_trion/tests/run.sh <stage>` with GHDL and Python 3. Port B uses
independent 49.152/50 MHz clocks and asynchronous sync stimulus, real TDM
and RMII framing with CRC, a changing word for every channel/sample, and
reset during traffic. After sustained playback the bench also stops audio
and BCLK through a complete `core_rst` pulse. The runner checks the DUT's
reset signals in the waveform for assertion and retention without clock
edges and release on each clock's second rising edge, restarting audio
while BCLK is still stopped. SPORT and Wishbone
cover word edges, frame mute, selector/range semantics, scan arbitration
and startup clearing.
The SS0 bench checks the DSP selector. The separate Verilator `tb_ss1.v`
bench checks the generated B-only SoC's identity, readiness and reset mask.
The sync pin bench compares all four output waveforms against the unpatched
submodule in generated and slave-forwarded modes. It checks both directions
of MDI/MDI-X switching between audio edges and reset assertion, release and
pair selection with the audio clock stopped.

In Efinity 2026.1.132 run `efx_run wing-fpga.xml --flow compile` on the staged
T55F484 project (C4, seed 1), then `efx_run --flow sta_tclsh --tcl_script
<path-to-audit_b.tcl> wing-fpga.xml`. Inspect the clock summary, exact bundle
paths and limits, synchronizer chain paths, and per-pin RMII setup/hold.
For the reset chains, check `cdc-reset-release-{setup,hold}.rpt` for two
timed interstage paths. The `cdc-reset-sr-{setup,hold}.rpt` queries should
find no timed paths to the excepted SR pins (Efinity logs "No timing path
is found" instead of writing an empty report). This is not recovery/removal
signoff for the asynchronous SR inputs.
The `check_timing` no-clock entry on `CLKBUF__2|I` is the input to the
generated clock declared on `CLKBUF__2|O`. Verify the driver is
`console/phase[1]` and all user FFs have clock signatures. Auxiliary/async
outputs and forwarded clocks intentionally have no external I/O delay;
they are not board-qualified by this audit. The sync TX outputs have no
false paths. `cdc-sync-tx-{max,min}.rpt` reports physical delays to them,
not slack against a receiver budget.

### Historical routed B-only result (build ID `0x2bcf0718`)

This result predates the separate fabric-identity target. The shared SPIBone
source is part of the B build digest, so regenerate and bind the current image;
do not reuse the historical manifest, build ID or bitstream hash.

| Check | Efinity 2026.1.132 (ns) |
| --- | ---: |
| Worst setup / hold across analyzed paths | +0.452 / +0.086 |
| TX descriptor (5 base bits + ASSM), 18 ns limit | +2.828 setup |
| RX descriptor (4 live base bits), 30 ns limit | +42.110 setup |
| Audio → AES BCLK data/FS | +7.535 setup / +5.139 hold |
| RMII RX pads, worst of all three | +2.987 setup / +3.024 hold |
| RMII TX pads, worst of all three | +2.025 setup / +8.548 hold |
| SPORT FPGA → DSP / DSP → FPGA, worst setup | +0.771 / +0.452 |

`audit_b.tcl` found no negative paths with the loaded constraints, no
phase-based hold path on the two bundles, and 11 timed first-to-second
synchronizer stages (worst setup +18.921 ns). `check_timing` reported no
unconstrained internal data endpoints. The full reports include the pad
reference clock arrival and the per-bit bundle bounds. The interface/pin
plan and DSP profile are byte-identical to the pre-fix stock candidate;
the 210 source and 210 destination IDs are unchanged.

### Routed B-only build with fabric-ID sources present (`0xc013b1ac`)

Efinity 2026.1.132 (C4, seed 1) reported worst setup/hold of
+0.978/+0.119 ns, TX/RX descriptor setup of +3.021/+40.895 ns, and zero
unconstrained internal data endpoints. These are results for this build ID
under the provisional pad budgets, not hardware qualification.

### Historical routed B-only build before restoring sync pin gating (`0x1142aad3`)

Efinity 2026.1.132 (T55F484 C4, seed 1) produced a bitstream. The loaded
constraints gave worst setup/hold slack of +1.448/+0.116 ns, zero negative
paths and zero unconstrained internal data endpoints. Audio and BCLK reset
interstage setup/hold slack was +19.266/+0.361 ns and +80.301/+0.361 ns,
respectively. TX/RX descriptor setup slack was +1.448/+42.720 ns; hold remains
excepted on those descriptor paths. RMII pad RX setup/hold was +5.307/+2.859 ns
and TX was +4.949/+8.246 ns under the provisional budgets.

In a separate route without the reset SR exception, the only negative paths
reported were the four RMII `core_rst` → asynchronous SR checks (worst hold
slack −2.661 ns). The final route cuts those crossings only; the positive
slack above does not include them. The mapped netlist shows asynchronous
SR on both stages of both chains (`SR_SYNC=0`).

### Routed B-only build with upstream sync pin gating (`0xaafb5e94`)

Efinity 2026.1.132 (T55F484 C4, seed 1) produced a bitstream. With the
project SDC, worst setup/hold slack was +1.335/+0.218 ns, with no negative
paths or unconstrained internal data endpoints. TX/RX descriptor setup
was +2.349/+41.874 ns; RMII RX was +2.664/+2.767 ns setup/hold and TX
was +3.025/+9.212 ns under the provisional pad budgets.

Reanalyzing the same route without the existing asynchronous reset SR
exception found two audio SR setup failures (−4.863 ns each) and two
BCLK SR hold failures (−2.203 ns each). This is not recovery/removal signoff.
No new timing exceptions were added. The sync TX audit found all ten
register-Q-to-pad paths, with delays ranging from 2.163 ns (fast corner)
to 7.875 ns (slow corner). The four outputs have no external timing budget,
so these delays are not board signoff.

## Physical gates (not part of digital signoff)

1. **Readback only:** Require an already approved diagnostic image and loader
   with a matching manifest. Require CDONE and online SPIBone on SS1. Read
   MAGIC, ABI, BUILD_ID, capabilities and READY at 0x1800…0x1810 without
   writes. Require zero DSP RESET_RELEASE / AUDIO_ENABLE / AUDIO_VALID and
   OFF routes; do not pulse configuration or release DSP audio. For an
   AES-isolated diagnostic, require a separate image that holds shared W9
   PHY reset asserted and forces TX_EN and both sync DEs low. The B audio
   image releases its PHY automatically; it has no CSR for this isolation.
2. **Clocks and pads:** Measure Si5351 CLK0/R2 49.152 MHz, CLK5/M3 50 MHz and
   AB15 REF frequency, duty, jitter and pad skew. Confirm actual PHY,
   straps/master mode and pad budgets for CRS_DV, RXD[1:0], TX_EN and
   TXD[1:0], and W9/reset effects on both A and B. Confirm T6/R7 are
   observed only and resolve sync transceiver pin roles and direction at B
   before connecting a peer. Check sync waveform and ASSM in both
   directions; CSR status bit 2 reports clock health, not valid audio.
3. **Data:** Qualify clock lock, link and CRC on a known 48 kHz peer with DSP
   FS/VALID still disabled, checking sustained 48-channel directional
   payloads and reset recovery. Separately measure SPORT CKRE phases,
   BCLK/FS and bidirectional setup/hold/skew on the actual SHARC speed grade
   and programmed PLL/CCLK. Require the real budget and framing before
   enabling a DSP lane. A valid bitstream/header or a link LED is not a pass.

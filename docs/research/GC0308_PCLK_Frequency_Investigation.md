# GC0308 PCLK Frequency Investigation

**Target:** Sipeed Tang Nano 4K / GC0308  
**Repository branch:** `feature/hyperram-storage-selftest`  
**Status:** Open — the exact DVP PCLK frequency is not yet proven from the available datasheet text.

## 1. Purpose

Record the clock configuration and timing analysis for the GC0308 camera interface. The key distinction is between:

- **MCLK/XCLK:** clock supplied by the FPGA to the sensor.
- **Internal pixel/timing clock:** clock domain used by the sensor's image pipeline and row timing.
- **PCLK / cam_pclk:** clock output by the sensor and used by the FPGA to sample the 8-bit DVP data bus.

These clocks must not be assumed to have the same frequency.

## 2. Configuration in the current RTL

Source: `gowin_cameradrive/src/camera_interface.vhd` on `feature/hyperram-storage-selftest`.

The design contains:

```vhdl
clkcam <= clk24;
```

and the top-level connects `clk24` to the sensor clock output. Therefore the configured sensor input clock is:

[
f_{MCLK}=24\text{ MHz}
]

The initialization table writes these page-0 registers:

| Register | Value | Relevant meaning |
|---|---:|---|
| `0x24` | `0xA6` | RGB565 output format |
| `0x25` | `0x0F` | Enables the selected DVP outputs, including PCLK |
| `0x26` | `0x03` | Sync polarity configuration; PCLK polarity bit is 0 |
| `0x28` | `0x00` | Clock-divider mode |

The capture process is clocked by the sensor's PCLK input:

```vhdl
dvp_capture_fsm : process(cam_pclk)
```

Thus the RTL correctly treats `cam_pclk` as an external clock domain. It does not generate PCLK inside the FPGA.

## 3. What the datasheet says

Reference: GC0308 datasheet, especially the row-timing description (page 9) and register descriptions for `0x26` and `0x28` (pages 15–16).

### 3.1 Register 0x28 — clock divider

The divider field is in bits [6:4], with the documented division factor given by the field plus one:

[
Div=Register[6:4]+1
]

For the programmed value `0x00`:

[
Div=0+1=1
]

This establishes that the configured divider field selects divide-by-one. It does **not**, by itself, establish the absolute frequency of the DVP PCLK output or prove that PCLK equals MCLK.

### 3.2 Register 0x26 — PCLK polarity

The programmed value is:

[
0x03=00000011_2
]

The PCLK polarity bit (bit 2) is zero. The datasheet describes PCLK as derived from the internal `isp_2pclk` signal, with this bit selecting its output polarity. The polarity setting changes the phase/inversion, not the clock frequency.

The name `isp_2pclk` is a useful clue, but the name alone is not sufficient evidence for a mathematical relation such as:

[
f_{PCLK}=2f_{MCLK}
]

Do not treat that relation as confirmed unless a timing diagram, explicit datasheet statement, or measurement establishes it.

## 4. Row timing from the programmed values

The datasheet gives the row-time relation:

[
row\_time=Hb+Sh\_delay+win\_width+4
]

The current initialization table programs:

- `Hb`: high bits from `0x0F[3:0]`, low byte `0x01` = `0x32`; hence (Hb=0x132=306).
- `Sh_delay`: `0x12=0x2A`; hence 42.
- `win_width`: `0x0B=0x02`, `0x0C=0x88`; hence (win\_width=0x288=648).

Therefore:

[
row\_time=306+42+648+4=1000
]

This is 1000 units of the pixel-clock timing domain used by the datasheet formula. It must not automatically be described as 1000 edges of the external DVP `cam_pclk` until the relationship between the internal timing clock and DVP PCLK is verified.

## 5. RGB565 DVP byte-rate constraint

The configured output is RGB565 over an 8-bit data bus. Each pixel therefore requires two byte transfers.

For 640 active pixels:

[
N_{bytes/line}=640\times2=1280
]

The RTL expects exactly 1280 valid byte samples while HSYNC is active:

```vhdl
constant C_BYTES_PER_LINE : positive := G_FRAME_WIDTH * 2;
```

If the 1000 row-time units correspond to a 24 MHz internal timing clock, then:

[
T_{row}=\frac{1000}{24\text{ MHz}}=41.667\ \mu s
]

For the 1280 active byte transfers to fit inside this row period, the average PCLK during active data must be at least:

[
f_{PCLK,active}\geq\frac{1280}{41.667\ \mu s}=30.72\text{ MHz}
]

This lower bound is only a consistency check under the stated 24 MHz timing-clock assumption. It does not prove a 48 MHz PCLK. If PCLK were 48 MHz, the active byte-transfer duration would be:

[
T_{active}=\frac{1280}{48\text{ MHz}}=26.667\ \mu s
]

which can fit within the calculated row period, leaving time for blanking and other row intervals. This makes 48 MHz a plausible hypothesis, not a datasheet-confirmed value.

## 6. Current conclusion

| Item | Current conclusion | Confidence |
|---|---|---|
| FPGA-to-sensor MCLK | 24 MHz, directly assigned from `clk24` | Confirmed by RTL |
| Divider field in `0x28` | Divide-by-one setting | Confirmed by register definition and RTL value |
| PCLK polarity | Selected by `0x26[2]=0` | Confirmed by register definition and RTL value |
| Active bytes per VGA line | 1280 bytes for 640 RGB565 pixels | Confirmed by format and RTL |
| Row-time register-derived count | 1000 internal pixel-clock units | Derived from datasheet formula and programmed values |
| Exact external DVP PCLK frequency | Not established | Open |
| 48 MHz PCLK | Plausible hypothesis only; not yet proven | Unverified |

**Do not hard-code 48 MHz as a guaranteed sensor output or use it as a proven input-rate assumption for FIFO sizing yet.** The camera capture logic should continue to use the actual `cam_pclk` pin as its clock.

## 7. How to close the question

Preferred verification order:

1. Measure the GC0308 PCLK pin with an oscilloscope or frequency counter while the sensor is configured and streaming.
2. If direct probing is unavailable, add a measurement block in the FPGA: count PCLK edges over a known interval measured in the independent 24 MHz domain. Use proper clock-domain crossing for the counter snapshot; do not sample a 48 MHz clock directly with a 24 MHz ILA clock and infer its frequency from the sampled waveform.
3. Capture HSYNC and PCLK together and measure:
   - PCLK cycles per active HSYNC interval,
   - PCLK cycles per complete line,
   - line period in 24 MHz reference-clock cycles.
4. Compare measured values with the datasheet row-time formula and revise the clock interpretation only after the measurement is repeatable.

## 8. Reference

- GalaxyCore GC0308 datasheet, timing section and register descriptions for page-0 registers `0x26` and `0x28`: https://www.min.at/prinz/fp-content/attachs/GC0308.pdf
- RTL source: `gowin_cameradrive/src/camera_interface.vhd`, branch `feature/hyperram-storage-selftest`.

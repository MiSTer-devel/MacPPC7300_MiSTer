# The sound: what went wrong, how it was found, what is left

The record of the audio work on the MacPPC7300 core, kept apart from the
plan so that the next sound problem starts from what is known. Dates are
2026; the decisions table in `MacPPC7300_plan.md` ("sound" rows) has the
same facts in brief, and the commits are named.

## What the sound path is

AWACS (`rtl/machine/MacPPC7300_awacs.sv`, the Screamer codec behind Grand
Central, after dingusppc's `awacs.cpp`) takes 16-bit stereo frames from
DBDMA channel 8 (`MacPPC7300_dbdma`, a word per memory access since build
43) through an 8-byte FIFO, at the frame rate the sound control register's
bits 10-8 select, and puts `snd_left`/`snd_right` out at that rate; a frame
the channel has not delivered holds the last one. `MacPPC7300.sv` adds the
CD's audio and the MT32-pi's I2S to it, saturates, and hands `AUDIO_L/R`
to the framework, whose `audio_out` samples them in its own 24.576 MHz
clock (a value is taken when two consecutive samples agree) and sends them
to HDMI and the analog outputs at 48 kHz.

Channel 9 (sound in; `SOUND_IN_DMA = 1` since 2026-11-13, 0 leaves its
registers alone) takes frames from the board's ADC, the DE10-nano's
LTC2308 behind the audio-in jack of the Analog I/O board or the ADC add-on
(`rtl/machine/MacPPC7300_adc.sv`; the OSD's "Audio input": Off, Mono,
Stereo, acting at once). At each of AWACS's 88,200 Hz ticks channels 0
(left) and 1 (right) are converted, the DC level they sit on is followed
(7 Hz) and taken off, and AWACS puts the mean of a frame's 2 to 12 samples
into the channel, in the out channel's byte order. The framework's
`ltc2308.sv` is not used: it would clock the chip at 50 MHz of this
machine's 100 (the chip's limit is 40) and needs a constant clock. The
codec's input selection and gain change nothing. `verilator/adc_tb.sv`
(`make adc`) runs it against a model of the chip, at 100 and at 70 MHz.

### The audio-in jack

A tester's recordings (DECK II, Pro Tools 3.4; 2026-11-14) were distorted,
their waveforms on one side of zero only. It is the board, not this logic
(reviewed again that day, nothing found):

- The ADC add-on (1.1, 1.3) and the Digital Base board (9.2) wire the jack
  straight to the ADC header: no capacitor, no bias. The DE10-nano adds
  49.9 ohm in series and 1 nF to ground a channel, the chip's COM is at
  ground, and its range is 0 to 4.096 V (schematics, read 2026-11-14). The
  clones' boards (MiSTer Pi, SuperStation) were not found.
- So a line signal, which swings about 0 V, loses its negative half: the
  chip reads 0 there, and the level followed here is only the mean of what
  is left. Nothing in the core can bring that half back, and the chip's
  bipolar mode does not either (its pins still read nothing below ground).
  The MiSTer wiki's "ADC-in" page says as much: enough for tape, not for
  audio. The framework's tape reader (`ltc2308_tape`, thresholds of 16 and
  64 mV) expects exactly this input.
- The level is low besides: a consumer source's 0.3 V RMS is a tenth of
  the range, and there is no gain here.
- Below -0.3 V the pins are outside the chip's absolute ratings, only the
  49.9 ohm limiting the current: a 2 V RMS source reaches -2.8 V.

What a clean recording needs, between the source and the jack, per channel
(**untested**, 2026-11-14; the values are computed, not measured):

```
                        +5 V (a quiet supply)
                          |
                         15k
            4.7 uF        |
  source o----||----------+--------o jack (tip: left, ring: right)
                          |
                         10k
                          |
  source ground o---------+--------o jack sleeve
```

The pin then rests at 2.0 V and the signal swings about it, up to +/-2 V
(1.4 V RMS) before clipping; the corner is 5.6 Hz and the source sees 6
kilohm. An electrolytic capacitor's positive end goes to the jack. For a
2 V RMS source, 6.2 kilohm in series before the capacitor halves it. The
supply's noise is recorded at 0.4 times its size, so it wants to be quiet
(the same 5 V through 100 ohm and 100 uF to ground, for one). The level
this core takes off is then the 2.0 V, as it was written to expect.

For a quick test with no supply: a 1.5 V cell in series with the tip
(positive end to the jack) lifts one channel by 1.5 V.

Still unanswered on a board: a recording of silence (bit errors of the
ADC's serial line at 100 MHz, its SDO taken 30 ns after the SCK edge, 43
at 70 MHz, with no constraint), and Stereo.

## The saga, in order

1. **10-08, milestone A.** The startup chime bit-exact in simulation (the
   lockstep against dingusppc, `run_machine.py --wav`); on the board "to be
   heard". Nobody listened: every board test is a screenshot or a UART line.
2. **10-09, games at half speed** (the user's video of Altair's splash,
   build 39): every Mac OS sound at exactly half speed. Found with the
   trace: Mac OS sets the rate with two read-modify-writes through
   little-endian accessors; our little-endian register read back
   byte-swapped, so the second write put the chime's code back. Fixed in
   build 40 (the register reads back as written; byte and halfword writes
   taken). The same session fixed AWACS keeping a part frame a stopped
   channel left in its FIFO (every later frame byte-shifted) and playing 0
   for a late frame (a click): the part frame is dropped at a stop, a late
   frame holds the last one; `run_scsi.py` test 14 covers both.
3. **10-09, the area cut** (build 43): channel 8 fetches a word per memory
   access instead of a 32-byte line. Suspected later for the crackle; it
   was innocent (the trace showed every command on time).
4. **10-10, "the chime is way too low and crackly"** (the user, build 47).
   The wrong turns, each measured out:
   - *Starved DMA?* The trace (kind 4/5/8 records) timed the ROM's last
     chime command at 2.35 s after the control write: exactly 51,928
     frames at 22,050 Hz. The bench's WAV played the same 2.2 s with no
     frame held. Not starved.
   - *The level?* The codec applies no attenuation; the data peaks at full
     scale. Not the level.
   - *The pitch?* The ROM's chime bytes (the command list at `FFE00020`,
     207,712 bytes from `FFE000A0`) rendered straight to WAV at 22,050 and
     44,100 Hz (`Scratch\rom_chime_*.wav`): the user picked the 22,050 one
     as the real chime on PC speakers, which sent the next hour the wrong
     way, and a phone recording of the board analysed at the right pitch
     (its clicks fooled the ear). Then a scratch build with code 2 at
     44,100 Hz (build 49) chimed "mostly correct", the user re-listened,
     and that settled it.
   - *The output path?* Build 50 added the **sound trace** (`SND_TRACE`:
     the codec's frames into the DDR3 trace, seven a record, kind 13;
     `syn\sndtrace.py` replays a capture and compares it with the ROM's
     chime): every frame the ROM's, none held, and the frame clock measured
     against the PC's clock at 44,247 a second. The output was exact.
   - *The crackle* (about 200 full-scale jumps a second, on a 50 Hz grid
     in the recording): the user's MT32-pi had hung and its I2S stream was
     being mixed in. Restarted and enabled again, no crackle.
   - *No video during the chime?* True (the Mac's video is off until the
     ROM's picture at 30 s) and worth fixing in its own right, but not the
     cause: all system sounds were low too, with the picture on.
5. **The wrong fix, and the right answer** (commit 816eb29, build 52,
   released as the sixth build on 10-10, then withdrawn). On the ear test
   of build 49 the table was changed to code 2 = 44,100 Hz. Hours later,
   listening afresh to build 52, the user heard every sound **an octave
   high**: the original table (code 2 = 22,050 Hz, as dingusppc and Linux)
   had been right all along, as every measurement had said (the codec's
   frames, its clock, the chime's 2.35 s, the recording's pitch, the user's
   own first choice between the two renderings). What had made the sound
   seem low and crackly was the hung MT32-pi's click train, a 50 Hz buzz
   heard as a low tone; build 49 "sounded mostly correct" because the Pi
   had just been restarted, and its octave went unnoticed. The lesson,
   recorded in the memory too: never change a measured hardware behaviour
   on an ear test made while another variable changed at the same time.
   The table is restored (build 54, dated 2026-10-11, the sixth release
   proper); the bench's byte-store rate test is back on code 2; the
   lockstep's chime wait is back to about 150 M instructions. The rest of
   the table (codes 1, 3-7) is still unmeasured on the real chip.
6. **The fallback video** (commit deb6e92, builds 52 and 54): Swatch runs a fixed
   black 640 x 480 at 60 Hz whenever the Mac's timing is off, so the
   framework has a signal from power-up as every other core gives it;
   proven by a black screenshot after shutdown, where screenshots failed
   before.
7. **Altair's startup buzz, parked.** One second of buzz at the game's
   start (after its "reset the monitor depth" dialog), clean sounds after
   and elsewhere. Measured with build 53 (the trace) and build 50 (the
   sound trace): the Sound Manager plays a looping double buffer of 192
   one-millisecond OUTPUT_LAST commands (176 bytes each) with an
   interrupt at each half; every command completes on its millisecond and
   the interrupts are taken within it; the codec plays what is in memory.
   The buzz segments are 8-bit samples expanded by byte replication (as
   every Mac OS sound here) **without the 0x80 sign flip**: silence sits at
   0x8080 (full negative) and every midpoint crossing is a full-scale
   jump. The same from a RAM disk (the app copied there, no SCSI read
   during its start), so the disk path is out; the same glitch on the
   Quadra core (another CPU, another sound chip), so the CPU is out. It is
   the app's startup racing the Sound Manager's conversion on a machine
   slower than a real 7300; whether a real 7300 loses it too is for the
   user's machine to tell. Re-judge after the speed work.

## The tools that exist now

- `run_machine.py --wav FILE`: the codec's output in the bench, 44,100 Hz.
- `syn\wavstat.py FILE.wav [--hold N]`: a WAV's level per 100 ms and its
  held frames.
- `SND_TRACE = 1` with `TRACE = 1` in `MacPPC7300.sv` (build 50 has it):
  the codec's frames in the trace; `syn\sndtrace.py CAPTURE OUT.wav [--rate
  HZ] [--rom releases/boot0.rom]`. The trace path keeps about 270 records a
  second under the Mac's video traffic and all of them with the video
  idle; `trstream.py` loses records when the ring overflows, so long
  captures of sound are patchy and the first 48 s of a capture are the
  previous run's ring. The frame counter in the records is 24 bits (380 s).
- `TRACE = 1` alone (build 53): channel 8's commands (kinds 5, 8, 9), its
  interrupt (kind 11), the codec's register accesses (kind 4), with
  `--trace-mesh` in `cfg` for MESH's.
- `mister.py trace --file CAPTURE` decodes all of them.
- The trace header's record and drop counts, read twice against the PC's
  clock, give the codec's frame rate without a build (`Scratch`'s
  `trcount.py` did it: 44,247 frames a second).
- Driving Mac OS through the Remote: `speedo_run.py`'s pointer-finding
  clicks (`find_pointer`, `move_to`, `click_at`) work for any dialog; a
  menu needs the button held (`ws mouseBtn:left_down`, a move, `left_up`).

## Open

- Codes 1 and 3-7 of the rate table are unmeasured on the real chip.
- Altair's startup buzz (above).
- The CD's audio and the MT32-pi mix are unchanged and untested by ear
  since the rate fix.
- Sound in (channel 9, the ADC) records on a board, half of the wave only
  ("The audio-in jack", above): the bias circuit there, a recording of
  silence, and Stereo are all to be tried. The bench (`adc_tb.sv`) has no
  input resting at 0.
- The user's request: an OSD "Power" button that presses the ADB power key.

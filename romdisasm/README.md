# ROM disassemblies

Annotated disassemblies of the two Apple ROMs this core runs, compressed:

| Archive | ROM | |
|---|---|---|
| `rom7300.tar.xz` | Power Macintosh 7300, `077D.34F2` (the "7300/7600/8600/9600" ROM, the one in `releases/boot0.rom`) | what differs from the 7600's ROM, region by region |
| `rom7600.tar.xz` | Power Macintosh 7600, `077D.28F2` (the "7200/7500/8500/9500 v2" ROM) | the full method and listing format |

Each holds a listing of every region at the address it runs at: the 68k
code, trap tables and resources, the PowerPC start-up code, the NanoKernel,
HWInit, Open Firmware 1.0.5 (its dictionary and detokenized FCode) and the
68k emulator. It also holds the hardware each region touches, and the
scripts in `tools/` that regenerate it all. The ROM images themselves are
not included.

Unpack with:

```
tar -xJf romdisasm/rom7300.tar.xz
```

Each archive's own `README.md` explains its files and how to regenerate
them.

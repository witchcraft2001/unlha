; Sprinter ports and control registers
; Naming matches the manual documentation (manual/) and hardware sources.
; Use: INCLUDE "manual/include/ports.inc"

; ── Memory banking (EMS windows) ────────────────────────────────────────────
EmmWin.P0      EQU     082h    ; memory window #0000-3FFF
EmmWin.P1      EQU     0A2h    ; memory window #4000-7FFF
EmmWin.P2      EQU     0C2h    ; memory window #8000-BFFF
EmmWin.P3      EQU     0E2h    ; memory window #C000-FFFF (PAGE3)

; Convenience aliases (PAGE0..PAGE3)
PAGE0          EQU     EmmWin.P0
PAGE1          EQU     EmmWin.P1
PAGE2          EQU     EmmWin.P2
PAGE3          EQU     EmmWin.P3

; ── Video ────────────────────────────────────────────────────────────────────
RGADR          EQU     089h    ; video line selector / palette address (PORT_Y)
PORT_Y         EQU     RGADR   ; alias used in documentation and SDK

RGMOD          EQU     0C9h    ; double-buffer page select / optional video blank
;   Bit 0: page select  0 = display screen A (#50-#54), 1 = display screen B (#55-#59)
;   Bit 1: video blank  forces BLANK signal in VIDEO2 (only if FPGA built with SCREEN_OFF="USE";
;                       disabled (GND) in standard firmware — bit 1 has no effect by default)
;   Bits [7:2]: unused

; RGMOD page-select values (bit 1 = 0 in standard firmware)
RGMOD_SCR_A    EQU     000h    ; display screen A — standard initial state
RGMOD_SCR_B    EQU     001h    ; display screen B

ALL_MODE       EQU     0C3h    ; graphics/text mode selector
;   Write via Dss.SetVMod (RST #10, C=#50) is preferred.
;   Direct port values (passed to DSS as A register):
;     #02 = text 40×32
;     #03 = text 80×32
;     #81 = graphics 320×256, 8bpp (256 colours)
;     #82 = graphics 640×256, 4bpp (16 colours)

BORDER         EQU     0C2h    ; border colour register (bits [2:0] = colour)
;   Port #CA is an alias for the same register.

; ── VRAM page numbers ────────────────────────────────────────────────────────
; Page #5X where X = %TSPP:
;   T (bit 3) – transparency: skip #FF bytes on write
;   S (bit 2) – VRAM-only:    do not mirror writes to DRAM
;   PP (bits 1..0) – 16 KB offset within the 64 KB video buffer
VPAGE_TILES    EQU     050h    ; normal write (no transparency, DRAM mirrored)
VPAGE_SPRITES  EQU     05Ch    ; transparent (#FF skipped) + VRAM-only (sprites)

; ── System map control ────────────────────────────────────────────────────────
SYS_PORT_OFF   EQU     03Ch    ; disable system map (map 0)
SYS_PORT_ON    EQU     07Ch    ; enable system map (map 1)

; ── Audio ────────────────────────────────────────────────────────────────────
Covox.Port     EQU     0FBh    ; mono Covox / Covox-Blaster DAC data
CBL.Ctrl       EQU     04Eh    ; Covox-Blaster control register
AY.PortA       EQU     0BFFDh  ; AY-3-8910 data port
AY.PortC       EQU     0FFFDh  ; AY-3-8910 register select

; ── ISA bus ──────────────────────────────────────────────────────────────────
ISA.Port       EQU     09FBDh  ; ISA control (A14-A19, RESET/AEN)
ISA.System     EQU     01FFDh  ; ISA system setup / window latch

; ── CMOS / RTC ───────────────────────────────────────────────────────────────
CMOS.DataRead  EQU     0FFBDh  ; CMOS read data port
CMOS.DataWrite EQU     0BFBDh  ; CMOS write data port
CMOS.AdrWrite  EQU     0DFBDh  ; CMOS index register

; ── FDD (VG93) ───────────────────────────────────────────────────────────────
VG93.Port1F    EQU     01Fh    ; VG93 status/command
VG93.Port3F    EQU     03Fh    ; VG93 track register
VG93.Port5F    EQU     05Fh    ; VG93 sector register
VG93.Port7F    EQU     07Fh    ; VG93 data register

; ── IDE ──────────────────────────────────────────────────────────────────────
IDE.Data       EQU     050h    ; IDE data register
IDE.Status     EQU     051h    ; IDE status/command mirror
IDE.SectorCnt  EQU     052h    ; IDE sector count
IDE.SectorNum  EQU     053h    ; IDE sector number (LBA low)
IDE.CylLow     EQU     054h    ; IDE cylinder low (LBA mid)
IDE.CylHigh    EQU     055h    ; IDE cylinder high (LBA high)
IDE.HeadDrv    EQU     056h    ; IDE head / drive select
IDE.Command    EQU     057h    ; IDE command register
IDE.Ctrl3F6    EQU     3F6h    ; IDE device control (reset, nIEN)
IDE.Alt3F7     EQU     3F7h    ; IDE alternate status

; BIOS call numbers (matching bios_equ.asm)
; Use: INCLUDE "manual/include/bios_equ.inc"

Bios.Rst          EQU    08h    ; RST vector for BIOS dispatcher

; EMS / memory windows
Bios.Emm_Fn0      EQU    0C0h   ; query RAM map / free pages
Bios.Emm_Fn1      EQU    0C1h   ; initialize EMS table
Bios.Emm_Fn2      EQU    0C2h   ; allocate block (B pages)
Bios.Emm_Fn3      EQU    0C3h   ; free block by id in A
Bios.Emm_Fn4      EQU    0C4h   ; translate block page# to physical
Bios.Emm_Fn5      EQU    0C5h   ; dump page list into buffer (HL)
Bios.Emm_Fn6      EQU    0C6h   ; read window port + current page
Bios.Emm_Fn7      EQU    0C7h   ; get next page of block (iterator)
Bios.Emm_Fn8      EQU    0C8h   ; reserved (not used in stock ROM)
Bios.Emm_Fn9      EQU    0C9h   ; reserved / future EMS ops

; Window/text services
Bios.Win_Open        EQU  0B0h  ; create BIOS text window
Bios.Win_Close       EQU  0B1h  ; close BIOS window
Bios.Win_Copy_Win    EQU  0B2h  ; copy window contents to buffer
Bios.Win_Restore_Win EQU  0B3h  ; restore window from buffer
Bios.Win_Get_Sym     EQU  0B4h  ; read symbol from window
Bios.Win_Put_Sym     EQU  0B5h  ; write symbol to window
Bios.Win_Set_ZG      EQU  0B6h  ; select character generator
Bios.Win_Move_Win    EQU  0B7h  ; move/resize window
Bios.Win_Get_ZG      EQU  0B8h  ; query current font info

Bios.Lp_Print_All    EQU  081h  ; print text with attribute
Bios.Lp_Print_Sym    EQU  082h  ; print single character
Bios.Lp_Print_Atr    EQU  083h  ; set/print attribute only
Bios.Lp_Set_Place    EQU  084h  ; set cursor position
Bios.Lp_Print_Ln     EQU  085h  ; print string variant #1
Bios.Lp_Print_Ln2    EQU  086h  ; print string variant #2
Bios.Lp_Print_Ln3    EQU  087h  ; print string variant #3
Bios.Lp_Print_Ln4    EQU  088h  ; print string variant #4
Bios.Lp_Cls_Win      EQU  089h  ; clear window
Bios.Lp_Scroll_Up    EQU  08Ah  ; scroll text window
Bios.Lp_Print_Ln5    EQU  08Bh  ; print string variant #5
Bios.Lp_Print_Ln6    EQU  08Ch  ; print string variant #6
Bios.Lp_Cls_Win2     EQU  08Dh  ; alternate clear window
Bios.Lp_Get_Place    EQU  08Eh  ; get cursor position

Bios.SetPalette      EQU  0A4h  ; load palette

; Mouse services use a separate RST vector.
Bios.Mouse_Rst        EQU 030h
Bios.Mouse_Init       EQU 000h
Bios.Mouse_HideCursor EQU 002h
Bios.Mouse_Read       EQU 003h

; Drive services
Bios.Drv_Reset       EQU  051h  ; reset drive/controller
Bios.Drv_Verify      EQU  054h  ; verify sectors
Bios.Drv_Read        EQU  055h  ; read sector(s)
Bios.Drv_Write       EQU  056h  ; write sector(s)
Bios.Drv_Detect      EQU  057h  ; detect attached drives
Bios.Drv_Get_Par     EQU  058h  ; get drive parameters
Bios.Drv_Set_Par     EQU  059h  ; set drive parameters
Bios.Ext_Version     EQU  05Ah  ; report BIOS extension version
Bios.Drv_List        EQU  05Fh  ; enumerate physical drives

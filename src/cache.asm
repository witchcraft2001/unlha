; ====================================================================
;   SRAM CACHE инфраструктура (Этап 5).
;   В turbo-режиме (21 МГц) обращения к SRAM окна 0 идут без wait-состояний.
;   «Горячий» код и таблицы лежат в EXE (WIN1), копируются в SRAM WIN0
;   на старте (InitSramBundle) и исполняются при CASH_ON=1.
;
;   Раскладка SRAM WIN0 (#0000-#3FFF), активна только при CASH_ON=1:
;     #3800-#38FF  CRC16: младшие байты table[256]   (SramCrcTableLo)
;     #3900-#39FF  CRC16: старшие байты table[256]    (SramCrcTableHi)
;     #3A00-...    кэш-код (DISP-бандл, CacheCrc16Update)
;   EXE-код/данные/стек в WIN1 (#4200+), поэтому #0000-#37FF в WIN0 пока
;   свободны под BSS/таблицы декодеров будущих шагов Этапа 5.
;
;   ПРАВИЛА (как в sprinter-unzip/gifview):
;   - Пока CASH_ON=1: WIN0 = SRAM; RST #08/#10/#30/#38 и прерывания НЕЛЬЗЯ
;     (векторы попадут в содержимое SRAM). EnterCacheWindow делает DI.
;   - Любой вызов DSS/BIOS — только при CASH_OFF (вне кэша).
;   - WIN1/WIN2/WIN3 при CASH_ON не меняются и доступны (буферы, (Crc16)).
; ====================================================================

; Порты управления кэшем (см. CLAUDE.md, sprinter-unzip, gifview).
CacheOnPort     EQU     #FB         ; IN -> CASH_ON = 1 (WIN0 = SRAM)
CacheOffPort    EQU     #7B         ; IN -> CASH_ON = 0
SysMapCache     EQU     #04         ; system map -> режим SRAM (OUT #3C)
SysMapDss       EQU     #03         ; system map -> режим DSS
IsaSystemDss    EQU     #01         ; ISA system (#1FFD) -> режим DSS
; SYS_PORT_OFF (#3C) и ISA.System (#1FFD) определены в ports.inc.

; Раскладка SRAM.
SramCrcTableLo  EQU     #3800
SramCrcTableHi  EQU     #3900       ; обязан быть SramCrcTableLo + #100
SramCacheCode   EQU     #3A00
SramPageEnd     EQU     #4000
        ASSERT  SramCrcTableHi == SramCrcTableLo + #100
        ASSERT  (SramCrcTableLo & #FF) == 0    ; таблицы выровнены по странице

; ====================================================================
; Инициализация SRAM-блока (один раз на старте). Портит AF,BC,DE,HL.
; ====================================================================
InitSramBundle:
        CALL    EnterCacheWindow
        LD      HL,CacheCodeStored          ; байты бандла лежат в EXE (WIN1)
        LD      DE,SramCacheCode            ; -> SRAM WIN0
        LD      BC,CacheCodeStoredEnd - CacheCodeStored
        LDIR
        CALL    BuildCrc16Table             ; таблица CRC16 прямо в SRAM
        JP      RestoreSystemWindow         ; tail (делает EI), RET вызвавшему

; Построить таблицу CRC16/ARC (полином #A001) в SRAM, раздельно lo/hi.
; Вызывается при CASH_ON=1 (пишет в WIN0). Портит AF,BC,DE,HL.
BuildCrc16Table:
        LD      HL,SramCrcTableLo           ; H = страница lo, L = индекс
.byte:
        LD      A,L                         ; c = index
        LD      E,A
        LD      D,0
        LD      B,8
.bit:
        SRL     D                           ; c >>= 1 ; CF = вытолкнутый LSB
        RR      E
        JR      NC,.noxor
        LD      A,D                         ; c ^= #A001
        XOR     #A0
        LD      D,A
        LD      A,E
        XOR     #01
        LD      E,A
.noxor:
        DJNZ    .bit
        LD      (HL),E                      ; SramCrcTableLo[index]
        INC     H
        LD      (HL),D                      ; SramCrcTableHi[index]
        DEC     H
        INC     L
        JR      NZ,.byte                    ; пока L не обернётся (256 записей)
        RET

; ====================================================================
; Вход/выход в SRAM-окно. Портит AF (BC сохраняется).
; EnterCacheWindow делает DI; RestoreSystemWindow делает EI.
; ====================================================================
EnterCacheWindow:
        PUSH    BC
        XOR     A
        LD      BC,ISA.System               ; #1FFD
        OUT     (C),A                       ; ISA system <- 0
        LD      A,SysMapCache
        OUT     (SYS_PORT_OFF),A            ; #3C <- 4 (режим SRAM)
        DI
        IN      A,(CacheOnPort)             ; CASH_ON = 1
        POP     BC
        RET

RestoreSystemWindow:
        PUSH    BC
        IN      A,(CacheOffPort)            ; CASH_ON = 0
        LD      A,SysMapDss
        OUT     (SYS_PORT_OFF),A            ; #3C <- 3 (режим DSS)
        LD      BC,ISA.System
        LD      A,IsaSystemDss
        OUT     (C),A                       ; ISA system <- 1
        EI
        POP     BC
        RET

; ====================================================================
; SRAM-бандл: хранится в EXE, копируется в SramCacheCode, исполняется
; только при CASH_ON=1. Метки внутри ассемблируются под адреса SRAM.
; ====================================================================
CacheCodeStored:
        DISP    SramCacheCode

; CacheCrc16Update: CRC16/ARC по BC байтам из HL -> (Crc16).
;   Таблично (1 поиск/байт вместо 8 итераций). (Crc16) и буфер — в WIN1/WIN3,
;   доступны при CASH_ON. Портит AF,BC,DE,HL (IY сохраняется).
CacheCrc16Update:
        LD      A,B
        OR      C
        RET     Z
        PUSH    IY
        PUSH    HL
        POP     IY                          ; IY = указатель буфера
        LD      DE,(Crc16)                  ; D = старший, E = младший
.next:
        LD      A,(IY+0)
        INC     IY
        XOR     E                           ; idx = byte ^ crc_lo
        LD      L,A
        LD      H,high(SramCrcTableLo)
        LD      A,D                          ; младший байт (crc>>8)
        XOR     (HL)                         ; ^ table_lo[idx]
        LD      E,A
        INC     H                            ; -> страница SramCrcTableHi
        LD      D,(HL)                       ; crc_hi = table_hi[idx]
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,.next
        LD      (Crc16),DE
        POP     IY
        RET
CacheCodeRuntimeEnd:
        ASSERT  CacheCodeRuntimeEnd <= SramPageEnd
        ENT
CacheCodeStoredEnd:
        ASSERT  CacheCrc16Update == SramCacheCode

; --- Раскладка рабочих массивов lh1 в SRAM WIN0 (этап 5B) ---
; lh1 держит CASH_ON весь декод; freq/son/prnt/TextBuf лежат в SRAM и не должны
; пересекаться ни между собой, ни с CRC-таблицей (#3800). Константы заданы в
; lh1.asm; размеры — из LH1_T/LH1_NCHAR. Проверяем здесь (всё уже определено).
        ASSERT  FreqBase >= TextBufBase + LH1_N
        ASSERT  SonBase  >= FreqBase + (LH1_T+1)*2
        ASSERT  PrntBase >= SonBase + LH1_T*2
        ASSERT  PrntBase + (LH1_T+LH1_NCHAR)*2 <= SramCrcTableLo

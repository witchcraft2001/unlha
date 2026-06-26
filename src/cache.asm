; ====================================================================
;   SRAM CACHE инфраструктура (Этап 5).
;   В turbo-режиме (21 МГц) обращения к SRAM окна 0 идут без wait-состояний.
;   «Горячий» код и таблицы лежат в EXE (WIN1), копируются в SRAM WIN0
;   на старте (InitSramBundle) и исполняются при CASH_ON=1.
;
;   Раскладка SRAM WIN0 (#0000-#3FFF), активна только при CASH_ON=1.
;   Аппаратно видимый 16K-bank выбирается через FastRAM.SLOT0/ROM_RG[1:0]:
;     bank 0: -lh1- workspace/code + общий CRC16
;     bank 1: -lh5- workspace/code + локальный CRC16
;
;   Раскладка bank 0:
;     #3800-#38FF  CRC16: младшие байты table[256]   (SramCrcTableLo)
;     #3900-#39FF  CRC16: старшие байты table[256]    (SramCrcTableHi)
;     #3A00-...    кэш-код (DISP-бандл, CacheCrc16Update)
;   Раскладка bank 1 задаётся в lh5.asm.
;
;   ПРАВИЛА (как в sprinter-unzip/gifview):
;   - Пока CASH_ON=1: WIN0 = SRAM; RST #08/#10/#30/#38 и прерывания НЕЛЬЗЯ
;     (векторы попадут в содержимое SRAM). EnterCacheWindow делает DI.
;   - Любой вызов DSS/BIOS — только при CASH_OFF (вне кэша).
;   - WIN1/WIN2/WIN3 при CASH_ON не меняются и доступны (буферы, (Crc16)).
; ====================================================================

; Порты управления кэшем (см. CLAUDE.md, sprinter-unzip, gifview, BIOS FastRAM).
CacheOnPort     EQU     #FB         ; IN -> CASH_ON = 1 (WIN0 = SRAM)
CacheOffPort    EQU     #7B         ; IN -> CASH_ON = 0
FastRamSlot0Port EQU    #5C         ; external FastRAM.SLOT0; works under SYS_PORT_ON
CacheBankLh1    EQU     #00
CacheBankLh5    EQU     #01
SysMapCache     EQU     #04         ; system map -> режим SRAM (OUT #3C)
SysMapDss       EQU     #03         ; system map -> режим DSS
SysRomPage0     EQU     #01         ; SYS_PORT_ON data: ROM page numbering 0..15
IsaSystemDss    EQU     #01         ; ISA system (#1FFD) -> режим DSS
; SYS_PORT_ON/OFF (#7C/#3C) и ISA.System (#1FFD) определены в ports.inc.

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
        CALL    EnterCacheWindowLh1
        LD      HL,CacheCodeStored          ; байты CRC-бандла лежат в EXE (WIN1)
        LD      DE,SramCacheCode            ; -> SRAM WIN0 (#3A00)
        LD      BC,CacheCodeStoredEnd - CacheCodeStored
        LDIR
        LD      HL,Lh1CacheStored           ; ядро декодера -lh1- (этап 5C)
        LD      DE,SramLh1Code              ; -> SRAM WIN0 (#2200)
        LD      BC,Lh1CacheStoredEnd - Lh1CacheStored
        LDIR
        CALL    BuildCrc16Table             ; таблица CRC16 прямо в SRAM bank 0
        CALL    RestoreSystemWindow         ; CASH_OFF (без EI)
        CALL    EnterCacheWindowLh5
        LD      HL,Lh5CacheStored           ; весь runtime image -lh5-
        LD      DE,SramLh5Code              ; -> SRAM bank 1
        LD      BC,Lh5CacheStoredEnd - Lh5CacheStored
        LDIR
        CALL    BuildLh5Crc16Table          ; локальная CRC16-таблица в SRAM bank 1
        CALL    RestoreSystemWindow         ; CASH_OFF (без EI)
        EI                                  ; вернуть обычный поток DSS (EI)
        RET

; Построить таблицу CRC16/ARC (полином #A001) в SRAM, раздельно lo/hi.
; Вызывается при CASH_ON=1 (пишет в WIN0). Портит AF,BC,DE,HL.
BuildCrc16Table:
        LD      HL,SramCrcTableLo           ; H = страница lo, L = индекс
        JR      BuildCrc16TableAtHL

BuildLh5Crc16Table:
        LD      HL,SramLh5CrcTableLo        ; H = страница lo, L = индекс
BuildCrc16TableAtHL:
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
; Вход/выход в SRAM-окно (модель sprinter-unzip). Портит AF (BC сохраняется).
;   EnterCacheWindow      — CASH_ON + DI.
;   RestoreSystemWindow   — CASH_OFF; прерывания НЕ трогает.
; Декодер держит DI весь проход, включая DSS-границы (Restore->DSS->Enter):
; прерывание в момент переключения карты памяти/кэша портит состояние. EI
; выполняется ЯВНО вызывающим при возврате к обычному потоку DSS — на трёх
; границах верхнего уровня: InitSramBundle, Crc16Update (вне кэша), конец
; DecodeLh1. На DSS-границах внутри декода EI не делается (DI держится).
; ====================================================================
; По manual + FPGA (SP2_ACEX.TDF): CASH_ON защёлкивается от IN #FB/#7B
; (бит A7), номер SRAM-bank берётся из ROM_RG[1:0]. В BIOS FastRAM.SLOT0 — это
; внешний порт #5C, который переключает страницы только при SYS_PORT.ROM (#7C).
; Прямой OUT #8F здесь не годится: #8F — внутренний DCP-порт.
; Портит AF.
EnterCacheWindow:
EnterCacheWindowLh1:
        PUSH    BC
        DI                                  ; в кэш-окне прерывания нельзя
        XOR     A
        LD      BC,ISA.System
        OUT     (C),A                       ; #1FFD <- 0, как в sprinter-unzip
        XOR     A                           ; SRAM bank 0: -lh1-/общий CRC
        CALL    SelectCacheBank             ; через SYS_PORT_ON + FastRAM.SLOT0
        LD      A,SysMapCache
        OUT     (SYS_PORT_OFF),A            ; #3C <- 4, system map для SRAM
        IN      A,(CacheOnPort)             ; CASH_ON = 1 (WIN0 = SRAM)
        POP     BC
        RET

EnterCacheWindowLh5:
        PUSH    BC
        DI
        XOR     A
        LD      BC,ISA.System
        OUT     (C),A                       ; #1FFD <- 0
        LD      A,CacheBankLh5              ; SRAM bank 1: -lh5-
        CALL    SelectCacheBank
        LD      A,SysMapCache
        OUT     (SYS_PORT_OFF),A            ; #3C <- 4
        IN      A,(CacheOnPort)             ; CASH_ON = 1
        POP     BC
        RET

EnterHeldCacheWindow:
        LD      A,(CacheHeld)
        CP      CacheBankLh5 + 1            ; CacheHeld=2 -> -lh5- bank 1
        JP      Z,EnterCacheWindowLh5
        JP      EnterCacheWindowLh1

RestoreSystemWindow:                        ; CASH_OFF; прерывания не трогаем
        PUSH    BC
        XOR     A                           ; перед CASH_OFF вернуть ROM_RG bank 0
        CALL    SelectCacheBank
        LD      A,SysMapCache
        OUT     (SYS_PORT_OFF),A            ; вернуть cache-map перед IN #7B
        IN      A,(CacheOffPort)            ; CASH_ON = 0 (WIN0 -> DSS-ROM/DRAM)
        LD      A,SysMapDss
        OUT     (SYS_PORT_OFF),A            ; #3C <- 3, system map DSS
        LD      BC,ISA.System
        LD      A,IsaSystemDss
        OUT     (C),A                       ; #1FFD <- 1
        POP     BC
        RET

; SelectCacheBank: A = 0..3. Переключение FastRAM.SLOT0 (#5C) работает только
; при SYS_PORT.ROM, поэтому кратко открываем SYS_PORT_ON и сразу возвращаем
; карту вызывающему коду. Портит только AF.
SelectCacheBank:
        PUSH    AF
        LD      A,SysRomPage0
        OUT     (SYS_PORT_ON),A
        POP     AF
        OUT     (FastRamSlot0Port),A
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
        ASSERT  SramLh1Code >= PrntBase + (LH1_T+LH1_NCHAR)*2  ; ядро после массивов
        ASSERT  Lh1Vars >= Lh1CacheRuntimeEnd                  ; переменные после кода
        ASSERT  Lh1VarsEnd <= SramCrcTableLo                   ; переменные до CRC-таблицы

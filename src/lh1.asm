; ====================================================================
;   Декодер -lh1- (LZHUF): LZSS + адаптивный Хаффман, окно 4 КБ.
;   Порт проверенного Python-эталона (LZHUF.C). Этап 4.
;   Этап 5C: вычислительное ядро (DecodeChar/Update/UpdateSwap/Reconst/
;   DecodePosition/GetWord/PutWord) вынесено в SRAM WIN0 (DISP-бандл
;   #2200) — выборка кода без wait-состояний. Ядро не делает DSS, поэтому
;   ловушки «возврат в SRAM после выключения кэша» нет. Главный цикл,
;   копирование совпадений, Lh1PutByte/Lh1Flush (с DSS-трамплинами) и
;   StartHuff остаются в DRAM (WIN1) и зовут SRAM-ядро при CASH_ON.
; ====================================================================
; Использует из lh5.asm: GetFilePos, CalcCompRemaining, InitBitReader,
; GetBits, RemainingZero, MapDataPages; из unlha.asm: Crc16Update.

LH1_N           EQU 4096
LH1_F           EQU 60
LH1_THRESH      EQU 2
LH1_NCHAR       EQU 314             ; 256 - THRESHOLD + F
LH1_T           EQU 627             ; NCHAR*2-1
LH1_R           EQU 626             ; корень
LH1_MAXFREQ     EQU #8000

; Рабочие массивы lh1 — в SRAM WIN0 (этап 5B): декод держит CASH_ON, поэтому
; обращения к дереву идут без wait-состояний. Выходной буфер остаётся в WIN3
; (#C000), т.к. сбрасывается через DSS (вне кэша). Раскладка не пересекается
; с кодом-ядром (#2200) и CRC-таблицей (#3800) — проверяется ASSERT в cache.asm.
TextBufBase     EQU #0000           ; окно 4096 байт (SRAM)
FreqBase        EQU #1000           ; freq[T+1] слов  (628*2 -> #1000-#14E7)
SonBase         EQU #1500           ; son[T] слов      (627*2 -> #1500-#19E5)
PrntBase        EQU #1A00           ; prnt[T+NCHAR] слов (941*2 -> #1A00-#2179)
SramLh1Code     EQU #2200           ; SRAM-бандл ядра декодера (этап 5C)
Lh1OutBuf       EQU #C000           ; выходной буфер 4096 (WIN3, не кэш)
Lh1OutBufLen    EQU 4096

; Рабочие переменные lh1 — в SRAM WIN0 (этап 5O-3): доступ без wait-состояний.
; Все пишутся до чтения при CASH_ON (init Lh1OutPos перенесён после Enter), так
; что неинициализированный SRAM безопасен. Адреса самовычисляемые (prev+размер).
Lh1Vars         EQU #3000
Lh1R            EQU Lh1Vars + 0
Lh1OutPos       EQU Lh1R + 2
Lh1Len          EQU Lh1OutPos + 2
Lh1MatchI       EQU Lh1Len + 2
Lh1I            EQU Lh1MatchI + 2
Lh1J            EQU Lh1I + 2
Lh1Cv           EQU Lh1J + 2
Lh1K            EQU Lh1Cv + 2
Lh1L            EQU Lh1K + 2
Lh1Ti           EQU Lh1L + 2
Lh1Tj           EQU Lh1Ti + 2
Lh1Pos          EQU Lh1Tj + 2
Lh1C            EQU Lh1Pos + 2
Lh1I8           EQU Lh1C + 2
Lh1JBits        EQU Lh1I8 + 1
Lh1Ri           EQU Lh1JBits + 1
Lh1Rj           EQU Lh1Ri + 2
Lh1Rk           EQU Lh1Rj + 2
Lh1Rf           EQU Lh1Rk + 2
Lh1Rcnt         EQU Lh1Rf + 2
Lh1Rsrc         EQU Lh1Rcnt + 2
Lh1Tson         EQU Lh1Rsrc + 2
Lh1VarsEnd      EQU Lh1Tson + 2

; ====================================================================
DecodeLh1:
        CALL    GetFilePos
        LD      (DataStart),IX
        LD      (DataStart+2),HL
        CALL    CalcCompRemaining
        CALL    InitBitReader
        LD      HL,(HdrBuf+#0B)
        LD      (Remaining),HL
        LD      HL,(HdrBuf+#0D)
        LD      (Remaining+2),HL
        LD      HL,0
        LD      (Crc16),HL                  ; Crc16 — в DRAM (читается вне кэша)
        ; --- войти в кэш и держать CASH_ON весь декод (массивы дерева + ядро
        ; + переменные lh1 в SRAM). DSS-init выше (GetFilePos/InitBitReader) сделан
        ; вне кэша. Дальше DSS только на границах RefillInBuf/Lh1Flush (трамплины).
        LD      A,1
        LD      (CacheHeld),A
        CALL    EnterCacheWindow
        LD      HL,0                        ; Lh1OutPos в SRAM -> init после Enter
        LD      (Lh1OutPos),HL
        CALL    Lh1InitWindow               ; пишет SRAM TextBuf (CASH_ON)
        CALL    StartHuff                   ; пишет SRAM freq/son/prnt (CASH_ON)
        CALL    CacheLh1Loop                ; основной цикл декода — в SRAM
        CALL    Lh1Flush                    ; финальный сброс (трамплинит DSS-запись)
        CALL    RestoreSystemWindow         ; выйти из кэша (CASH_OFF, без EI)
        EI                                  ; вернуть обычный поток DSS (EI)
        XOR     A
        LD      (CacheHeld),A
        RET

; Окно: text_buf[0..N-F-1] = ' '(0x20), r = N-F.  (DRAM; пишет SRAM TextBuf)
Lh1InitWindow:
        LD      HL,TextBufBase
        LD      (HL),#20
        LD      DE,TextBufBase+1
        LD      BC,LH1_N-LH1_F-1
        LDIR
        LD      HL,LH1_N-LH1_F
        LD      (Lh1R),HL
        RET

; Lh1PutByte перенесён в SRAM-бандл (этап 5O: горячий — на каждый выходной байт).

; DRAM: CRC через SRAM-процедуру (кэш держится), DSS-запись — вне кэша.
Lh1Flush:
        LD      HL,(Lh1OutPos)
        LD      A,H
        OR      L
        RET     Z
        LD      BC,(Lh1OutPos)              ; число байт (Lh1OutPos в SRAM, CASH_ON)
        PUSH    BC                          ; сохранить: CRC портит BC, а после
        LD      HL,Lh1OutBuf                ; RestoreSystemWindow SRAM недоступен
        CALL    Crc16Update                 ; cache-aware (прямой CacheCrc16 в кэше)
        POP     DE                          ; DE = число байт (из регистра, не из SRAM!)
        ; --- DSS-запись на границе: Restore->DSS->Enter, БЕЗ EI (DI весь декод).
        ; Lh1OutPos лежит в SRAM и при CASH_OFF недоступен — счётчик уже в DE.
        LD      A,(CacheHeld)
        OR      A
        CALL    NZ,RestoreSystemWindow
        LD      HL,Lh1OutBuf
        LD      A,(OutHandle)
        LD      C,Dss.Write
        RST     Dss.Rst
        CALL    MapDataPages
        LD      A,(CacheHeld)
        OR      A
        CALL    NZ,EnterCacheWindow
        RET

; ====================================================================
; StartHuff — инициализация дерева. (DRAM; зовёт SRAM GetWord/PutWord при CASH_ON)
; ====================================================================
StartHuff:
        ; freq[0..NCHAR-1] = 1
        LD      HL,FreqBase
        LD      DE,LH1_NCHAR
.f1:
        LD      (HL),1
        INC     HL
        LD      (HL),0
        INC     HL
        DEC     DE
        LD      A,D
        OR      E
        JR      NZ,.f1
        ; son[i] = i + T  (i = 0..NCHAR-1)
        LD      HL,SonBase
        LD      DE,LH1_T
        LD      BC,LH1_NCHAR
.f2:
        LD      (HL),E
        INC     HL
        LD      (HL),D
        INC     HL
        INC     DE
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,.f2
        ; prnt[T+i] = i
        LD      HL,PrntBase + LH1_T*2
        LD      DE,0
        LD      BC,LH1_NCHAR
.f3:
        LD      (HL),E
        INC     HL
        LD      (HL),D
        INC     HL
        INC     DE
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,.f3
        ; внутренние узлы: i=0, j=NCHAR; while j<=R
        LD      HL,LH1_NCHAR
        LD      (Lh1J),HL
        LD      HL,0
        LD      (Lh1I),HL
.in:
        LD      HL,(Lh1J)
        LD      DE,LH1_R
        OR      A
        SBC     HL,DE
        JR      Z,.ineq
        JR      NC,.indone                  ; j > R
.ineq:
        LD      HL,(Lh1I)                   ; freq[j] = freq[i]+freq[i+1]
        LD      DE,FreqBase
        CALL    Lh1GetWord
        PUSH    HL
        LD      HL,(Lh1I)
        INC     HL
        LD      DE,FreqBase
        CALL    Lh1GetWord
        POP     DE
        ADD     HL,DE
        LD      B,H
        LD      C,L
        LD      HL,(Lh1J)
        LD      DE,FreqBase
        CALL    Lh1PutWord
        LD      BC,(Lh1I)                   ; son[j] = i
        LD      HL,(Lh1J)
        LD      DE,SonBase
        CALL    Lh1PutWord
        LD      BC,(Lh1J)                   ; prnt[i] = j
        LD      HL,(Lh1I)
        LD      DE,PrntBase
        CALL    Lh1PutWord
        LD      BC,(Lh1J)                   ; prnt[i+1] = j
        LD      HL,(Lh1I)
        INC     HL
        LD      DE,PrntBase
        CALL    Lh1PutWord
        LD      HL,(Lh1I)                   ; i += 2
        INC     HL
        INC     HL
        LD      (Lh1I),HL
        LD      HL,(Lh1J)                   ; j++
        INC     HL
        LD      (Lh1J),HL
        JR      .in
.indone:
        LD      HL,LH1_T                    ; freq[T] = 0xFFFF
        LD      DE,FreqBase
        LD      BC,#FFFF
        CALL    Lh1PutWord
        LD      HL,LH1_R                    ; prnt[R] = 0
        LD      DE,PrntBase
        LD      BC,0
        CALL    Lh1PutWord
        RET

; ====================================================================
; SRAM-бандл ядра декодера (этап 5C). Хранится в EXE, копируется в
; SramLh1Code на старте (InitSramBundle), исполняется только при CASH_ON.
; Метки внутри ассемблируются под адреса SRAM; out-вызовы (GetBits) и
; данные (Lh1Cv/.../Lh1DCode/Lh1DLen) — по абсолютным адресам WIN1.
; ====================================================================
Lh1CacheStored:
        DISP    SramLh1Code

; Доступ к словным массивам: HL=индекс, DE=база.
Lh1GetWord:                                 ; -> HL = word[index]; сохраняет DE
        ADD     HL,HL
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        RET

Lh1PutWord:                                 ; HL=index, DE=база, BC=значение
        ADD     HL,HL
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        RET

; ====================================================================
; DecodeChar -> HL = c (0..NCHAR-1).
; ====================================================================
DecodeChar:
        LD      HL,(SonBase + LH1_R*2)      ; c = son[R] (R константа -> прямой адрес)
.walk:
        LD      DE,LH1_T                    ; while c < T
        PUSH    HL
        OR      A
        SBC     HL,DE
        POP     HL
        JR      NC,.leaf                    ; c >= T
        PUSH    HL                          ; c = son[c + bit]
        LD      B,1
        CALL    CacheGetBits                ; SRAM-битридер
        LD      A,L
        POP     HL
        ADD     A,L
        LD      L,A
        LD      A,0
        ADC     A,H
        LD      H,A                         ; HL = c + bit
        ADD     HL,HL                       ; son[c+bit] (инлайн Lh1GetWord)
        LD      DE,SonBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        JR      .walk
.leaf:
        LD      DE,LH1_T                    ; c -= T
        OR      A
        SBC     HL,DE
        PUSH    HL                          ; символ-возврат (Lh1Update портит Lh1Cv)
        LD      (Lh1Cv),HL                  ; вход для Lh1Update
        CALL    Lh1Update
        POP     HL                          ; вернуть исходный символ
        RET

; ====================================================================
; DecodePosition -> HL = position (0..N-1).
; ====================================================================
DecodePosition:
        LD      B,8
        CALL    CacheGetBits                ; i = байт (SRAM-битридер)
        LD      A,L
        LD      (Lh1I8),A
        LD      H,0                          ; c = d_code[i] << 6
        LD      L,A
        LD      DE,Lh1DCode
        ADD     HL,DE
        LD      A,(HL)
        LD      H,0
        LD      L,A
        ADD     HL,HL
        ADD     HL,HL
        ADD     HL,HL
        ADD     HL,HL
        ADD     HL,HL
        ADD     HL,HL
        LD      (Lh1C),HL
        LD      A,(Lh1I8)                   ; i (16-бит) = байт
        LD      L,A
        LD      H,0
        LD      (Lh1Pos),HL
        LD      A,(Lh1I8)                   ; j = d_len[i] - 2
        LD      L,A
        LD      H,0
        LD      DE,Lh1DLen
        ADD     HL,DE
        LD      A,(HL)
        SUB     2
        LD      (Lh1JBits),A
.lp:
        LD      A,(Lh1JBits)
        OR      A
        JR      Z,.fin
        DEC     A
        LD      (Lh1JBits),A
        LD      HL,(Lh1Pos)                 ; i <<= 1
        ADD     HL,HL
        LD      (Lh1Pos),HL
        LD      B,1
        CALL    CacheGetBits                ; bit (SRAM-битридер)
        LD      A,L
        OR      A
        JR      Z,.lp
        LD      HL,(Lh1Pos)                 ; i |= 1
        SET     0,L
        LD      (Lh1Pos),HL
        JR      .lp
.fin:
        LD      HL,(Lh1Pos)                 ; return c | (i & 0x3F)
        LD      A,L
        AND     #3F
        LD      L,A
        LD      H,0
        LD      DE,(Lh1C)
        ADD     HL,DE
        RET

; ====================================================================
; update(c) — частоты и реструктуризация.
; ====================================================================
Lh1Update:
        LD      HL,(FreqBase + LH1_R*2)     ; freq[R] (прямой адрес) == MAX_FREQ?
        LD      DE,LH1_MAXFREQ
        OR      A
        SBC     HL,DE
        JR      NZ,.nrec
        CALL    Lh1Reconst
.nrec:
        LD      HL,(Lh1Cv)                  ; c = prnt[c+T] (инлайн Lh1GetWord)
        LD      DE,LH1_T
        ADD     HL,DE
        ADD     HL,HL
        LD      DE,PrntBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        LD      (Lh1Cv),HL
.uloop:
        ; freq[c]++ на месте; k = freq[c]; freq[l]=freq[c+1] по смежному адресу
        LD      HL,(Lh1Cv)                  ; &freq[c]
        ADD     HL,HL
        LD      DE,FreqBase
        ADD     HL,DE
        INC     (HL)                        ; freq[c]++ (16 бит)
        JR      NZ,.kinc
        INC     HL
        INC     (HL)
        DEC     HL
.kinc:
        LD      E,(HL)                      ; k = freq[c] -> DE ; HL = &freq[c].hi
        INC     HL
        LD      D,(HL)
        LD      (Lh1K),DE                   ; k нужен Lh1UpdateSwap
        INC     HL                          ; -> &freq[l].lo (freq[c+1] смежно)
        LD      C,(HL)
        INC     HL
        LD      B,(HL)                      ; BC = freq[l]
        LD      HL,(Lh1Cv)                  ; l = c+1 (нужен Lh1UpdateSwap)
        INC     HL
        LD      (Lh1L),HL
        LD      H,D                         ; HL = k
        LD      L,E
        OR      A                           ; k > freq[l] ?
        SBC     HL,BC
        JR      Z,.noswap
        JR      C,.noswap
        CALL    Lh1UpdateSwap               ; сам ставит Lh1Cv = l
.noswap:
        LD      HL,(Lh1Cv)                  ; c = prnt[c] (инлайн Lh1GetWord)
        ADD     HL,HL
        LD      DE,PrntBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        LD      (Lh1Cv),HL
        LD      A,H
        OR      L
        JR      NZ,.uloop
        RET

; Инлайн Lh1GetWord/Lh1PutWord по всем сайтам (свопы часты при перестройке дерева).
; GetWord: ADD HL,HL / ADD HL,DE / LD A,(HL)/INC HL/LD H,(HL)/LD L,A.
; PutWord: ADD HL,HL / ADD HL,DE / LD (HL),C/INC HL/LD (HL),B.
Lh1UpdateSwap:
.fl:
        LD      HL,(Lh1L)                   ; while k > freq[l+1]: l++
        INC     HL
        ADD     HL,HL                       ; freq[l+1]
        LD      DE,FreqBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        LD      DE,(Lh1K)
        EX      DE,HL                       ; HL=k, DE=freq[l+1]
        OR      A
        SBC     HL,DE
        JR      Z,.fld
        JR      C,.fld
        LD      HL,(Lh1L)
        INC     HL
        LD      (Lh1L),HL
        JR      .fl
.fld:
        LD      HL,(Lh1L)                   ; freq[c] = freq[l]
        ADD     HL,HL
        LD      DE,FreqBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A                         ; HL = freq[l]
        LD      B,H
        LD      C,L
        LD      HL,(Lh1Cv)
        ADD     HL,HL
        LD      DE,FreqBase
        ADD     HL,DE
        LD      (HL),C                      ; freq[c] = freq[l]
        INC     HL
        LD      (HL),B
        LD      BC,(Lh1K)                   ; freq[l] = k
        LD      HL,(Lh1L)
        ADD     HL,HL
        LD      DE,FreqBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        LD      HL,(Lh1Cv)                  ; i = son[c]
        ADD     HL,HL
        LD      DE,SonBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        LD      (Lh1Ti),HL
        LD      BC,(Lh1L)                   ; prnt[i] = l
        LD      HL,(Lh1Ti)
        ADD     HL,HL
        LD      DE,PrntBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        LD      HL,(Lh1Ti)                  ; if i<T: prnt[i+1]=l
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JR      NC,.skip1
        LD      BC,(Lh1L)
        LD      HL,(Lh1Ti)
        INC     HL
        ADD     HL,HL
        LD      DE,PrntBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
.skip1:
        LD      HL,(Lh1L)                   ; jj = son[l]
        ADD     HL,HL
        LD      DE,SonBase
        ADD     HL,DE
        LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        LD      (Lh1Tj),HL
        LD      BC,(Lh1Ti)                  ; son[l] = i
        LD      HL,(Lh1L)
        ADD     HL,HL
        LD      DE,SonBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        LD      BC,(Lh1Cv)                  ; prnt[jj] = c
        LD      HL,(Lh1Tj)
        ADD     HL,HL
        LD      DE,PrntBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        LD      HL,(Lh1Tj)                  ; if jj<T: prnt[jj+1]=c
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JR      NC,.skip2
        LD      BC,(Lh1Cv)
        LD      HL,(Lh1Tj)
        INC     HL
        ADD     HL,HL
        LD      DE,PrntBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
.skip2:
        LD      BC,(Lh1Tj)                  ; son[c] = jj
        LD      HL,(Lh1Cv)
        ADD     HL,HL
        LD      DE,SonBase
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        LD      HL,(Lh1L)                   ; c = l
        LD      (Lh1Cv),HL
        RET

; ====================================================================
; reconst — перестройка дерева (freq[R] достиг MAX_FREQ).
; ====================================================================
Lh1Reconst:
        ; фаза 1: собрать листья
        LD      HL,0
        LD      (Lh1Rj),HL
        LD      (Lh1Ri),HL
.p1:
        LD      HL,(Lh1Ri)
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JR      NC,.p1d
        LD      HL,(Lh1Ri)                  ; son[i]
        LD      DE,SonBase
        CALL    Lh1GetWord
        LD      (Lh1Tson),HL
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JR      C,.p1n                      ; son[i] < T -> пропуск
        LD      HL,(Lh1Ri)                  ; freq[j] = (freq[i]+1)/2
        LD      DE,FreqBase
        CALL    Lh1GetWord
        INC     HL
        SRL     H
        RR      L
        LD      B,H
        LD      C,L
        LD      HL,(Lh1Rj)
        LD      DE,FreqBase
        CALL    Lh1PutWord
        LD      BC,(Lh1Tson)                ; son[j] = son[i]
        LD      HL,(Lh1Rj)
        LD      DE,SonBase
        CALL    Lh1PutWord
        LD      HL,(Lh1Rj)                  ; j++
        INC     HL
        LD      (Lh1Rj),HL
.p1n:
        LD      HL,(Lh1Ri)
        INC     HL
        LD      (Lh1Ri),HL
        JR      .p1
.p1d:
        ; фаза 2: построить внутренние узлы
        LD      HL,0
        LD      (Lh1Ri),HL
        LD      HL,LH1_NCHAR
        LD      (Lh1Rj),HL
.p2:
        LD      HL,(Lh1Rj)
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JP      NC,.p2d
        LD      HL,(Lh1Ri)                  ; f = freq[i] + freq[i+1]
        LD      DE,FreqBase
        CALL    Lh1GetWord
        PUSH    HL
        LD      HL,(Lh1Ri)
        INC     HL
        LD      DE,FreqBase
        CALL    Lh1GetWord
        POP     DE
        ADD     HL,DE
        LD      (Lh1Rf),HL
        LD      B,H                         ; freq[j] = f
        LD      C,L
        LD      HL,(Lh1Rj)
        LD      DE,FreqBase
        CALL    Lh1PutWord
        LD      HL,(Lh1Rj)                  ; k = j-1; while f < freq[k]: k--
        DEC     HL
        LD      (Lh1Rk),HL
.fk:
        LD      HL,(Lh1Rk)
        LD      DE,FreqBase
        CALL    Lh1GetWord
        LD      DE,(Lh1Rf)
        EX      DE,HL                       ; HL=f, DE=freq[k]
        OR      A
        SBC     HL,DE
        JR      NC,.fkd                     ; f >= freq[k] -> стоп
        LD      HL,(Lh1Rk)
        DEC     HL
        LD      (Lh1Rk),HL
        JR      .fk
.fkd:
        LD      HL,(Lh1Rk)                  ; k++
        INC     HL
        LD      (Lh1Rk),HL
        ; сдвиг freq[k..j-1] -> freq[k+1..j] (count = j-k слов, LDDR)
        LD      HL,(Lh1Rj)
        LD      DE,(Lh1Rk)
        OR      A
        SBC     HL,DE
        LD      (Lh1Rcnt),HL                ; count = j-k
        LD      A,H
        OR      L
        JR      Z,.fshift_f_done
        LD      HL,(Lh1Rj)                  ; src = старший байт freq[j-1]
        DEC     HL
        ADD     HL,HL
        LD      DE,FreqBase
        ADD     HL,DE
        INC     HL                          ; LDDR копирует сверху вниз
        LD      (Lh1Rsrc),HL
        LD      HL,(Lh1Rj)                  ; dst = старший байт freq[j]
        ADD     HL,HL
        LD      DE,FreqBase
        ADD     HL,DE
        INC     HL
        EX      DE,HL                       ; DE = dst
        LD      HL,(Lh1Rsrc)
        LD      BC,(Lh1Rcnt)
        SLA     C                           ; *2 байт
        RL      B
        LDDR
.fshift_f_done:
        LD      BC,(Lh1Rf)                  ; freq[k] = f
        LD      HL,(Lh1Rk)
        LD      DE,FreqBase
        CALL    Lh1PutWord
        LD      HL,(Lh1Rcnt)                ; сдвиг son аналогично
        LD      A,H
        OR      L
        JR      Z,.fshift_s_done
        LD      HL,(Lh1Rj)                  ; src = старший байт son[j-1]
        DEC     HL
        ADD     HL,HL
        LD      DE,SonBase
        ADD     HL,DE
        INC     HL
        LD      (Lh1Rsrc),HL
        LD      HL,(Lh1Rj)                  ; dst = старший байт son[j]
        ADD     HL,HL
        LD      DE,SonBase
        ADD     HL,DE
        INC     HL
        EX      DE,HL
        LD      HL,(Lh1Rsrc)
        LD      BC,(Lh1Rcnt)
        SLA     C
        RL      B
        LDDR
.fshift_s_done:
        LD      BC,(Lh1Ri)                  ; son[k] = i
        LD      HL,(Lh1Rk)
        LD      DE,SonBase
        CALL    Lh1PutWord
        LD      HL,(Lh1Ri)                  ; i += 2
        INC     HL
        INC     HL
        LD      (Lh1Ri),HL
        LD      HL,(Lh1Rj)                  ; j++
        INC     HL
        LD      (Lh1Rj),HL
        JP      .p2
.p2d:
        ; фаза 3: восстановить prnt
        LD      HL,0
        LD      (Lh1Ri),HL
.p3:
        LD      HL,(Lh1Ri)
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JR      NC,.p3d
        LD      HL,(Lh1Ri)                  ; k = son[i]
        LD      DE,SonBase
        CALL    Lh1GetWord
        LD      (Lh1Rk),HL
        LD      DE,LH1_T
        OR      A
        SBC     HL,DE
        JR      NC,.p3big                   ; k >= T
        LD      BC,(Lh1Ri)                  ; prnt[k] = i ; prnt[k+1] = i
        LD      HL,(Lh1Rk)
        LD      DE,PrntBase
        CALL    Lh1PutWord
        LD      BC,(Lh1Ri)
        LD      HL,(Lh1Rk)
        INC     HL
        LD      DE,PrntBase
        CALL    Lh1PutWord
        JR      .p3n
.p3big:
        LD      BC,(Lh1Ri)                  ; prnt[k] = i
        LD      HL,(Lh1Rk)
        LD      DE,PrntBase
        CALL    Lh1PutWord
.p3n:
        LD      HL,(Lh1Ri)
        INC     HL
        LD      (Lh1Ri),HL
        JR      .p3
.p3d:
        RET

; ====================================================================
; SRAM-копии битридера для lh1 (этап 5O-2 р2): чтобы DecodeChar/DecodePosition
; не платили DRAM-выборку кода на каждый бит. Состояние (BitBuf/InCur/
; InBitsLeft/InPos/InCnt) и InBuf — общие в WIN1, доступны при CASH_ON.
; Дозагрузка входа -> DRAM RefillInBuf (трамплин, ре-вход в кэш перед RET).
; Тела идентичны GetBits/FillBuf/InByte из lh5.asm (взаимные вызовы — на SRAM).
; ====================================================================
CacheGetBits:
        LD      A,B
        OR      A
        JR      NZ,.nz
        LD      HL,0
        RET
.nz:
        LD      HL,(BitBuf)
        LD      DE,0
        LD      A,B
.ex:
        ADD     HL,HL
        RL      E
        RL      D
        DEC     A
        JR      NZ,.ex
        PUSH    DE
        CALL    CacheFillBuf
        POP     HL
        RET

CacheFillBuf:
        LD      A,B
        OR      A
        RET     Z
        LD      HL,(BitBuf)
        LD      A,(InCur)
        LD      D,A
        LD      A,(InBitsLeft)
        LD      E,A
.loop:
        LD      A,E
        OR      A
        JR      NZ,.have
        PUSH    HL
        PUSH    DE
        PUSH    BC
        CALL    CacheInByte
        POP     BC
        POP     DE
        POP     HL
        LD      D,A
        LD      E,8
.have:
        LD      A,E
        CP      B
        JR      NC,.kn
        LD      C,A
        JR      .dok
.kn:
        LD      C,B
.dok:
        LD      A,C
.sh:
        SLA     D
        ADC     HL,HL
        DEC     A
        JR      NZ,.sh
        LD      A,E
        SUB     C
        LD      E,A
        LD      A,B
        SUB     C
        LD      B,A
        JR      NZ,.loop
        LD      (BitBuf),HL
        LD      A,D
        LD      (InCur),A
        LD      A,E
        LD      (InBitsLeft),A
        RET

CacheInByte:
        LD      HL,(InPos)
        LD      DE,(InCnt)
        OR      A
        SBC     HL,DE
        JR      C,.get
        CALL    RefillInBuf                 ; DRAM-трамплин (ре-вход в кэш перед RET)
        JR      C,.zero
.get:
        LD      HL,(InPos)
        LD      DE,InBufBase
        ADD     HL,DE
        LD      A,(HL)
        LD      HL,(InPos)
        INC     HL
        LD      (InPos),HL
        RET
.zero:
        XOR     A
        RET

; Вывод байта (SRAM, этап 5O): окно + выходной буфер (с flush), Remaining--.
; Байт держим в C (без PUSH/POP AF). text_buf[r] пишем по адресу r напрямую
; (TextBufBase=#0000 -> ADD не нужен). Flush сбрасывает Lh1OutPos уже при CASH_ON
; (после возврата из DRAM Lh1Flush). Remaining — в DRAM. Портит AF,C,DE,HL.
        ASSERT  TextBufBase == 0            ; для прямой записи text_buf[r]
Lh1PutByte:
        LD      C,A                         ; байт
        LD      HL,(Lh1R)                   ; text_buf[r] = byte (адрес = r)
        LD      (HL),C
        INC     HL                          ; r = (r+1) & (N-1)
        LD      A,H
        AND     #0F
        LD      H,A
        LD      (Lh1R),HL
        LD      HL,(Lh1OutPos)              ; out_buf[outpos] = byte
        LD      DE,Lh1OutBuf
        ADD     HL,DE
        LD      (HL),C
        LD      HL,(Lh1OutPos)
        INC     HL
        LD      (Lh1OutPos),HL
        LD      A,H
        CP      high(Lh1OutBufLen)          ; буфер полон (4096) ?
        JR      NZ,.nf
        CALL    Lh1Flush                    ; DRAM (трамплин), возврат при CASH_ON
        LD      HL,0
        LD      (Lh1OutPos),HL              ; CASH_ON -> запись SRAM-переменной OK
.nf:
        LD      HL,Remaining                ; Remaining-- (32-бит, DRAM)
        LD      A,(HL)
        SUB     1
        LD      (HL),A
        INC     HL
        LD      A,(HL)
        SBC     A,0
        LD      (HL),A
        INC     HL
        LD      A,(HL)
        SBC     A,0
        LD      (HL),A
        INC     HL
        LD      A,(HL)
        SBC     A,0
        LD      (HL),A
        RET

; RemainingZero (SRAM-копия): Z=1 если Remaining(DRAM)==0.
CacheRemainingZero:
        LD      A,(Remaining)
        LD      HL,Remaining+1
        OR      (HL)
        INC     HL
        OR      (HL)
        INC     HL
        OR      (HL)
        RET

; Основной цикл декода -lh1- (SRAM, этап 5O р2). Вызывается из DecodeLh1 после
; Enter (CASH_ON держится); возврат, когда Remaining==0. Поцикловая работа и
; копирование совпадений идут из SRAM. text_buf[matchI] читается по адресу=index
; (TextBufBase=#0000), без перезагрузки Lh1MatchI (адрес уже = индекс).
CacheLh1Loop:
.loop:
        CALL    CacheRemainingZero
        RET     Z
        CALL    DecodeChar                  ; HL = c
        LD      A,H
        OR      A
        JR      NZ,.match                   ; c >= 256
        LD      A,L
        CALL    Lh1PutByte
        JR      .loop
.match:
        LD      DE,255-LH1_THRESH           ; len = c - 255 + THRESHOLD = c-253
        OR      A
        SBC     HL,DE
        LD      (Lh1Len),HL
        CALL    DecodePosition              ; HL = pos
        EX      DE,HL                       ; DE = pos
        LD      HL,(Lh1R)                   ; i = (r - pos - 1) & (N-1)
        OR      A
        SBC     HL,DE
        DEC     HL
        LD      A,H
        AND     #0F
        LD      H,A
        LD      (Lh1MatchI),HL
        LD      BC,(Lh1Len)
.copy:
        LD      A,B
        OR      C
        JR      Z,.loop
        PUSH    BC
        LD      HL,(Lh1MatchI)              ; b = text_buf[matchI] (адрес = index)
        LD      A,(HL)
        LD      E,A
        INC     HL                          ; matchI = (matchI+1) & (N-1)
        LD      A,H
        AND     #0F
        LD      H,A
        LD      (Lh1MatchI),HL
        LD      A,E
        CALL    Lh1PutByte
        POP     BC
        DEC     BC
        CALL    CacheRemainingZero
        RET     Z
        JR      .copy

Lh1CacheRuntimeEnd:
        ASSERT  Lh1GetWord == SramLh1Code
        ENT
Lh1CacheStoredEnd:

; ====================================================================
; Статические таблицы позиций (в WIN1, читаются ядром по абсолютным адресам).
; ====================================================================
        INCLUDE "dtables.inc"

; Переменные -lh1- теперь в SRAM WIN0 (см. блок Lh1Vars в начале файла, этап 5O-3).

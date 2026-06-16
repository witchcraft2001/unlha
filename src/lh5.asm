; ====================================================================
;   Декодер -lh5- (LHA AR002): LZSS + статический Хаффман (3 таблицы).
;   Порт проверенного Python-эталона. Этап 3: реализация в DRAM
;   (страницы WIN2/WIN3 под кольцевое окно и таблицы). SRAM — этап 5.
; ====================================================================
; INCLUDE-ится в unlha.asm; использует ArcHandle, OutHandle, NextRecord,
; HdrBuf, Remaining, Crc16, Crc16Update, VerifyCrc, SetExitCode, MapPages.

; --- Константы формата ---
LH5_NC          EQU 510             ; число литер/длин символов (256+256-3+1)
LH5_CBIT        EQU 9
LH5_NP          EQU 14              ; число позиц. кодов (DICBIT+1)
LH5_PBIT        EQU 4
LH5_NT          EQU 19              ; число кодов таблицы длин
LH5_TBIT        EQU 5
LH5_THRESHOLD   EQU 3
LH5_DICSIZ      EQU 8192
LH5_DICMASK     EQU 8191
InBufLen        EQU 1024

; --- Раскладка в выделенных страницах (WIN2 #8000, WIN3 #C000) ---
RingBufBase     EQU #8000           ; кольцевое окно/выход (8192)
CTableBase      EQU #A000           ; 4096 слов (2^12)
CLeftBase       EQU #C000           ; узлы дерева C
CRightBase      EQU #C800
PtTableBase     EQU #D000           ; 256 слов (2^8)
PtLeftBase      EQU #D200
PtRightBase     EQU #D280
CLenBase        EQU #D300           ; длины кодов C (байты, NC)
PtLenBase       EQU #D500           ; длины кодов PT (байты)
; Буфер чтения сжатого потока (InBufBase) — в WIN1 (см. переменные ниже),
; т.к. Dss.Read может перенастраивать окна WIN2/WIN3.

; ====================================================================
; Вход: распаковать текущую -lh5- запись. Файл стоит на начале данных,
; выходной файл создан (OutHandle). orig в HdrBuf+#0B.
; ====================================================================
DecodeLh5:
        CALL    GetFilePos                  ; HL:IX = data_start
        LD      (DataStart),IX
        LD      (DataStart+2),HL
        CALL    CalcCompRemaining           ; CompRemaining = NextRecord - DataStart
        CALL    InitBitReader
        LD      HL,(HdrBuf+#0B)             ; Remaining = orig
        LD      (Remaining),HL
        LD      HL,(HdrBuf+#0D)
        LD      (Remaining+2),HL
        LD      HL,0
        LD      (Crc16),HL
        LD      (RingPos),HL
        LD      (BlockSize),HL
        CALL    Lh5DecodeLoop
        CALL    FlushRing                   ; дослать остаток окна + CRC
        RET

GetFilePos:                                 ; -> HL:IX = текущая позиция
        LD      HL,0
        LD      IX,0
        LD      BC,#0115                    ; Move_FP FromCurrent 0
        LD      A,(ArcHandle)
        RST     Dss.Rst
        RET

CalcCompRemaining:                          ; CompRemaining = NextRecord - DataStart
        LD      HL,(NextRecord)
        LD      DE,(DataStart)
        OR      A
        SBC     HL,DE
        LD      (CompRemaining),HL
        LD      HL,(NextRecord+2)
        LD      DE,(DataStart+2)
        SBC     HL,DE
        LD      (CompRemaining+2),HL
        RET

; ====================================================================
; Главный цикл декодирования.
; ====================================================================
Lh5DecodeLoop:
.loop:
        CALL    RemainingZero
        RET     Z
        CALL    DecodeC                     ; HL = символ
        LD      A,H
        OR      A
        JR      NZ,.match                   ; >=256 -> совпадение
        LD      A,L                         ; литерал
        CALL    OutByteCount
        JR      .loop
.match:
        LD      DE,256-LH5_THRESHOLD         ; len = c - 256 + THRESHOLD = c - 253
        OR      A
        SBC     HL,DE
        PUSH    HL                          ; сохранить len через DecodeP (в стеке)
        CALL    DecodeP                     ; HL = p (дистанция-1)
        EX      DE,HL                       ; DE = p (без MatchDist в памяти)
        LD      HL,(RingPos)                ; src = (r - p - 1) & DICMASK
        OR      A
        SBC     HL,DE
        DEC     HL
        LD      A,H
        AND     high(LH5_DICMASK)
        LD      H,A
        LD      (MatchSrc),HL
        POP     BC                          ; BC = len
.copy:
        LD      A,B
        OR      C
        JR      Z,.loop
        PUSH    BC
        LD      HL,(MatchSrc)               ; b = ring[src]
        LD      DE,RingBufBase
        ADD     HL,DE
        LD      A,(HL)
        LD      E,A                         ; сохранить байт
        LD      HL,(MatchSrc)               ; src = (src+1) & DICMASK
        INC     HL
        LD      A,H
        AND     high(LH5_DICMASK)
        LD      H,A
        LD      (MatchSrc),HL
        LD      A,E
        CALL    OutByteCount
        POP     BC
        DEC     BC
        CALL    RemainingZero
        RET     Z
        JR      .copy

RemainingZero:                              ; Z=1, если Remaining==0
        LD      A,(Remaining)
        LD      HL,Remaining+1
        OR      (HL)
        INC     HL
        OR      (HL)
        INC     HL
        OR      (HL)
        RET

; Вывести байт A в окно/выход; flush при заполнении; Remaining--.
; Портит AF,C,DE,HL (BC тоже). Вызывающие не полагаются на сохранность регистров:
; литерал перезагружает всё, match-copy сам сохраняет счётчик (PUSH/POP BC). Байт
; держим в C — прежние PUSH/POP HL/DE/BC/AF (4 пары на байт) были избыточны.
OutByteCount:
        LD      C,A                         ; байт
        LD      HL,(RingPos)                ; ring[r] = byte
        LD      DE,RingBufBase
        ADD     HL,DE
        LD      (HL),C
        LD      HL,(RingPos)
        INC     HL
        LD      (RingPos),HL
        LD      A,H
        CP      high(LH5_DICSIZ)            ; 8192 -> перенос окна
        JR      NZ,.noflush
        CALL    FlushRing
        LD      HL,0
        LD      (RingPos),HL
.noflush:
        ; Remaining--
        LD      HL,Remaining
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

; Сбросить RingPos байт из RingBufBase: CRC + запись в файл.
FlushRing:
        LD      HL,(RingPos)
        LD      A,H
        OR      L
        RET     Z
        LD      BC,(RingPos)
        LD      HL,RingBufBase
        CALL    Crc16Update
        LD      DE,(RingPos)
        LD      HL,RingBufBase
        LD      A,(OutHandle)
        LD      C,Dss.Write
        RST     Dss.Rst
        CALL    MapDataPages
        RET

; ====================================================================
; Битовый поток (MSB-first, модель LHA: BitBuf = следующие 16 бит).
; Этап 3 — побитовое заполнение (корректность); ускорение — этап 5.
; ====================================================================
InitBitReader:
        LD      HL,0
        LD      (InPos),HL
        LD      (InCnt),HL
        LD      (BitBuf),HL
        XOR     A
        LD      (InBitsLeft),A
        LD      B,16
        CALL    FillBuf
        RET

; PeekBits недоступен отдельно; GetBits(B=n) -> HL, и потребляет n бит.
GetBits:
        LD      A,B
        OR      A
        JR      NZ,.nz
        LD      HL,0
        RET
.nz:
        ; result = верхние B бит BitBuf. Извлекаем сдвигом ВЛЕВО за B итераций
        ; (вместо 16-B вправо) — выгодно для частого B=1 (обход дерева: 1 vs 15).
        LD      HL,(BitBuf)
        LD      DE,0
        LD      A,B
.ex:
        ADD     HL,HL                       ; bit15 -> CF
        RL      E
        RL      D
        DEC     A
        JR      NZ,.ex
        PUSH    DE                          ; результат (B сохранён для FillBuf)
        CALL    FillBuf                     ; продвинуть поток на B бит
        POP     HL                          ; -> HL
        RET

; FillBuf(B=n): сдвинуть BitBuf влево на n, втянув n новых бит.
; FillBuf(B=n): втянуть n бит в BitBuf (побайтовая модель LHA).
; Состояние в регистрах: HL=BitBuf, D=InCur (валидные биты сверху), E=InBitsLeft.
; Биты k-чанка вносятся плотным циклом SLA D / ADC HL,HL (без вызовов на бит).
FillBuf:
        LD      A,B
        OR      A
        RET     Z
        LD      HL,(BitBuf)
        LD      A,(InCur)
        LD      D,A
        LD      A,(InBitsLeft)
        LD      E,A
.loop:
        LD      A,E                         ; нужен новый байт?
        OR      A
        JR      NZ,.have
        PUSH    HL                          ; refill (редко) — InByte портит регистры
        PUSH    DE
        PUSH    BC
        CALL    InByte
        POP     BC
        POP     DE
        POP     HL
        LD      D,A
        LD      E,8
.have:
        LD      A,E                         ; k = min(n, InBitsLeft) -> C
        CP      B
        JR      NC,.kn
        LD      C,A
        JR      .dok
.kn:
        LD      C,B
.dok:
        LD      A,C                         ; внести k бит: верхний бит InCur -> младший BitBuf
.sh:
        SLA     D
        ADC     HL,HL
        DEC     A
        JR      NZ,.sh
        LD      A,E                         ; InBitsLeft -= k
        SUB     C
        LD      E,A
        LD      A,B                         ; n -= k
        SUB     C
        LD      B,A
        JR      NZ,.loop
        LD      (BitBuf),HL                 ; сохранить состояние
        LD      A,D
        LD      (InCur),A
        LD      A,E
        LD      (InBitsLeft),A
        RET

InByte:                                     ; -> A = очередной сжатый байт (0 если конец)
        LD      HL,(InPos)
        LD      DE,(InCnt)
        OR      A
        SBC     HL,DE
        JR      C,.get
        CALL    RefillInBuf
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

RefillInBuf:                                ; CF=1 если данных больше нет
        LD      HL,(CompRemaining)
        LD      DE,(CompRemaining+2)
        LD      A,H
        OR      L
        OR      D
        OR      E
        JR      Z,.none
        CALL    CompInChunk                 ; BC = min(CompRemaining, InBufLen)
        PUSH    BC
        ; --- DSS-чтение на границе: Restore->DSS->Enter, БЕЗ EI (DI весь декод) ---
        LD      A,(CacheHeld)
        OR      A
        CALL    NZ,RestoreSystemWindow
        LD      HL,InBufBase
        LD      D,B
        LD      E,C
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        CALL    MapDataPages
        LD      A,(CacheHeld)
        OR      A
        CALL    NZ,EnterCacheWindow
        POP     BC
        LD      (InCnt),BC
        LD      HL,0
        LD      (InPos),HL
        LD      HL,(CompRemaining)          ; CompRemaining -= BC
        OR      A
        SBC     HL,BC
        LD      (CompRemaining),HL
        LD      HL,(CompRemaining+2)
        LD      BC,0
        SBC     HL,BC
        LD      (CompRemaining+2),HL
        OR      A
        RET
.none:
        SCF
        RET

CompInChunk:                                ; BC = min(CompRemaining, InBufLen)
        LD      A,(CompRemaining+2)
        LD      B,A
        LD      A,(CompRemaining+3)
        OR      B
        JR      NZ,.full
        LD      A,(CompRemaining+1)
        CP      high(InBufLen)
        JR      NC,.full
        LD      BC,(CompRemaining)
        RET
.full:
        LD      BC,InBufLen
        RET

; ====================================================================
; Страницы памяти (WIN2/WIN3) под окно и таблицы.
; ====================================================================
EnsurePages:
        LD      A,(PagesReady)
        OR      A
        JR      NZ,.ok
        ; Выделить блок 2 страницы (DSS GetMem) -> A = id блока.
        LD      B,2
        LD      C,Dss.GetMem
        RST     Dss.Rst
        JR      C,.fail
        LD      (MemBlock),A
        ; Разрезолвить id блока в номера физ. страниц (BIOS EMM_FN5
        ; выгружает список страниц блока в буфер HL) — как в gifview.
        LD      HL,PageTable
        LD      C,Bios.Emm_Fn5
        RST     Bios.Rst
        JR      C,.fail
        LD      A,(PageTable)
        LD      (PhysPage2),A
        LD      A,(PageTable+1)
        LD      (PhysPage3),A
        CALL    MapDataPages
        LD      A,1
        LD      (PagesReady),A
.ok:
        OR      A
        RET
.fail:
        SCF
        RET

MapDataPages:
        LD      A,(PhysPage2)
        OUT     (PAGE2),A
        LD      A,(PhysPage3)
        OUT     (PAGE3),A
        RET

FreePages:
        LD      A,(PagesReady)
        OR      A
        RET     Z
        LD      A,(MemBlock)
        LD      C,Dss.FreeMem              ; освободить блок по id в A
        RST     Dss.Rst
        XOR     A
        LD      (PagesReady),A
        RET

; ====================================================================
; Декодирование символов.
; ====================================================================
DecodeC:                                    ; -> HL = символ (0..NC-1)
        LD      HL,(BlockSize)
        LD      A,H
        OR      L
        JR      NZ,.have
        CALL    ReadBlockHeader
.have:
        LD      HL,(BlockSize)
        DEC     HL
        LD      (BlockSize),HL
        LD      HL,(BitBuf)                 ; j = c_table[bitbuf>>4]
        SRL     H
        RR      L
        SRL     H
        RR      L
        SRL     H
        RR      L
        SRL     H
        RR      L
        ADD     HL,HL
        LD      DE,CTableBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL                       ; HL = j
        ; j < NC (510 = #01FE)? побайтово, без порчи HL (на каждый символ)
        LD      A,H
        OR      A
        JR      Z,.leaf                     ; H==0 -> j<256 -> leaf
        DEC     A
        JR      NZ,.bigj                    ; H>=2 -> j>=512 -> обход дерева
        LD      A,L                         ; H==1
        CP      #FE
        JR      C,.leaf                     ; L<#FE -> j<510 -> leaf
.bigj:
        LD      C,#08                       ; mask = 1<<(15-12)
.walk:
        LD      A,(BitBuf)
        AND     C
        JR      Z,.left
        ADD     HL,HL
        LD      DE,CRightBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        JR      .next
.left:
        ADD     HL,HL
        LD      DE,CLeftBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
.next:
        SRL     C
        JR      Z,.leaf                     ; предохранитель от зацикливания
        LD      DE,LH5_NC
        PUSH    HL
        OR      A
        SBC     HL,DE
        POP     HL
        JR      NC,.walk                    ; j >= NC
.leaf:
        PUSH    HL                          ; fillbuf(c_len[j])
        LD      DE,CLenBase
        ADD     HL,DE
        LD      A,(HL)
        LD      B,A
        CALL    FillBuf
        POP     HL
        RET

DecodeP:                                    ; -> HL = p (дистанция-1)
        LD      A,(BitBuf+1)                ; j = pt_table[bitbuf>>8]
        LD      L,A
        LD      H,0
        ADD     HL,HL
        LD      DE,PtTableBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL                       ; HL = j
        LD      DE,(PtThresh)
        LD      A,L                         ; j < PtThresh ? (через A, без порчи HL)
        SUB     E
        LD      A,H
        SBC     A,D
        JR      C,.leaf                     ; j < thresh -> leaf
        LD      C,#80                       ; mask = 1<<(15-8)
.walk:
        LD      A,(BitBuf)
        AND     C
        JR      Z,.left
        ADD     HL,HL
        LD      DE,PtRightBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        JR      .next
.left:
        ADD     HL,HL
        LD      DE,PtLeftBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
.next:
        SRL     C
        JR      Z,.leaf                     ; предохранитель от зацикливания
        LD      DE,(PtThresh)
        LD      A,L                         ; j >= PtThresh ? (через A, без порчи HL)
        SUB     E
        LD      A,H
        SBC     A,D
        JR      NC,.walk                    ; j >= thresh -> продолжить обход
.leaf:
        PUSH    HL                          ; fillbuf(pt_len[j])
        LD      DE,PtLenBase
        ADD     HL,DE
        LD      A,(HL)
        LD      B,A
        CALL    FillBuf
        POP     HL
        ; if j!=0: j = (1<<(j-1)) + getbits(j-1)
        LD      A,H
        OR      L
        RET     Z
        PUSH    HL                          ; сохранить j
        DEC     L                           ; j-1 (j<=13, H=0)
        LD      B,L
        CALL    GetBits                     ; HL = getbits(j-1)
        POP     DE                          ; DE = j
        DEC     E                           ; j-1
        LD      BC,1                        ; BC = 1<<(j-1)
        LD      A,E
        OR      A
        JR      Z,.add
.sh:
        SLA     C
        RL      B
        DEC     A
        JR      NZ,.sh
.add:
        ADD     HL,BC
        RET

; Декод одного кода PT-таблицы (порог в PtThresh). -> HL = код.
DecodePtCode:
        LD      A,(BitBuf+1)
        LD      L,A
        LD      H,0
        ADD     HL,HL
        LD      DE,PtTableBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        LD      DE,(PtThresh)
        PUSH    HL
        OR      A
        SBC     HL,DE
        POP     HL
        JR      C,.leaf
        LD      C,#80
.walk:
        LD      A,(BitBuf)
        AND     C
        JR      Z,.left
        ADD     HL,HL
        LD      DE,PtRightBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        JR      .next
.left:
        ADD     HL,HL
        LD      DE,PtLeftBase
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
.next:
        SRL     C
        JR      Z,.leaf                     ; предохранитель от зацикливания
        LD      DE,(PtThresh)
        PUSH    HL
        OR      A
        SBC     HL,DE
        POP     HL
        JR      NC,.walk
.leaf:
        PUSH    HL
        LD      DE,PtLenBase
        ADD     HL,DE
        LD      A,(HL)
        LD      B,A
        CALL    FillBuf
        POP     HL
        RET

; ====================================================================
; Чтение заголовка блока: blocksize + 3 таблицы Хаффмана.
; ====================================================================
ReadBlockHeader:
        LD      B,16
        CALL    GetBits
        LD      (BlockSize),HL
        CALL    ReadPtLenNT                 ; временная таблица (для длин C)
        CALL    ReadCLen                    ; таблица литер/длин
        CALL    ReadPtLenNP                 ; таблица позиций
        RET

ReadPtLenNT:
        LD      HL,LH5_NT
        LD      (PtThresh),HL
        LD      A,LH5_TBIT
        LD      (PtNbit),A
        LD      A,3
        LD      (PtISpec),A
        JP      ReadPtLen

ReadPtLenNP:
        LD      HL,LH5_NP
        LD      (PtThresh),HL
        LD      A,LH5_PBIT
        LD      (PtNbit),A
        LD      A,255                       ; -1 (никогда не совпадёт)
        LD      (PtISpec),A
        JP      ReadPtLen

; read_pt_len(nn=PtThresh, nbit=PtNbit, ispec=PtISpec)
ReadPtLen:
        LD      A,(PtNbit)
        LD      B,A
        CALL    GetBits                     ; n
        LD      A,H
        OR      L
        JR      NZ,.nonzero
        CALL    ZeroPtLen                   ; обнулить pt_len ДО чтения c
        LD      A,(PtNbit)                  ; (ZeroPtLen портит HL, биты не трогает)
        LD      B,A
        CALL    GetBits                     ; n==0: c=getbits(nbit) -> HL
        CALL    FillPtTableConst            ; pt_table = c (HL не испорчен)
        RET
.nonzero:
        LD      (PtCount),HL
        LD      HL,0
        LD      (PtI),HL
.loop:
        LD      HL,(PtI)
        LD      DE,(PtCount)
        OR      A
        SBC     HL,DE
        JR      NC,.fillrest                ; i >= n
        LD      B,3
        CALL    GetBits                     ; c
        LD      A,L
        CP      7
        JR      C,.store                    ; c<7
        LD      A,7
.cnt:
        PUSH    AF
        LD      B,1
        CALL    GetBits
        POP     AF
        BIT     0,L
        JR      Z,.store                    ; 0 -> стоп (терм. ноль потреблён)
        INC     A
        JR      .cnt
.store:
        LD      HL,(PtI)                    ; pt_len[i] = A
        LD      DE,PtLenBase
        ADD     HL,DE
        LD      (HL),A
        LD      HL,(PtI)
        INC     HL
        LD      (PtI),HL
        LD      A,(PtI)                     ; if i==ispec: пропуск нулей
        LD      HL,PtISpec
        CP      (HL)
        JR      NZ,.loop
        LD      B,2
        CALL    GetBits
        LD      A,L
        LD      (PtZ),A
.zl:
        LD      A,(PtZ)
        OR      A
        JR      Z,.loop
        LD      HL,(PtI)
        LD      DE,PtLenBase
        ADD     HL,DE
        LD      (HL),0
        LD      HL,(PtI)
        INC     HL
        LD      (PtI),HL
        LD      A,(PtZ)
        DEC     A
        LD      (PtZ),A
        JR      .zl
.fillrest:
        LD      HL,(PtI)                    ; while i<nn: pt_len[i++]=0
        LD      DE,(PtThresh)
.fr:
        LD      A,L
        SUB     E
        LD      A,H
        SBC     A,D
        JR      NC,.frdone                  ; i>=nn
        PUSH    DE                          ; сохранить предел nn
        PUSH    HL
        LD      DE,PtLenBase
        ADD     HL,DE
        LD      (HL),0
        POP     HL
        POP     DE
        INC     HL
        JR      .fr
.frdone:
        CALL    SetupMakeTablePt
        CALL    MakeTable
        RET

; read_c_len()
ReadCLen:
        LD      B,LH5_CBIT
        CALL    GetBits                     ; n
        LD      A,H
        OR      L
        JR      NZ,.nonzero
        CALL    ZeroCLen                    ; обнулить c_len ДО чтения c (портит HL)
        LD      B,LH5_CBIT                  ; n==0: c=getbits(CBIT) -> HL
        CALL    GetBits
        CALL    FillCTableConst             ; c_table = c (HL не испорчен)
        RET
.nonzero:
        LD      (CCount),HL
        LD      HL,0
        LD      (CI),HL
.loop:
        LD      HL,(CI)
        LD      DE,(CCount)
        OR      A
        SBC     HL,DE
        JR      NC,.fillrest                ; i>=n
        CALL    DecodePtCode                ; c (порог PtThresh=NT)
        LD      A,L
        CP      3
        JR      NC,.normal                  ; c>=3
        OR      A
        JR      NZ,.c1
        LD      HL,1                        ; c==0 -> run=1
        JR      .runzeros
.c1:
        CP      1
        JR      NZ,.c2
        LD      B,4                         ; c==1 -> run=getbits(4)+3
        CALL    GetBits
        LD      DE,3
        ADD     HL,DE
        JR      .runzeros
.c2:
        LD      B,9                         ; c==2 -> run=getbits(9)+20
        CALL    GetBits
        LD      DE,20
        ADD     HL,DE
.runzeros:
        LD      (CRun),HL
.rz:
        LD      HL,(CRun)
        LD      A,H
        OR      L
        JR      Z,.loop
        LD      HL,(CI)
        LD      DE,CLenBase
        ADD     HL,DE
        LD      (HL),0
        LD      HL,(CI)
        INC     HL
        LD      (CI),HL
        LD      HL,(CRun)
        DEC     HL
        LD      (CRun),HL
        JR      .rz
.normal:
        LD      A,L                         ; c_len[i] = c-2
        SUB     2
        LD      HL,(CI)
        LD      DE,CLenBase
        ADD     HL,DE
        LD      (HL),A
        LD      HL,(CI)
        INC     HL
        LD      (CI),HL
        JR      .loop
.fillrest:
        LD      HL,(CI)                     ; while i<NC: c_len[i++]=0
        LD      DE,LH5_NC
.fr:
        LD      A,L
        SUB     E
        LD      A,H
        SBC     A,D
        JR      NC,.frdone
        PUSH    DE                          ; сохранить предел NC
        PUSH    HL
        LD      DE,CLenBase
        ADD     HL,DE
        LD      (HL),0
        POP     HL
        POP     DE
        INC     HL
        JR      .fr
.frdone:
        CALL    SetupMakeTableC
        CALL    MakeTable
        RET

ZeroPtLen:
        LD      HL,PtLenBase
        LD      (HL),0
        LD      DE,PtLenBase+1
        LD      BC,31
        LDIR
        RET

ZeroCLen:
        LD      HL,CLenBase
        LD      (HL),0
        LD      DE,CLenBase+1
        LD      BC,LH5_NC
        LDIR
        RET

FillPtTableConst:                           ; HL = значение, 256 слов
        LD      DE,PtTableBase
        LD      B,0
.l:
        LD      A,L
        LD      (DE),A
        INC     DE
        LD      A,H
        LD      (DE),A
        INC     DE
        DJNZ    .l
        RET

FillCTableConst:                            ; HL = значение, 4096 слов
        LD      DE,CTableBase
        LD      BC,4096
.l:
        LD      A,L
        LD      (DE),A
        INC     DE
        LD      A,H
        LD      (DE),A
        INC     DE
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,.l
        RET

SetupMakeTablePt:
        LD      HL,(PtThresh)
        LD      (MtNchar),HL
        LD      A,8
        LD      (MtTBits),A
        LD      HL,PtLenBase
        LD      (MtBitlen),HL
        LD      HL,PtTableBase
        LD      (MtTable),HL
        LD      HL,PtLeftBase
        LD      (MtLeft),HL
        LD      HL,PtRightBase
        LD      (MtRight),HL
        RET

SetupMakeTableC:
        LD      HL,LH5_NC
        LD      (MtNchar),HL
        LD      A,12
        LD      (MtTBits),A
        LD      HL,CLenBase
        LD      (MtBitlen),HL
        LD      HL,CTableBase
        LD      (MtTable),HL
        LD      HL,CLeftBase
        LD      (MtLeft),HL
        LD      HL,CRightBase
        LD      (MtRight),HL
        RET

; ====================================================================
; make_table — построение таблицы декодирования из длин кодов.
; Порт maketbl.c (16-битная арифметика с переполнением).
; Параметры в MtNchar/MtTBits/MtBitlen/MtTable/MtLeft/MtRight.
; ====================================================================
MakeTable:
        LD      A,16                        ; jut = 16 - tbits
        LD      HL,MtTBits
        SUB     (HL)
        LD      (MtJut),A
        LD      HL,MtCount                  ; count[]=0 (17 слов)
        LD      (HL),0
        LD      DE,MtCount+1
        LD      BC,33
        LDIR
        LD      BC,(MtNchar)                ; count[bitlen[ch]]++
        LD      HL,(MtBitlen)
.c1:
        LD      A,B
        OR      C
        JR      Z,.c1d
        LD      A,(HL)
        INC     HL
        PUSH    HL
        PUSH    BC
        LD      HL,MtCount
        CALL    AddWordIndex
        POP     BC
        POP     HL
        DEC     BC
        JR      .c1
.c1d:
        LD      HL,0                        ; start[1]=0
        LD      (MtStart+2),HL
        LD      B,1                         ; for i=1..16
.s1:
        LD      A,B
        LD      HL,MtCount
        CALL    GetWordIndex                ; HL=count[i]
        LD      A,16
        SUB     B
        LD      E,A
        CALL    ShlHL_E                     ; count[i]<<(16-i)
        PUSH    HL
        LD      A,B
        LD      HL,MtStart
        CALL    GetWordIndex                ; HL=start[i]
        POP     DE
        ADD     HL,DE
        LD      A,B
        INC     A
        LD      DE,MtStart
        CALL    PutWordIndexHL              ; start[i+1]=...
        INC     B
        LD      A,B
        CP      17
        JR      C,.s1
        LD      B,1                         ; i=1..tbits: start>>=jut; weight=1<<(tbits-i)
.s2:
        LD      A,(MtTBits)
        CP      B
        JR      C,.s2d
        LD      A,B
        LD      HL,MtStart
        CALL    GetWordIndex
        LD      A,(MtJut)
        LD      E,A
        CALL    ShrHL_E
        LD      A,B
        LD      DE,MtStart
        CALL    PutWordIndexHL
        LD      A,(MtTBits)
        SUB     B
        LD      E,A
        LD      HL,1
        CALL    ShlHL_E
        LD      A,B
        LD      DE,MtWeight
        CALL    PutWordIndexHL
        INC     B
        JR      .s2
.s2d:
        LD      A,(MtTBits)                 ; i=tbits+1..16: weight=1<<(16-i)
        INC     A
        LD      B,A
.s3:
        LD      A,B
        CP      17
        JR      NC,.s3d
        LD      A,16
        SUB     B
        LD      E,A
        LD      HL,1
        CALL    ShlHL_E
        LD      A,B
        LD      DE,MtWeight
        CALL    PutWordIndexHL
        INC     B
        JR      .s3
.s3d:
        LD      A,(MtTBits)                 ; mid-fill нулями верх таблицы
        INC     A
        LD      HL,MtStart
        CALL    GetWordIndex
        LD      A,(MtJut)
        LD      E,A
        CALL    ShrHL_E                     ; i = start[tbits+1]>>jut
        LD      A,(MtTBits)
        LD      E,A
        PUSH    HL
        LD      HL,1
        CALL    ShlHL_E
        LD      (MtKK),HL                   ; kk = 1<<tbits
        POP     HL
.midf:
        LD      DE,(MtKK)
        PUSH    HL
        OR      A
        SBC     HL,DE
        POP     HL
        JR      NC,.midd
        PUSH    HL
        ADD     HL,HL
        LD      DE,(MtTable)
        ADD     HL,DE
        LD      (HL),0
        INC     HL
        LD      (HL),0
        POP     HL
        INC     HL
        JR      .midf
.midd:
        LD      HL,(MtNchar)                ; avail=nchar
        LD      (MtAvail),HL
        LD      A,15                        ; mask=1<<(15-tbits)
        LD      HL,MtTBits
        SUB     (HL)
        LD      E,A
        LD      HL,1
        CALL    ShlHL_E
        LD      (MtMask),HL
        LD      HL,0                        ; for ch=0..nchar-1
        LD      (MtCh),HL
.chl:
        LD      HL,(MtCh)
        LD      DE,(MtNchar)
        OR      A
        SBC     HL,DE
        JP      NC,.chd
        LD      HL,(MtBitlen)
        LD      DE,(MtCh)
        ADD     HL,DE
        LD      A,(HL)                      ; len
        OR      A
        JP      Z,.chn
        LD      (MtLen),A
        LD      HL,MtStart                  ; k=start[len]
        CALL    GetWordIndex
        LD      (MtK),HL
        LD      A,(MtLen)
        LD      HL,MtWeight                 ; nextcode=k+weight[len]
        CALL    GetWordIndex
        LD      DE,(MtK)
        ADD     HL,DE
        LD      (MtNext),HL
        LD      A,(MtLen)
        LD      HL,MtTBits
        CP      (HL)
        JR      Z,.short
        JR      C,.short
        JP      .tree
.short:
        LD      HL,(MtK)                    ; table[k..nextcode-1]=ch
.shf:
        LD      DE,(MtNext)
        PUSH    HL
        OR      A
        SBC     HL,DE
        POP     HL
        JR      NC,.shd
        PUSH    HL
        ADD     HL,HL
        LD      DE,(MtTable)
        ADD     HL,DE
        LD      DE,(MtCh)
        LD      (HL),E
        INC     HL
        LD      (HL),D
        POP     HL
        INC     HL
        JR      .shf
.shd:
        LD      A,(MtLen)                   ; start[len]=nextcode
        LD      HL,(MtNext)
        LD      DE,MtStart
        CALL    PutWordIndexHL
        JP      .chn
.tree:
        LD      HL,(MtK)                    ; p=&table[k>>jut]
        LD      A,(MtJut)
        LD      E,A
        CALL    ShrHL_E
        ADD     HL,HL
        LD      DE,(MtTable)
        ADD     HL,DE
        LD      (MtP),HL
        LD      A,(MtLen)                   ; i=len-tbits
        LD      HL,MtTBits
        SUB     (HL)
        LD      (MtTreeI),A
        LD      HL,(MtK)
        LD      (MtKW),HL
.tw:
        LD      A,(MtTreeI)
        OR      A
        JR      Z,.twd
        LD      HL,(MtP)                    ; node = *p
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        LD      A,D
        OR      E
        JR      NZ,.haveN
        LD      HL,(MtAvail)                ; создать узел
        EX      DE,HL                       ; DE = avail
        LD      HL,(MtP)
        LD      (HL),E
        INC     HL
        LD      (HL),D
        PUSH    DE
        EX      DE,HL                       ; HL=avail
        ADD     HL,HL
        LD      DE,(MtLeft)
        ADD     HL,DE
        LD      (HL),0
        INC     HL
        LD      (HL),0
        POP     DE
        PUSH    DE
        EX      DE,HL
        ADD     HL,HL
        LD      DE,(MtRight)
        ADD     HL,DE
        LD      (HL),0
        INC     HL
        LD      (HL),0
        POP     DE
        LD      HL,(MtAvail)
        INC     HL
        LD      (MtAvail),HL
.haveN:                                     ; DE = node
        LD      HL,(MtKW)                   ; if k&mask -> right else left
        LD      BC,(MtMask)
        LD      A,H
        AND     B
        LD      H,A
        LD      A,L
        AND     C
        OR      H
        JR      Z,.useL
        EX      DE,HL                       ; HL=node
        ADD     HL,HL
        LD      DE,(MtRight)
        ADD     HL,DE
        LD      (MtP),HL
        JR      .twn
.useL:
        EX      DE,HL
        ADD     HL,HL
        LD      DE,(MtLeft)
        ADD     HL,DE
        LD      (MtP),HL
.twn:
        LD      HL,(MtKW)                   ; k<<=1
        ADD     HL,HL
        LD      (MtKW),HL
        LD      A,(MtTreeI)
        DEC     A
        LD      (MtTreeI),A
        JR      .tw
.twd:
        LD      HL,(MtP)                    ; *p = ch
        LD      DE,(MtCh)
        LD      (HL),E
        INC     HL
        LD      (HL),D
        LD      A,(MtLen)                   ; start[len]=nextcode
        LD      HL,(MtNext)
        LD      DE,MtStart
        CALL    PutWordIndexHL
.chn:
        LD      HL,(MtCh)
        INC     HL
        LD      (MtCh),HL
        JP      .chl
.chd:
        RET

; --- Помощники для массивов слов и сдвигов ---
GetWordIndex:                               ; HL=base, A=index -> HL = word[index]
        ADD     A,A
        LD      E,A
        LD      D,0
        ADD     HL,DE
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        RET

PutWordIndexHL:                             ; A=index, DE=base, HL=value
        PUSH    HL
        LD      H,0
        LD      L,A
        ADD     HL,HL
        ADD     HL,DE
        EX      DE,HL
        POP     HL
        LD      A,L
        LD      (DE),A
        INC     DE
        LD      A,H
        LD      (DE),A
        RET

AddWordIndex:                               ; HL=base, A=index -> ++word[index]
        ADD     A,A
        LD      E,A
        LD      D,0
        ADD     HL,DE
        INC     (HL)
        RET     NZ
        INC     HL
        INC     (HL)
        RET

ShlHL_E:                                    ; HL <<= E
        INC     E
.l:
        DEC     E
        RET     Z
        ADD     HL,HL
        JR      .l

ShrHL_E:                                    ; HL >>= E (логический)
        INC     E
.l:
        DEC     E
        RET     Z
        SRL     H
        RR      L
        JR      .l

; ====================================================================
; Переменные декодера (WIN1).
; ====================================================================
BitBuf:         DW      0
InCur:          DB      0
InBitsLeft:     DB      0
InPos:          DW      0
InCnt:          DW      0
CompRemaining:  DS      4
RingPos:        DW      0
BlockSize:      DW      0
DataStart:      DS      4
; MatchLen/MatchDist больше не нужны: len держится в стеке через DecodeP,
; дистанция — в регистре (EX DE,HL).
MatchSrc:       DW      0
PagesReady:     DB      0
MemBlock:       DB      0
PhysPage2:      DB      0
PhysPage3:      DB      0
PageTable:      DS      8
PtThresh:       DW      0
PtNbit:         DB      0
PtISpec:        DB      0
PtCount:        DW      0
PtI:            DW      0
PtZ:            DB      0
CCount:         DW      0
CI:             DW      0
CRun:           DW      0
MtNchar:        DW      0
MtTBits:        DB      0
MtJut:          DB      0
MtBitlen:       DW      0
MtTable:        DW      0
MtLeft:         DW      0
MtRight:        DW      0
MtAvail:        DW      0
MtMask:         DW      0
MtCh:           DW      0
MtLen:          DB      0
MtK:            DW      0
MtNext:         DW      0
MtP:            DW      0
MtKW:           DW      0
MtTreeI:        DB      0
MtKK:           DW      0
MtCount:        DS      34
MtStart:        DS      36
MtWeight:       DS      34
InBufBase:      DS      InBufLen

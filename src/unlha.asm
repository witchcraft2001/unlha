; ====================================================================
;   UNLHA — распаковщик архивов LZH/LHA для Sprinter DSS
;   Z80 assembler (sjasmplus). Стиль/конвенции — см. CLAUDE.md.
; ====================================================================
;   Этап 1: CLI + разбор заголовков LZH (Level 0/1) + режим списка
;   (на экран и в текстовый файл) + фильтр-маски (* ? , / == \).
;   Распаковка появится на этапе 2.
; ====================================================================

        INCLUDE "../include/exe_header.inc"
        INCLUDE "../include/bios_equ.inc"
        INCLUDE "../include/dss_equ.inc"
        INCLUDE "../include/ports.inc"

UnlhaOrg        EQU #4200
UnlhaStack      EQU #7FFE
ExeVersion      EQU 1
ListPageLines   EQU 22                  ; строк на экран перед паузой

        ORG     UnlhaOrg - DSS_EXE_HEADER_SIZE
        DSS_EXE_HEADER ExeVersion, #0000, UnlhaOrg, UnlhaOrg, UnlhaStack

        ORG     UnlhaOrg

; ====================================================================
; Точка входа. IX -> командная строка DSS (IX+0 = длина, далее токены).
; ====================================================================
Start:
        LD      SP,UnlhaStack
        LD      (CommandLinePtr),IX
        XOR     A
        LD      (ExitCode),A

        LD      HL,MsgBanner
        CALL    PrintString

        CALL    ParseCmdLine

        LD      A,(ArchivePath)             ; задан ли архив?
        OR      A
        JP      Z,Usage

        LD      HL,ArchivePath              ; открыть архив (только чтение)
        LD      A,FileMode.Read
        LD      C,Dss.Open
        RST     Dss.Rst
        JP      C,OpenError
        LD      (ArcHandle),A

        LD      A,(ModeList)
        OR      A
        JR      NZ,DoList

        ; Режим распаковки (-lh0-/-lz4- stored, -lh5- AR002).
        CALL    ExtractArchive
        CALL    FreePages
        CALL    CloseArchive
        LD      A,(ExitCode)
        JP      ExitWithCodeA

DoList:
        ; Открыть файл листинга, если задан позиционный путь (не маска).
        LD      A,#FF
        LD      (ListFileHandle),A
        LD      A,(OutOrListPath)
        OR      A
        JR      Z,.toScreen
        LD      HL,OutOrListPath
        LD      A,FileAttrib.Arch
        LD      C,Dss.Create
        RST     Dss.Rst
        JP      C,CreateError
        LD      (ListFileHandle),A
.toScreen:
        CALL    ListArchive                 ; A = 0 норм. / 1 прерывание
        LD      (ListResult),A
        CALL    CloseListFile
        CALL    CloseArchive
        LD      A,(ListResult)
        JP      ExitWithCodeA

; ====================================================================
; Завершение в DSS. Код возврата в A.
; ====================================================================
ExitWithCodeA:
        LD      B,A
        LD      C,Dss.Exit
        RST     Dss.Rst
        ; не возвращается

Usage:
        LD      HL,MsgUsage
        CALL    PrintString
        LD      A,1
        JP      ExitWithCodeA

InvalidCmd:
        LD      HL,MsgUsage
        CALL    PrintString
        LD      A,1
        JP      ExitWithCodeA

OpenError:
        LD      HL,MsgOpenErr
        CALL    PrintString
        LD      A,3
        JP      ExitWithCodeA

CreateError:
        LD      HL,MsgCreateErr
        CALL    PrintString
        CALL    CloseArchive
        LD      A,7
        JP      ExitWithCodeA

; ====================================================================
; Разбор командной строки.
;   флаги: -l/-o/-s/-x (или /l ...), позиционные: archive, out/list, mask.
; ====================================================================
ParseCmdLine:
        LD      HL,(CommandLinePtr)
        INC     HL                          ; пропустить байт длины
        XOR     A
        LD      (ModeList),A
        LD      (OverwriteMode),A
        LD      (StripMode),A
        LD      (PosCount),A
        LD      (ArchivePath),A
        LD      (OutOrListPath),A
        LD      (MaskBuf),A
.loop:
        LD      DE,ParamBuf
        CALL    GetCmdParam
        RET     C                           ; параметров больше нет
        LD      A,(ParamBuf)
        CP      '-'
        JR      Z,.opt
        CP      '/'
        JR      Z,.opt
        CALL    HandlePositional
        JR      .loop
.opt:
        LD      A,(ParamBuf+1)
        OR      #20                         ; в нижний регистр
        CP      'l'
        JR      Z,.optL
        CP      'o'
        JR      Z,.optO
        CP      's'
        JR      Z,.optS
        CP      'x'
        JR      Z,.optX
        JP      InvalidCmd
.optL:  LD      A,1
        LD      (ModeList),A
        JR      .loop
.optO:  LD      A,1                         ; 1 = overwrite
        LD      (OverwriteMode),A
        JR      .loop
.optS:  LD      A,2                         ; 2 = skip
        LD      (OverwriteMode),A
        JR      .loop
.optX:  LD      A,1
        LD      (StripMode),A
        JR      .loop

; Классификация позиционного параметра (в ParamBuf) по PosCount.
HandlePositional:
        PUSH    HL
        LD      A,(PosCount)
        INC     A
        LD      (PosCount),A
        DEC     A                           ; A = старый счётчик (0-based)
        OR      A
        JR      Z,.arc
        CP      1
        JR      Z,.second
        JR      .asMask
.arc:
        LD      HL,ParamBuf
        LD      DE,ArchivePath
        CALL    CopyStr
        JR      .ret
.second:
        LD      HL,ParamBuf                 ; если есть wildcard — это маска
        CALL    HasWildcard
        JR      C,.asMask
        LD      HL,ParamBuf
        LD      DE,OutOrListPath
        CALL    CopyStr
        JR      .ret
.asMask:
        LD      HL,ParamBuf
        LD      DE,MaskBuf
        CALL    CopyStr
        CALL    NormalizeMask
.ret:
        POP     HL
        RET

; ====================================================================
; Чтение следующего параметра командной строки.
;   Inp: HL -> позиция в CLI, DE -> буфер назначения
;   Out: CF=1 если параметр пуст; HL продвинут
; ====================================================================
GetCmdParam:
        PUSH    DE
.first:
        LD      A,(HL)
        INC     HL
        OR      A
        JR      Z,.eol
        CP      ' '+1                       ; пробел/управляющий = разделитель
        JR      C,.first
        DEC     HL
.mov:
        LD      A,(HL)
        OR      A
        JR      Z,.eol
        CP      ' '+1
        JR      C,.eol
        LD      (DE),A
        INC     HL
        INC     DE
        JR      .mov
.eol:
        XOR     A
        LD      (DE),A
        POP     DE
        LD      A,(DE)
        OR      A
        RET     NZ
        SCF
        RET

; ====================================================================
; Список архива. Out: A = 0 (норм.) / 1 (прерывание).
; ====================================================================
ListArchive:
        XOR     A
        LD      (LineCount),A
.loop:
        LD      HL,HdrBuf                   ; читать фиксированную часть (22 байта)
        LD      DE,22
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        JR      C,.done
        LD      A,E
        CP      22
        JR      C,.done                     ; прочитано меньше — конец
        LD      A,(HdrBuf)                  ; header size == 0 -> маркер конца
        OR      A
        JR      Z,.done

        LD      A,(HdrBuf+#15)              ; длина имени
        LD      (NameLen),A
        OR      A
        JR      Z,.noName
        LD      E,A                         ; читать имя
        LD      D,0
        LD      HL,NameBuf
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        JR      C,.done
.noName:
        LD      A,(NameLen)                 ; null-терминатор имени
        LD      L,A
        LD      H,0
        LD      DE,NameBuf
        ADD     HL,DE
        LD      (HL),0

        CALL    ComputeSkip
        CALL    OutEntry
        JR      C,.abort
        CALL    SeekSkip
        JR      C,.done
        JR      .loop
.abort:
        LD      A,1
        RET
.done:
        XOR     A
        RET

; SkipWork = packed(4) + (headerSize - 20 - nameLen)
ComputeSkip:
        LD      HL,HdrBuf+7
        LD      DE,SkipWork
        LD      BC,4
        LDIR
        LD      A,(HdrBuf)
        SUB     20
        LD      B,A
        LD      A,(NameLen)
        LD      C,A
        LD      A,B
        SUB     C
        LD      C,A                         ; C = остаток заголовка (8-бит)
        LD      A,(SkipWork)
        ADD     A,C
        LD      (SkipWork),A
        LD      A,(SkipWork+1)
        ADC     A,0
        LD      (SkipWork+1),A
        LD      A,(SkipWork+2)
        ADC     A,0
        LD      (SkipWork+2),A
        LD      A,(SkipWork+3)
        ADC     A,0
        LD      (SkipWork+3),A
        RET

; Перемотать файл вперёд на SkipWork (FromCurrent). CF=1 при ошибке.
SeekSkip:
        LD      HL,(SkipWork+2)             ; старшее слово
        LD      IX,(SkipWork)               ; младшее слово
        LD      BC,#0115                    ; B=01 FromCurrent, C=15 Move_FP
        LD      A,(ArcHandle)
        RST     Dss.Rst
        RET

; ====================================================================
; Вывод строки списка по текущей записи.
;   CF=1 -> запрошено прерывание (Esc); CF=0 -> продолжать.
; ====================================================================
OutEntry:
        LD      A,(MaskBuf)                 ; фильтр по маске
        OR      A
        JR      Z,.show
        LD      HL,NameBuf
        LD      DE,MaskBuf
        CALL    MatchMask
        JR      NC,.show
        OR      A                           ; нет совпадения — пропуск (CF=0)
        RET
.show:
        CALL    CopyMethod
        LD      HL,MethodStr
        CALL    OutStr
        LD      HL,MsgGap
        CALL    OutStr
        LD      HL,HdrBuf+7                 ; упакованный размер
        CALL    OutU32
        LD      HL,MsgGap
        CALL    OutStr
        LD      HL,HdrBuf+#0B              ; исходный размер
        CALL    OutU32
        LD      HL,MsgGap
        CALL    OutStr
        LD      HL,NameBuf
        CALL    OutStr
        LD      HL,MsgCrLf
        CALL    OutStr
        CALL    PagerTick
        RET

CopyMethod:
        LD      HL,HdrBuf+2
        LD      DE,MethodStr
        LD      BC,5
        LDIR
        XOR     A
        LD      (DE),A
        RET

; Постраничная пауза (только при выводе на экран). CF=1 -> прерывание.
PagerTick:
        LD      A,(ListFileHandle)
        INC     A
        JR      Z,.screen                   ; #FF -> экран
        OR      A                           ; файл — без пейджера (CF=0)
        RET
.screen:
        LD      A,(LineCount)
        INC     A
        LD      (LineCount),A
        CP      ListPageLines
        JR      Z,.page
        OR      A
        RET
.page:
        XOR     A
        LD      (LineCount),A
        LD      HL,MsgMore
        CALL    PrintString
        LD      C,Dss.WaitKey
        RST     Dss.Rst
        LD      HL,MsgCrLf
        CALL    PrintString
        CP      27                          ; Esc -> прерывание
        JR      Z,.abort
        OR      A
        RET
.abort:
        SCF
        RET

; ====================================================================
; Вывод ASCIIZ-строки в текущий приёмник (экран или файл листинга).
;   HL -> строка.
; ====================================================================
OutStr:
        LD      A,(ListFileHandle)
        INC     A
        JR      Z,.screen                   ; #FF -> экран
        PUSH    HL                          ; файл: записать strlen байт
        CALL    StrLen                      ; DE = длина
        POP     HL
        LD      A,(ListFileHandle)
        LD      C,Dss.Write
        RST     Dss.Rst
        RET
.screen:
        LD      C,Dss.PChars
        RST     Dss.Rst
        RET

StrLen:                                     ; HL -> str ; Out: DE = длина (HL сохр.)
        PUSH    HL
        LD      DE,0
.l:
        LD      A,(HL)
        OR      A
        JR      Z,.d
        INC     HL
        INC     DE
        JR      .l
.d:
        POP     HL
        RET

; Печать 32-битного LE числа (HL -> 4 байта) в текущий приёмник.
OutU32:
        LD      DE,NumWork
        LD      BC,4
        LDIR
        CALL    FormatU32
        LD      HL,NumStr
        CALL    OutStr
        RET

; NumWork(4 LE) -> NumStr (ASCIIZ, десятичное).
FormatU32:
        LD      C,0                         ; счётчик цифр
.gen:
        CALL    Div32by10                   ; A = остаток (цифра)
        ADD     A,'0'
        PUSH    AF
        INC     C
        LD      A,(NumWork)                 ; число == 0 ?
        LD      B,A
        LD      A,(NumWork+1)
        OR      B
        LD      B,A
        LD      A,(NumWork+2)
        OR      B
        LD      B,A
        LD      A,(NumWork+3)
        OR      B
        JR      NZ,.gen
        LD      HL,NumStr
.out:
        POP     AF
        LD      (HL),A
        INC     HL
        DEC     C
        JR      NZ,.out
        LD      (HL),0
        RET

; NumWork(4 LE) /= 10 ; Out: A = остаток. Сохраняет C.
Div32by10:
        XOR     A                           ; rem = 0
        LD      H,A
        LD      A,(NumWork+3)
        LD      L,A
        CALL    Div16by10
        LD      H,A                          ; rem -> старший байт следующего
        LD      A,B
        LD      (NumWork+3),A
        LD      A,(NumWork+2)
        LD      L,A
        CALL    Div16by10
        LD      H,A
        LD      A,B
        LD      (NumWork+2),A
        LD      A,(NumWork+1)
        LD      L,A
        CALL    Div16by10
        LD      H,A
        LD      A,B
        LD      (NumWork+1),A
        LD      A,(NumWork+0)
        LD      L,A
        CALL    Div16by10
        PUSH    AF                           ; сохранить остаток
        LD      A,B
        LD      (NumWork+0),A
        POP     AF
        RET

; HL / 10 -> B = частное, A = остаток (HL <= 2559). Сохраняет C.
Div16by10:
        LD      B,0
.l:
        LD      A,L
        SUB     10
        LD      E,A
        LD      A,H
        SBC     A,0
        LD      D,A
        JR      C,.done
        EX      DE,HL
        INC     B
        JR      .l
.done:
        LD      A,L                          ; остаток (HL < 10)
        RET

; ====================================================================
; Сопоставление имени с маской.
;   Inp: HL -> имя, DE -> маска. Out: CF=0 совпало, CF=1 нет.
;   * = любая последовательность, ? = один символ, / == \, регистронезав.
; ====================================================================
MatchMask:
        XOR     A
        LD      (MmStar),A
.loop:
        LD      A,(HL)
        OR      A
        JR      Z,.nameEnd
        LD      A,(DE)
        CP      '*'
        JR      Z,.star
        CP      '?'
        JR      Z,.adv
        LD      A,(DE)
        CALL    NormChar
        LD      B,A
        LD      A,(HL)
        CALL    NormChar
        CP      B
        JR      Z,.adv
        LD      A,(MmStar)                  ; несовпадение — откат к '*'
        OR      A
        JR      Z,.noMatch
        LD      HL,(MmStarS)
        INC     HL
        LD      (MmStarS),HL                ; ss++ ; s = ss
        LD      DE,(MmStarP)
        INC     DE                          ; p = starP+1
        JR      .loop
.adv:
        INC     HL
        INC     DE
        JR      .loop
.star:
        LD      (MmStarP),DE                ; запомнить позицию '*'
        LD      (MmStarS),HL
        LD      A,1
        LD      (MmStar),A
        INC     DE
        JR      .loop
.nameEnd:
        LD      A,(DE)                      ; пропустить хвостовые '*'
        CP      '*'
        JR      NZ,.nameEnd2
        INC     DE
        JR      .nameEnd
.nameEnd2:
        LD      A,(DE)
        OR      A
        JR      Z,.match
.noMatch:
        SCF
        RET
.match:
        OR      A
        RET

NormChar:                                   ; A -> нормализованный символ
        CP      '/'
        JR      NZ,.n1
        LD      A,'\'
        RET
.n1:
        CP      'A'
        RET     C
        CP      'Z'+1
        RET     NC
        OR      #20
        RET

; ====================================================================
; РАСПАКОВКА (этап 2: stored -lh0-/-lz4-).
; Использует абсолютную навигацию по записям (Move_FP FromStart).
; ====================================================================
ExtractArchive:
        LD      HL,0                        ; RecordStart = 0
        LD      (RecordStart),HL
        LD      (RecordStart+2),HL
        CALL    PrepareOutBase
        CALL    EnsureOutDir                ; создать выходной каталог при необходимости
.loop:
        CALL    SeekToRecord
        JP      C,.done
        LD      HL,HdrBuf                   ; фиксированная часть (22 байта)
        LD      DE,22
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        JP      C,.done
        LD      A,E
        CP      22
        JP      C,.done
        LD      A,(HdrBuf)
        OR      A
        JP      Z,.done
        LD      A,(HdrBuf+#14)              ; уровень заголовка
        CP      2
        JR      C,.levelOk                  ; 0/1 поддержаны
        LD      HL,MsgUnsupLevel            ; 2/3 — этап 6
        CALL    PrintString
        JP      .done
.levelOk:
        LD      A,(HdrBuf+#15)              ; длина имени
        LD      (NameLen),A
        OR      A
        JR      Z,.noName
        LD      E,A
        LD      D,0
        LD      HL,NameBuf
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        JP      C,.done
.noName:
        LD      A,(NameLen)                 ; null-терминатор имени
        LD      L,A
        LD      H,0
        LD      DE,NameBuf
        ADD     HL,DE
        LD      (HL),0

        LD      HL,ExpectedCrc              ; CRC16 из заголовка (2 байта)
        LD      DE,2
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        JP      C,.done

        CALL    ComputeNextRecord
        CALL    WalkToData                  ; файл -> начало сжатых данных
        JP      C,.done

        CALL    EntrySelected               ; CF=1 -> пропустить запись
        JR      C,.advance
        CALL    ExtractEntry
.advance:
        LD      HL,(NextRecord)             ; RecordStart = NextRecord
        LD      (RecordStart),HL
        LD      HL,(NextRecord+2)
        LD      (RecordStart+2),HL
        JP      .loop
.done:
        RET

; Перемотка к RecordStart (FromStart). CF=1 при ошибке.
SeekToRecord:
        LD      HL,(RecordStart+2)          ; старшее слово
        LD      IX,(RecordStart)            ; младшее слово
        LD      BC,#0015                    ; B=00 FromStart, C=15 Move_FP
        LD      A,(ArcHandle)
        RST     Dss.Rst
        RET

; NextRecord = RecordStart + (2 + headerSize) + packedField
ComputeNextRecord:
        LD      HL,(RecordStart)
        LD      (NextRecord),HL
        LD      HL,(RecordStart+2)
        LD      (NextRecord+2),HL
        LD      A,(HdrBuf)                  ; + (headerSize + 2)
        LD      L,A
        LD      H,0
        INC     HL
        INC     HL
        LD      A,(NextRecord)
        ADD     A,L
        LD      (NextRecord),A
        LD      A,(NextRecord+1)
        ADC     A,H
        LD      (NextRecord+1),A
        LD      A,(NextRecord+2)
        ADC     A,0
        LD      (NextRecord+2),A
        LD      A,(NextRecord+3)
        ADC     A,0
        LD      (NextRecord+3),A
        LD      A,(HdrBuf+7)                ; + packedField (4 байта)
        LD      B,A
        LD      A,(NextRecord)
        ADD     A,B
        LD      (NextRecord),A
        LD      A,(HdrBuf+8)
        LD      B,A
        LD      A,(NextRecord+1)
        ADC     A,B
        LD      (NextRecord+1),A
        LD      A,(HdrBuf+9)
        LD      B,A
        LD      A,(NextRecord+2)
        ADC     A,B
        LD      (NextRecord+2),A
        LD      A,(HdrBuf+#0A)
        LD      B,A
        LD      A,(NextRecord+3)
        ADC     A,B
        LD      (NextRecord+3),A
        RET

; Дойти от позиции после CRC16 до начала сжатых данных.
; Level 0: пропустить ext-область. Level 1: пройти цепочку ext-заголовков.
; CF=1 при ошибке ввода-вывода.
WalkToData:
        LD      A,(HdrBuf+#14)              ; уровень заголовка
        OR      A
        JR      Z,.level0
        CP      1
        JR      Z,.level1
        OR      A                           ; уровень 2/3 не поддержан — данные
        RET                                 ; всё равно пропустим запись по NextRecord
.level0:
        LD      A,(HdrBuf)                  ; skip = hs - 22 - nameLen
        SUB     22
        LD      B,A
        LD      A,(NameLen)
        LD      C,A
        LD      A,B
        SUB     C
        LD      L,A
        LD      H,0
        JP      SkipFwd16
.level1:
        LD      A,(HdrBuf)                  ; skip = hs - 24 - nameLen (OS id + ext area)
        SUB     24
        LD      B,A
        LD      A,(NameLen)
        LD      C,A
        LD      A,B
        SUB     C
        LD      L,A
        LD      H,0
        CALL    SkipFwd16
        RET     C
.extLoop:
        LD      HL,ExtSize                  ; прочитать слово «размер ext-заголовка»
        LD      DE,2
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        RET     C
        LD      HL,(ExtSize)
        LD      A,H
        OR      L
        RET     Z                           ; 0 -> данные начинаются здесь
        DEC     HL                          ; пропустить (ExtSize - 2) байт тела
        DEC     HL
        CALL    SkipFwd16
        RET     C
        JR      .extLoop

; Перемотка вперёд на HL байт (FromCurrent). CF=1 при ошибке.
SkipFwd16:
        LD      A,H
        OR      L
        RET     Z                           ; ноль — ничего не делаем (CF=0)
        PUSH    HL
        POP     IX                          ; IX = младшее слово
        LD      HL,0                        ; старшее слово
        LD      BC,#0115                    ; FromCurrent
        LD      A,(ArcHandle)
        RST     Dss.Rst
        RET

; Выбрана ли запись для распаковки. CF=1 -> пропустить.
EntrySelected:
        CALL    IsDirEntry                  ; CF=0 -> это каталог (-lhd-), пропустить
        JR      C,.notDir
        SCF
        RET
.notDir:
        LD      A,(MaskBuf)
        OR      A
        JR      Z,.sel
        LD      HL,NameBuf
        LD      DE,MaskBuf
        CALL    MatchMask                   ; нет совпадения -> CF=1
        RET     C
.sel:
        OR      A
        RET

IsDirEntry:                                 ; CF=0 если метод "-lhd-", иначе CF=1
        LD      HL,HdrBuf+2
        LD      DE,MethodDir
        JP      Cmp5

; Распаковать текущую запись (файл стоит на начале данных).
ExtractEntry:
        CALL    IsStored
        JR      NC,.stored
        CALL    IsLh5
        JR      NC,.lh5
        CALL    IsLh1
        JR      NC,.lh1
        ; неподдержанный метод — не создаём файл
        LD      HL,NameBuf
        CALL    PrintName
        LD      HL,MsgUnsup
        JP      PrintString
.lh1:
        CALL    EnsurePages
        JR      C,.noMem
        CALL    OpenOutForEntry
        RET     C
        CALL    DecodeLh1
        CALL    CloseOutput
        JP      VerifyCrc
.stored:
        CALL    OpenOutForEntry             ; CF=1 -> пропуск
        RET     C
        CALL    ExtractStored
        CALL    CloseOutput
        JP      VerifyCrc
.lh5:
        CALL    EnsurePages
        JR      C,.noMem
        CALL    OpenOutForEntry
        RET     C
        CALL    DecodeLh5
        CALL    CloseOutput
        JP      VerifyCrc
.noMem:
        LD      HL,NameBuf
        CALL    PrintName
        LD      HL,MsgNoMem
        JP      PrintString

; Построить путь, проверить существующий, создать файл. CF=1 -> пропуск.
OpenOutForEntry:
        CALL    BuildOutPath
        CALL    CheckExisting               ; CF=1 -> пропуск
        RET     C
        LD      HL,OutPath
        LD      A,FileAttrib.Arch
        LD      C,Dss.Create
        RST     Dss.Rst
        JR      C,.err
        LD      (OutHandle),A
        OR      A
        RET
.err:
        LD      HL,NameBuf
        CALL    PrintName
        LD      HL,MsgCreateErr2
        CALL    PrintString
        LD      A,7
        CALL    SetExitCode
        SCF
        RET

; Метод -lh5-? CF=0 если да.
IsLh5:
        LD      HL,HdrBuf+2
        LD      DE,MethodLh5
        JP      Cmp5

; Метод -lh1-? CF=0 если да.
IsLh1:
        LD      HL,HdrBuf+2
        LD      DE,MethodLh1
        JP      Cmp5

; Метод «без сжатия»? CF=0 для -lh0-/-lz4-.
IsStored:
        LD      HL,HdrBuf+2
        LD      DE,MethodLh0
        CALL    Cmp5
        RET     NC
        LD      HL,HdrBuf+2
        LD      DE,MethodLz4
        JP      Cmp5

; Сравнить 5 байт (HL vs DE). CF=0 если равны, CF=1 иначе.
Cmp5:
        LD      B,5
.l:
        LD      A,(DE)
        CP      (HL)
        JR      NZ,.no
        INC     HL
        INC     DE
        DJNZ    .l
        OR      A
        RET
.no:
        SCF
        RET

; Копирование stored-данных вход->выход + CRC16. Размер = исходный (orig).
ExtractStored:
        LD      HL,(HdrBuf+#0B)
        LD      (Remaining),HL
        LD      HL,(HdrBuf+#0D)
        LD      (Remaining+2),HL
        LD      HL,0
        LD      (Crc16),HL
.loop:
        CALL    ComputeChunk                ; DE = ChunkLen
        LD      A,D
        OR      E
        RET     Z
        PUSH    DE
        LD      HL,CopyBuf                  ; читать ChunkLen из архива
        LD      A,(ArcHandle)
        LD      C,Dss.Read
        RST     Dss.Rst
        POP     BC
        RET     C
        PUSH    BC                          ; CRC по прочитанному блоку
        LD      HL,CopyBuf
        CALL    Crc16Update
        POP     BC
        LD      H,B                         ; записать ChunkLen в выход
        LD      L,C
        EX      DE,HL                       ; DE = ChunkLen
        LD      HL,CopyBuf
        LD      A,(OutHandle)
        LD      C,Dss.Write
        RST     Dss.Rst
        RET     C
        CALL    SubChunk                    ; Remaining -= ChunkLen
        JR      .loop

; ChunkLen = min(Remaining, размер CopyBuf). Результат в DE и (ChunkLen).
ComputeChunk:
        LD      A,(Remaining+2)
        LD      B,A
        LD      A,(Remaining+3)
        OR      B
        JR      NZ,.full
        LD      A,(Remaining+1)
        CP      high(CopyBufLen)
        JR      NC,.full                    ; >= CopyBufLen
        LD      DE,(Remaining)
        JR      .store
.full:
        LD      DE,CopyBufLen
.store:
        LD      (ChunkLen),DE
        RET

SubChunk:                                   ; Remaining -= ChunkLen
        LD      HL,(ChunkLen)
        LD      A,(Remaining)
        SUB     L
        LD      (Remaining),A
        LD      A,(Remaining+1)
        SBC     A,H
        LD      (Remaining+1),A
        LD      A,(Remaining+2)
        SBC     A,0
        LD      (Remaining+2),A
        LD      A,(Remaining+3)
        SBC     A,0
        LD      (Remaining+3),A
        RET

; CRC-16/ARC (poly 0xA001, init 0). HL=буфер, BC=кол-во. Обновляет (Crc16).
Crc16Update:
        LD      A,B
        OR      C
        RET     Z
        LD      DE,(Crc16)
.next:
        LD      A,(HL)
        XOR     E
        LD      E,A
        PUSH    BC
        LD      B,8
.bit:
        SRL     D
        RR      E
        JR      NC,.noXor
        LD      A,D
        XOR     #A0
        LD      D,A
        LD      A,E
        XOR     #01
        LD      E,A
.noXor:
        DJNZ    .bit
        POP     BC
        INC     HL
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,.next
        LD      (Crc16),DE
        RET

; Сверка CRC16, печать результата, код возврата.
VerifyCrc:
        LD      HL,NameBuf
        CALL    PrintName
        LD      HL,(Crc16)
        LD      DE,(ExpectedCrc)
        OR      A
        SBC     HL,DE
        JR      NZ,.bad
        LD      HL,MsgOk
        JP      PrintString
.bad:
        LD      HL,MsgBadCrc
        CALL    PrintString
        LD      A,#17
        JP      SetExitCode

; Печать имени записи + разделитель.
PrintName:
        CALL    PrintString
        LD      HL,MsgGap
        JP      PrintString

; OutBase = абсолютный выходной каталог с завершающим '\'.
;   нет аргумента        -> текущий каталог ("X:\curdir\")
;   относительный путь    -> "X:\curdir\" + путь + '\'
;   "X:..."/"\..."        -> приводится к абсолютному (диск/корень)
; Абсолютный путь обязателен: DSS-операции с относительным путём нестабильны
; (один файл мог попасть в X:\test, другой — в подкаталог текущего каталога).
PrepareOutBase:
        LD      HL,OutOrListPath
        LD      A,(HL)
        OR      A
        JR      Z,.default                  ; нет out_dir -> текущий каталог
        LD      DE,OutBase
        CALL    CopyStr
        LD      HL,OutBase
        CALL    AddBackSlash
        LD      HL,OutBase
        JP      MakePathAbsolute
.default:
        LD      HL,OutBase
        JP      GetCurDir

; HL -> ASCIIZ путь. Гарантирует завершающий '\'. Возврат: HL -> терминатор 0.
; Вход не должен быть пустым (DEC HL ниже).
AddBackSlash:
        XOR     A
.find:
        CP      (HL)
        JR      Z,.end
        INC     HL
        JR      .find
.end:
        DEC     HL
        LD      A,(HL)
        CP      '\'
        JR      Z,.sep
        CP      '/'
        JR      Z,.sep
        INC     HL
        LD      (HL),'\'
.sep:
        INC     HL
        LD      (HL),0
        RET

; Записать в HL абсолютный текущий каталог "X:\...\" (с завершающим '\').
; Возврат: HL -> терминатор 0. CurDisk должен сохранять HL (как в DSS).
GetCurDir:
        PUSH    HL
        LD      C,Dss.CurDisk
        RST     Dss.Rst                     ; A = id диска (best-effort)
        ADD     A,'A'
        LD      (HL),A
        INC     HL
        LD      (HL),':'
        INC     HL
        LD      C,Dss.CurDir                ; пишет путь каталога после "X:"
        RST     Dss.Rst
        POP     HL
        JP      AddBackSlash

; Привести путь в HL к абсолютному (на месте). Использует TempPath как буфер.
;   "X:..." -> без изменений; "\..." -> "X:\..."; иначе -> "X:\curdir\..."
MakePathAbsolute:
        LD      A,(HL)
        OR      A
        RET     Z                           ; пусто
        INC     HL
        LD      A,(HL)
        DEC     HL
        CP      ':'
        RET     Z                           ; "X:..." уже абсолютный
        PUSH    HL                          ; сохранить оригинал в TempPath
        LD      DE,TempPath
.save:
        LD      A,(HL)
        LD      (DE),A
        INC     HL
        INC     DE
        OR      A
        JR      NZ,.save
        POP     HL
        LD      A,(HL)
        CP      '\'
        JR      Z,.rootabs
        CP      '/'
        JR      Z,.rootabs
        CALL    GetCurDir                   ; HL = OutBase -> "X:\curdir\", HL->терминатор
        LD      DE,TempPath                 ; дописать оригинал
.append:
        LD      A,(DE)
        LD      (HL),A
        INC     HL
        INC     DE
        OR      A
        JR      NZ,.append
        RET
.rootabs:
        PUSH    HL                          ; путь "\...": подставить только "X:"
        LD      C,Dss.CurDisk
        RST     Dss.Rst
        ADD     A,'A'
        POP     HL
        LD      (HL),A
        INC     HL
        LD      (HL),':'
        INC     HL
        LD      DE,TempPath
.rapp:
        LD      A,(DE)
        LD      (HL),A
        INC     HL
        INC     DE
        OR      A
        JR      NZ,.rapp
        RET

; Создать все каталоги пути OutBase (best-effort, ошибки игнорируются).
; Для каждого разделителя '\'/'/'  делаем MkDir префикса.
EnsureOutDir:
        LD      HL,OutBase
        LD      A,(HL)
        OR      A
        RET     Z                           ; пусто -> текущий каталог
.scan:
        LD      A,(HL)
        OR      A
        RET     Z
        CP      '\'
        JR      Z,.mk
        CP      '/'
        JR      Z,.mk
        INC     HL
        JR      .scan
.mk:
        LD      (SaveSep),A                 ; сохранить разделитель
        LD      (HL),0                      ; временно завершить строку
        PUSH    HL
        LD      HL,OutBase
        LD      C,Dss.MkDir
        RST     Dss.Rst                     ; ошибки (уже существует) игнорируем
        POP     HL
        LD      A,(SaveSep)
        LD      (HL),A                      ; восстановить разделитель
        INC     HL
        JR      .scan

; OutPath = OutBase + NameBuf
BuildOutPath:
        LD      HL,OutBase
        LD      DE,OutPath
        CALL    CopyNoTerm
        LD      HL,NameBuf
.l:
        LD      A,(HL)
        LD      (DE),A
        OR      A
        RET     Z
        INC     HL
        INC     DE
        JR      .l

CopyNoTerm:                                 ; HL->DE до нуля (ноль не копируется)
        LD      A,(HL)
        OR      A
        RET     Z
        LD      (DE),A
        INC     HL
        INC     DE
        JR      CopyNoTerm

; Проверка существующего файла. CF=1 -> пропустить запись.
CheckExisting:
        LD      A,(OverwriteMode)
        CP      1
        JR      Z,.ok                       ; -o: перезаписывать
        LD      HL,OutPath
        LD      A,FileMode.Read
        LD      C,Dss.Open
        RST     Dss.Rst
        JR      C,.ok                       ; не открылся -> не существует
        LD      C,Dss.Close                 ; существует -> закрыть дескриптор
        RST     Dss.Rst
        LD      HL,NameBuf
        CALL    PrintName
        LD      HL,MsgExists
        CALL    PrintString
        LD      A,(OverwriteMode)
        CP      2
        JR      Z,.skip                     ; -s: тихо пропустить
        LD      A,7
        CALL    SetExitCode
.skip:
        SCF
        RET
.ok:
        OR      A
        RET

CloseOutput:
        LD      A,(OutHandle)
        LD      C,Dss.Close
        RST     Dss.Rst
        RET

SetExitCode:                                ; A=код, хранится первый ненулевой
        PUSH    HL
        PUSH    AF
        LD      HL,ExitCode
        LD      A,(HL)
        OR      A
        JR      NZ,.keep
        POP     AF
        LD      (HL),A
        POP     HL
        RET
.keep:
        POP     AF
        POP     HL
        RET

; ====================================================================
; Утилиты со строками
; ====================================================================
CopyStr:                                    ; HL -> DE (ASCIIZ)
        LD      A,(HL)
        LD      (DE),A
        OR      A
        RET     Z
        INC     HL
        INC     DE
        JR      CopyStr

HasWildcard:                                ; HL -> ASCIIZ ; CF=1 если есть * или ?
        LD      A,(HL)
        OR      A
        JR      Z,.no
        CP      '*'
        JR      Z,.yes
        CP      '?'
        JR      Z,.yes
        INC     HL
        JR      HasWildcard
.yes:
        SCF
        RET
.no:
        OR      A
        RET

NormalizeMask:                              ; маска, кончающаяся на \ или /, -> + '*'
        LD      HL,MaskBuf
        LD      A,(HL)
        OR      A
        RET     Z
.findEnd:
        LD      A,(HL)
        OR      A
        JR      Z,.atEnd
        INC     HL
        JR      .findEnd
.atEnd:
        DEC     HL
        LD      A,(HL)
        CP      '\'
        JR      Z,.append
        CP      '/'
        JR      Z,.append
        RET
.append:
        INC     HL
        LD      (HL),'*'
        INC     HL
        LD      (HL),0
        RET

; ====================================================================
; Печать ASCIIZ на экран (для баннеров/ошибок). HL -> строка.
; ====================================================================
PrintString:
        LD      C,Dss.PChars
        RST     Dss.Rst
        RET

CloseArchive:
        LD      A,(ArcHandle)
        LD      C,Dss.Close
        RST     Dss.Rst
        RET

CloseListFile:
        LD      A,(ListFileHandle)
        INC     A
        RET     Z
        DEC     A
        LD      C,Dss.Close
        RST     Dss.Rst
        RET

        INCLUDE "lh5.asm"
        INCLUDE "lh1.asm"

; ====================================================================
; Сообщения
; ====================================================================
MsgBanner:
        DB      "UNLHA 0.1 - LZH/LHA unpacker for Sprinter DSS", 13, 10, 0
MsgUsage:
        DB      "Usage:", 13, 10
        DB      " unlha.exe <archive.lzh> [<out_dir>] [<mask>]", 13, 10
        DB      " unlha.exe -l <archive.lzh> [<list_file>] [<mask>]", 13, 10
        DB      "Options: -l list  -o overwrite  -s skip  -x strip", 13, 10, 0
MsgUnsup:
        DB      "skip (method not supported yet)", 13, 10, 0
MsgOk:
        DB      "OK", 13, 10, 0
MsgBadCrc:
        DB      "CRC ERROR", 13, 10, 0
MsgExists:
        DB      "exists", 13, 10, 0
MsgUnsupLevel:
        DB      "header level 2/3 not supported yet", 13, 10, 0
MsgNoMem:
        DB      "no memory for decode", 13, 10, 0
MsgCreateErr2:
        DB      "cannot create", 13, 10, 0
MethodDir:
        DB      "-lhd-"
MethodLh0:
        DB      "-lh0-"
MethodLz4:
        DB      "-lz4-"
MethodLh5:
        DB      "-lh5-"
MethodLh1:
        DB      "-lh1-"
MsgOpenErr:
        DB      "Error: cannot open archive", 13, 10, 0
MsgCreateErr:
        DB      "Error: cannot create list file", 13, 10, 0
MsgMore:
        DB      "-- more (Esc to stop) --", 0
MsgGap:
        DB      "  ", 0
MsgCrLf:
        DB      13, 10, 0

; ====================================================================
; Переменные / буферы (RAM в WIN1, инициализируются образом EXE)
; ====================================================================
CopyBufLen      EQU     2048

CommandLinePtr: DW      0
ArcHandle:      DB      0
OutHandle:      DB      0
ListFileHandle: DB      #FF
ListResult:     DB      0
ExitCode:       DB      0
ModeList:       DB      0
OverwriteMode:  DB      0
StripMode:      DB      0
PosCount:       DB      0
NameLen:        DB      0
LineCount:      DB      0
SaveSep:        DB      0

MmStar:         DB      0
MmStarP:        DW      0
MmStarS:        DW      0

SkipWork:       DS      4
NumWork:        DS      4
NumStr:         DS      12
MethodStr:      DS      6

RecordStart:    DS      4
NextRecord:     DS      4
Remaining:      DS      4
ExpectedCrc:    DS      2
ExtSize:        DS      2
ChunkLen:       DS      2
Crc16:          DS      2

ParamBuf:       DS      128
ArchivePath:    DS      128
OutOrListPath:  DS      128
MaskBuf:        DS      130
HdrBuf:         DS      24
NameBuf:        DS      256
OutBase:        DS      256
TempPath:       DS      256
OutPath:        DS      320
CopyBuf:        DS      CopyBufLen

        END

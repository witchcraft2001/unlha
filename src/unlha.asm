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

        ; Режим распаковки пока не реализован (этап 2).
        LD      HL,MsgExtractTodo
        CALL    PrintString
        CALL    CloseArchive
        XOR     A
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
MsgExtractTodo:
        DB      "Extraction will be added in stage 2. Use -l to list.", 13, 10, 0
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
CommandLinePtr: DW      0
ArcHandle:      DB      0
ListFileHandle: DB      #FF
ListResult:     DB      0
ModeList:       DB      0
OverwriteMode:  DB      0
StripMode:      DB      0
PosCount:       DB      0
NameLen:        DB      0
LineCount:      DB      0

MmStar:         DB      0
MmStarP:        DW      0
MmStarS:        DW      0

SkipWork:       DS      4
NumWork:        DS      4
NumStr:         DS      12
MethodStr:      DS      6

ParamBuf:       DS      128
ArchivePath:    DS      128
OutOrListPath:  DS      128
MaskBuf:        DS      130
HdrBuf:         DS      24
NameBuf:        DS      256

        END

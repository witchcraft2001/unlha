; DSS EXE header helpers for Sprinter programs.
; Layout matches Estex-DSS _sEXE_HEADER:
;   00..02  "EXE"
;   03      EXE version
;   04..07  32-bit code offset in file, normally #00000200
;   08..09  loader length/address field, zero when no preloader is used
;   10..15  reserved
;   16..17  load address
;   18..19  start PC
;   20..21  initial SP
;   22..511 reserved/application info area

DSS_EXE_HEADER_SIZE   EQU #0200
DSS_EXE_CODE_OFFSET   EQU #0200
DSS_EXE_DEFAULT_STACK EQU #BFFF

        MACRO DSS_EXE_HEADER exe_version, loader_value, load_addr, start_addr, stack_addr
DssExeHeader:
        DB      "EXE"
        DB      exe_version
        DD      DSS_EXE_CODE_OFFSET
        DW      loader_value
        DW      #0000
        DW      #0000
        DW      #0000
        DW      load_addr
        DW      start_addr
        DW      stack_addr
        DS      DSS_EXE_HEADER_SIZE - ($ - DssExeHeader), #00
        ENDM

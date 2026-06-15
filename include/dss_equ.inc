; DSS call numbers (taken from dss_equ.asm)
; Use: INCLUDE "manual/include/dss_equ.inc"

Dss.Rst         EQU     10h    ; RST vector used by DSS dispatcher

Dss.Version     EQU     00h    ; query DSS version (D/E = major/minor)
Dss.ChDisk      EQU     01h    ; change current logical drive
Dss.CurDisk     EQU     02h    ; get active drive id
Dss.DskInfo     EQU     03h    ; fetch free/total clusters info
Dss.BootDsk     EQU     09h    ; return system (boot) drive

; Files
Dss.Create      EQU     0Ah    ; create/overwrite file by name
Dss.Create_N    EQU     0Bh    ; create new file only if absent
Dss.Erase       EQU     0Dh    ; historical DSS delete/erase alias
Dss.Delete      EQU     0Eh    ; delete file or empty dir
Dss.Rename      EQU     10h    ; rename file/directory
Dss.Open        EQU     11h    ; open existing file
Dss.Close       EQU     12h    ; close handle
Dss.Read        EQU     13h    ; read bytes from handle
Dss.Write       EQU     14h    ; write bytes to handle
Dss.Move_FP     EQU     15h    ; move file pointer (seek)
Dss.MoveFp.FromStart   EQU 00h ; Move_FP subfunction: seek from start
Dss.MoveFp.FromCurrent EQU 01h ; Move_FP subfunction: seek from current
Dss.MoveFp.FromEnd     EQU 02h ; Move_FP subfunction: seek from end
Dss.Attrib      EQU     16h    ; change/read file attributes
Dss.Get_D_T     EQU     17h    ; read time/date stamp
Dss.Put_D_T     EQU     18h    ; write time/date stamp
Dss.F_First     EQU     19h    ; start directory search
Dss.Find.DosName EQU    01h    ; F_First subfunction: DOS 8.3 name
Dss.F_Next      EQU     1Ah    ; continue directory search
Dss.MkDir       EQU     1Bh    ; create directory
Dss.RmDir       EQU     1Ch    ; remove directory
Dss.ChDir       EQU     1Dh    ; change current directory
Dss.CurDir      EQU     1Eh    ; get current directory path
Dss.SysTime     EQU     21h    ; read RTC/system time
Dss.SetTime     EQU     22h    ; set RTC/system time

; Keyboard
Dss.WaitKey     EQU     30h    ; blocking key read
Dss.ScanKey     EQU     31h    ; get key with modifiers
Dss.EchoKey     EQU     32h    ; print key to TTY
Dss.CtrlKey     EQU     33h    ; control keyboard vars
Dss.K_Clear     EQU     35h    ; clear keyboard buffer
Dss.K_Setup     EQU     36h    ; install keyboard handler
Dss.TestKey     EQU     37h    ; non-blocking keyboard test

; Memory
Dss.SetWin      EQU     38h    ; connect arbitrary page to window
Dss.SetWin1     EQU     39h    ; connect page to window #4000
Dss.SetWin2     EQU     3Ah    ; connect page to window #8000
Dss.SetWin3     EQU     3Bh    ; connect page to window #C000
Dss.InfoMem     EQU     3Ch    ; get block info by id
Dss.GetMem      EQU     3Dh    ; allocate block (N pages)
Dss.FreeMem     EQU     3Eh    ; free block by id
Dss.SetMem      EQU     3Fh    ; mark block with owner id

; Execution
Dss.Exec        EQU     40h    ; load/execute EXE file
Dss.Exit        EQU     41h    ; terminate current task
Dss.Wait        EQU     42h    ; wait for child termination

; Strings / environment
Dss.GSwitch     EQU     43h    ; parse command line switch
Dss.DosName     EQU     44h    ; convert to/from 8.3 name
Dss.Ex_Path     EQU     45h    ; read command line buffer
Dss.ExPath.GSwitch EQU  07h    ; Ex_Path subfunction used by legacy tools
Dss.Environ     EQU     46h    ; access environment variables
Dss.AppInfo     EQU     47h    ; get parent/app descriptor

; Screen
Dss.SetVMod     EQU     50h    ; set video mode (text/gfx)
Dss.GetVMod     EQU     51h    ; read current video mode
Dss.Locate      EQU     52h    ; move text cursor
Dss.Cursor      EQU     53h    ; enable/disable cursor
Dss.SelPage     EQU     54h    ; select text page
Dss.Scroll      EQU     55h    ; scroll window
Dss.Clear       EQU     56h    ; clear window/screen
Dss.RdChar      EQU     57h    ; read char/attr from screen
Dss.WrChar      EQU     58h    ; write char/attr
Dss.WinCopy     EQU     59h    ; copy window to buffer
Dss.WinRest     EQU     5Ah    ; restore window from buffer
Dss.PutChar     EQU     5Bh    ; print char with attribute
Dss.PChars      EQU     5Ch    ; print ASCIIZ string
Dss.Print       EQU     5Fh    ; raw printer output

; Helpers
FileMode.RW       EQU   00h    ; open for read/write
FileMode.Read     EQU   01h    ; open read-only
FileMode.Write    EQU   02h    ; open write-only

FileAttrib.Normal EQU   00h    ; regular file
FileAttrib.RDOnly EQU   01h    ; read-only
FileAttrib.Hidden EQU   02h    ; hidden entry
FileAttrib.System EQU   04h    ; system file
FileAttrib.Label  EQU   08h    ; volume label
FileAttrib.Dir    EQU   10h    ; directory
FileAttrib.Arch   EQU   20h    ; archive bit

; DSS error codes (from Sprinter Programming guide, page 27)
Dss.Err.Success        EQU 00h    ; success (CF reset)
Dss.Err.InvFunc        EQU 01h    ; invalid function number
Dss.Err.InvDrive       EQU 02h    ; invalid drive letter
Dss.Err.FileNotFound   EQU 03h    ; file not found
Dss.Err.PathNotFound   EQU 04h    ; path not found
Dss.Err.InvHandle      EQU 05h    ; invalid file handle
Dss.Err.TooManyOpen    EQU 06h    ; too many open files
Dss.Err.FileExists     EQU 07h    ; file already exists
Dss.Err.ReadOnly       EQU 08h    ; write attempt to read-only file
Dss.Err.RootOverflow   EQU 09h    ; root directory overflow
Dss.Err.NoSpace        EQU 0Ah    ; no free disk space
Dss.Err.DirNotEmpty    EQU 0Bh    ; directory not empty
Dss.Err.RemoveCurrDir  EQU 0Ch    ; attempt to remove current dir
Dss.Err.InvMedia       EQU 0Dh    ; invalid media type
Dss.Err.InvOp          EQU 0Eh    ; invalid operation
Dss.Err.DirExists      EQU 0Fh    ; directory already exists
Dss.Err.InvFilename    EQU 10h    ; invalid filename
Dss.Err.InvExe         EQU 11h    ; invalid EXE header
Dss.Err.UnsupportedExe EQU 12h    ; unsupported EXE format
Dss.Err.Permission     EQU 13h    ; permission denied
Dss.Err.NotReady       EQU 14h    ; device not ready
Dss.Err.SeekError      EQU 15h    ; seek error
Dss.Err.SectorNotFound EQU 16h    ; sector not found
Dss.Err.CrcError       EQU 17h    ; CRC error
Dss.Err.WriteProtect   EQU 18h    ; write protected media
Dss.Err.ReadError      EQU 19h    ; read error
Dss.Err.WriteError     EQU 1Ah    ; write error
Dss.Err.DriveFailure   EQU 1Bh    ; drive failure
Dss.Err.Unknown28      EQU 1Ch    ; reserved / unknown
Dss.Err.Unknown29      EQU 1Dh    ; reserved / unknown
Dss.Err.NoFreeMemory   EQU 1Eh    ; not enough memory pages
Dss.Err.InvMemBlock    EQU 1Fh    ; invalid memory block ID
Dss.Err.Unknown32      EQU 20h    ; reserved / unknown

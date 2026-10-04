!to "Pathfinder.d64",d64,"pathfinder.gui","pathfinder disk"

; Pathfinder - a tip-over puzzle for GUI64 (MAC and WIN design)
;
; The playfield has 6 x 6 cells. Some cells hold towers of stacked
; boxes: red (height 1, the target), yellow (2), green (3) and blue (4).
; A level uses at most 1 red, 10 yellow, 4 green and 2 blue towers.
; The player starts on a tower and has to find a path to the red box:
; a tower the player can reach is tipped over to the north, south, west
; or east. It then lies on the cells next to it (as many cells as it was
; high, they must be free and inside the playfield), and the player
; stands on its far end. The player can walk over all boxes that touch
; each other (standing or lying). The level is solved when the red box
; can be reached.
;
; Controls: CRSR keys or W/A/S/D move the cursor to a tower,
;           RETURN or SPACE selects it (the player walks onto it),
;           then CRSR or W/A/S/D tips it over (RETURN/SPACE: cancel).
;           U: undo, R: restart the level.
;           Mouse: click a tower to select it, then click a cell
;           in its row or column to tip it in that direction.
;
; Each cell is 2x2 chars. The cursor blinks (GUI64 timer, the window is
; repainted). The app only uses the GUI64 API (gui64.inc.asm).

!source "gui64.inc.asm"

!zone Constants
WT_PATHFINDER    = 56 ; app window types start at 50
CT_PF_BOARD      = 50 ; app control types start at 50
ID_MENU_GAME     = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

BOARD_N          = 6                ; 6 x 6 cells
BOARD_SIZE       = BOARD_N * BOARD_N
BOARD_X          = 2                ; position of the board control
BOARD_Y          = 4
BOARD_W          = 2 * BOARD_N      ; a cell is 2x2 chars
MAX_UNDO         = 16               ; a level has at most 16 towers to tip
UNDO_REC         = BOARD_SIZE + 1   ; board + player position

; Board cells: 0 = empty, 1..4 = standing tower of this height,
; CELL_LYING + height = part of a tipped tower
CELL_LYING       = $10

; Directions
DIR_N            = 0
DIR_S            = 1
DIR_W            = 2
DIR_E            = 3

; Game states
ST_SELECT        = 0 ; cursor selects a tower
ST_STUCK         = 1 ; no tower can be tipped any more (undo/restart)
ST_DIR           = 2 ; a tower is selected, cursor keys tip it
ST_SOLVED        = 3 ; path to the red box found

BLINK_TICKS      = 4 ; cursor blinks every 4/10 s

; Keys (see MicroMoves): key_shifted tells up from down and left from right
KEY_CRSR_UD      = $fb
KEY_CRSR_LR      = $f8
KEY_RETURN       = $fc

; Colors
COL_RED          = CL_RED
COL_YELLOW       = CL_YELLOW
COL_GREEN        = CL_DARKGREEN
COL_BLUE         = CL_DARKBLUE
COL_CURSOR       = CL_BLACK
SOLID_CHAR       = 160

STATUS_LEN       = 14
LEVEL_SIZE       = BOARD_SIZE + 2   ; 6x6 matrix + start column, row

!zone Init
*=$b000
                lda #WT_PATHFINDER              ; look for window with type "WT_PATHFINDER"
                sta Param0                      ;
                jsr GUI_FindWndByType           ;
                bcc +                           ; if not found, start app
                stx Param0                      ; otherwise, make this window
                jmp GUI_SelectTopWindow         ; the top window and leave
                ; Start app
+               ldx #<CharList                  ; Register
                ldy #>CharList                  ; the
                lda #NUM_APP_CHARS              ; chars defined in CharList
                jsr GUI_RegisterChars           ; (see zone "Data" below)
                ;
                ldx #<CtrlAction                ; Behavior of the board control
                ldy #>CtrlAction                ; (void, events are handled
                jsr GUI_SetCtrlActionsRoutine   ; in the window proc)
                ;
                ldx #<PaintCtrls                ; Look of the
                ldy #>PaintCtrls                ; board control
                jsr GUI_SetPaintCtrlsRoutine    ;
                ;
                ldx #<Wnd_Pathfinder            ; Create the window with
                ldy #>Wnd_Pathfinder            ; its controls
                jsr GUI_CreateWindowEx          ;
                ;
                jsr GUI_GetDesign               ; Z=1: WIN, Z=0: MAC
                beq +                           ;
                dec WindowHeight                ; For MAC design, the menu bar
                jsr GUI_UpdateWindow            ; is not in the window
+               ; Menu
                jsr GUI_SelectControl0          ; Associate the menu bar
                ldx #<Str_PFMenubar             ; strings with control 0
                ldy #>Str_PFMenubar             ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                ;
                ldx #<TimerProc                 ; blinking cursor
                ldy #>TimerProc                 ; (every 1/10 second)
                jsr GUI_InitTimer
                jsr GUI_StartTimer
                ;
                lda #0                          ; start with
                sta CurLevel                    ; the first level
                jmp RestartLevel

; Timer handler (GUI64 main loop, not IRQ): lets the cursor blink
TimerProc       lda State                       ; only while the cursor
                cmp #ST_DIR                     ; selects a tower
                bcs .rts
                inc BlinkCnt
                lda BlinkCnt
                cmp #BLINK_TICKS
                bcc .rts
                lda #0
                sta BlinkCnt
                lda WindowType                  ; only while the window is
                cmp #WT_PATHFINDER              ; the current one,
                bne .rts
                lda WindowBits                  ; not minimized
                and #BIT_WND_ISMINIMIZED
                bne .rts
                lda ProgramMode                 ; and no menu or dialog is
                bne .rts                        ; open
                lda Blink
                eor #1
                sta Blink
                jmp GUI_RepaintCurWindow
.rts            rts

!zone WndProc
; Window Proc (event handler for window)
PF_WndProc      jsr GUI_StdWndProc              ; MUST always be called
                lda wndParam0                   ; app shuts down (window closed)?
                cmp #EC_SHUTDOWN
                bne +
                jmp GUI_StopTimer               ; then stop the timer
+               lda wndParam1                   ; ProgramMode
                bmi .leave                      ; leave in dialog mode
                beq .normal                     ; normal mode
                ; menu mode
                lda wndParam0                   ; event code
                cmp #EC_LBTNPRESS               ;
                bne .leave                      ;
                jsr GUI_IsInCurMenu             ; mouse in current menu?
                bcc .leave                      ;
                jsr GUI_GetCurMenuID            ;
                cmp #ID_MENU_GAME               ;
                bne +                           ;
                jmp GameMenuClicked             ;
+               jmp HelpMenuClicked             ;
.normal         lda wndParam0                   ; event code
                cmp #EC_KEYPRESS                ;
                bne +                           ;
                jmp KeyPressed                  ;
+               cmp #EC_LBTNPRESS               ;
                bne .leave                      ;
                jsr GUI_IsInCurControl          ; mouse in a control?
                bcc .leave                      ;
                lda ControlType                 ;
                cmp #CT_PF_BOARD                ; was it the board?
                bne .leave                      ;
                jmp BoardClicked                ;
.leave          rts

; Invoked when an item in the game menu was clicked
GameMenuClicked lda CurMenuItem                 ; 0: Restart
                beq RestartLevel                ;
                cmp #1                          ; 1: Undo
                bne +                           ;
                jmp Undo                        ;
+               cmp #2                          ; 2: Next
                beq NextLevel                   ;
                cmp #3                          ; 3: Prev
                beq PrevLevel                   ;
                jsr GUI_KillCurWindow           ; 4: Quit (sends EC_SHUTDOWN,
                jmp GUI_Repaint                 ; which stops the timer)

HelpMenuClicked lda CurMenuItem
                bne +
                ldx #<Str_Mess_Help             ; 0: Help
                ldy #>Str_Mess_Help
                jmp GUI_ShowMessage
+               ldx #<Str_Mess_About            ; 1: About
                ldy #>Str_Mess_About
                jmp GUI_ShowMessage

NextLevel       inc CurLevel
                lda CurLevel
                cmp #NUM_LEVELS                 ; after the last level
                bcc RestartLevel                ; start over with
                lda #0                          ; the first one
                sta CurLevel
                beq RestartLevel                ; jmp

PrevLevel       lda CurLevel
                bne +
                lda #NUM_LEVELS                 ; before the first level
+               sec                             ; comes the last one
                sbc #1
                sta CurLevel
                ; fall through

RestartLevel    jsr LoadLevel
                jmp GUI_RepaintCurWindow

!zone Keys
; Keyboard: key in actkey
KeyPressed      lda State
                cmp #ST_SOLVED                  ; level solved:
                beq NextLevel                   ; any key starts the next one
                lda actkey
                cmp #KEY_CRSR_UD                ; CRSR down,
                bne +
                ldx #DIR_S
                lda key_shifted                 ; with SHIFT: up
                beq .dir
                ldx #DIR_N
                beq .dir                        ; jmp (DIR_N = 0)
+               cmp #KEY_CRSR_LR                ; CRSR right,
                bne +
                ldx #DIR_E
                lda key_shifted                 ; with SHIFT: left
                beq .dir
                ldx #DIR_W
                bne .dir                        ; jmp
+               cmp #KEY_RETURN                 ; RETURN or SPACE:
                beq .select                     ; select a tower / cancel
                cmp #" "
                beq .select
                and #%01111111                  ; ignore shift for letters
                ldx #DIR_N
                cmp #"W"
                beq .dir
                ldx #DIR_S
                cmp #"S"
                beq .dir
                ldx #DIR_W
                cmp #"A"
                beq .dir
                ldx #DIR_E
                cmp #"D"
                beq .dir
                cmp #"U"
                bne +
                jmp Undo
+               cmp #"R"
                beq RestartLevel
                rts
.dir            txa
                ldx State                       ; a tower is selected:
                cpx #ST_DIR                     ; tip it over
                bne +
                jmp TipTower
+               jmp MoveCursor                  ; otherwise move the cursor
.select         lda State
                cmp #ST_DIR
                bne +
                jmp CancelSelect
+               jmp SelectTower

!zone Mouse
; Mouse: in direction mode, a click in the row or column of the selected
; tower tips it in this direction. Otherwise the clicked cell is selected.
BoardClicked    lda State
                cmp #ST_SOLVED                  ; level solved:
                bne +                           ; a click starts the next one
                jmp NextLevel
+               jsr GUI_GetMousePosInWnd        ; mouse coords relative to window
                lda MousePosInWndY
                sec
                sbc ControlPosY
                lsr                             ; 2 rows per cell
                cmp #BOARD_N
                bcs .done
                tax
                lda MousePosInWndX
                sec
                sbc ControlPosX
                lsr                             ; 2 columns per cell
                cmp #BOARD_N
                bcs .done
                clc
                adc Mul6,x
                sta ClickPos                    ; index of the clicked cell
                lda State
                cmp #ST_DIR
                bne .select
                ldx ClickPos
                ldy SelPos
                cpx SelPos                      ; selected tower again:
                bne +                           ; cancel
                jmp CancelSelect
+               lda RowOf,x                     ; same row?
                cmp RowOf,y
                bne .column
                lda ColOf,x
                cmp ColOf,y
                lda #DIR_E
                bcs .tip
                lda #DIR_W
                bne .tip                        ; jmp
.column         lda ColOf,x                     ; same column?
                cmp ColOf,y
                bne .select
                lda RowOf,x
                cmp RowOf,y
                lda #DIR_S
                bcs .tip
                lda #DIR_N
.tip            jmp TipTower
.select         lda State                       ; another cell: a selected
                cmp #ST_DIR                     ; tower is deselected
                bne +
                jsr SetIdleState
+               lda ClickPos
                sta CursorPos
                jmp SelectTower
.done           rts

!zone Game
!zone MoveCursor
; Moves the cursor one cell. A = direction
MoveCursor      tax
                ldy CursorPos
                lda RowOf,y
                clc
                adc DirDRow,x
                cmp #BOARD_N                    ; outside (also -1)?
                bcs .done
                sta TmpRow
                lda ColOf,y
                clc
                adc DirDCol,x
                cmp #BOARD_N
                bcs .done
                ldy TmpRow
                clc
                adc Mul6,y
                sta CursorPos
                jsr ShowCursor
                jmp GUI_RepaintCurWindow
.done           rts

!zone ShowCursor
; The cursor is shown at once (and the blink phase starts again)
ShowCursor      lda #1
                sta Blink
                lda #0
                sta BlinkCnt
                rts

!zone SelectTower
; Selects the tower under the cursor, if the player can reach it and
; it can be tipped over
SelectTower     jsr ShowCursor
                ldx CursorPos
                lda Board,x
                beq .noTower                    ; empty
                cmp #1
                beq .target                     ; red box
                cmp #5
                bcs .noTower                    ; lying tower
                jsr CalcReach
                ldx CursorPos
                lda Reach,x
                beq .far
                stx SelPos                      ; select it, the player
                stx PlayerPos                   ; walks onto it
                lda #ST_DIR
                sta State
                ldx #<Msg_Dir
                ldy #>Msg_Dir
                bne .status                     ; jmp
.noTower        ldx #<Msg_NoTower
                ldy #>Msg_NoTower
                bne .status                     ; jmp
.target         ldx #<Msg_Target
                ldy #>Msg_Target
                bne .status                     ; jmp
.far            ldx #<Msg_Far
                ldy #>Msg_Far
.status         jsr SetStatus
                jmp GUI_RepaintCurWindow

!zone CancelSelect
; Cancels the selection of a tower
CancelSelect    lda SelPos
                sta CursorPos
                jsr ShowCursor
                jsr SetIdleState
                jmp GUI_RepaintCurWindow

!zone TipTower
; Tips the selected tower over. A = direction
TipTower        ldx SelPos
                jsr CanTip
                bcs +
                ldx #<Msg_CantTip               ; no room there
                ldy #>Msg_CantTip
                jsr SetStatus
                jmp GUI_RepaintCurWindow
+               jsr SaveUndo
                ldx SelPos                      ; the base gets empty
                lda #0
                sta Board,x
                lda TipH
                ora #CELL_LYING
                ldy #0
-               ldx TipCells,y                  ; the tower lies on the
                sta Board,x                     ; cells next to it
                iny
                cpy TipH
                bne -
                stx PlayerPos                   ; player on the far end
                stx CursorPos
                jsr ShowCursor
                jsr CalcReach                   ; red box reachable?
                ldx #BOARD_SIZE-1
-               lda Reach,x
                beq +
                lda Board,x
                cmp #1
                beq .solved
+               dex
                bpl -
                jsr SetIdleState
                jmp GUI_RepaintCurWindow
.solved         stx PlayerPos                   ; the player walks onto
                stx CursorPos                   ; the red box
                lda #ST_SOLVED
                sta State
                ldx #<Msg_Solved
                ldy #>Msg_Solved
                jsr SetStatus
                jsr GUI_RepaintCurWindow
                ldx #<Str_Mess_Solved
                ldy #>Str_Mess_Solved
                lda CurLevel
                cmp #NUM_LEVELS-1
                bne +
                ldx #<Str_Mess_AllDone
                ldy #>Str_Mess_AllDone
+               jmp GUI_ShowMessage

!zone SetIdleState
; State ST_SELECT if a tower can be tipped, otherwise ST_STUCK,
; and the matching status text
SetIdleState    jsr HasMoves
                bcc +
                lda #ST_SELECT
                sta State
                ldx #<Msg_Select
                ldy #>Msg_Select
                jmp SetStatus
+               lda #ST_STUCK
                sta State
                ldx #<Msg_Stuck
                ldy #>Msg_Stuck
                jmp SetStatus

!zone Undo
; Undoes the last tip
Undo            lda State
                cmp #ST_SOLVED
                beq .done
                lda UndoCount
                beq .done
                dec UndoCount
                jsr UndoPtr
                ldy #UNDO_REC-1
                lda (ZP_FB),y
                sta PlayerPos
                sta CursorPos
                dey
-               lda (ZP_FB),y
                sta Board,y
                dey
                bpl -
                jsr ShowCursor
                jsr SetIdleState
                jmp GUI_RepaintCurWindow
.done           rts

!zone SaveUndo
; Saves board and player position before a tip
SaveUndo        lda UndoCount
                cmp #MAX_UNDO
                bcs .done                       ; (can't happen)
                jsr UndoPtr
                ldy #UNDO_REC-1
                lda PlayerPos
                sta (ZP_FB),y
                dey
-               lda Board,y
                sta (ZP_FB),y
                dey
                bpl -
                inc UndoCount
.done           rts

!zone UndoPtr
; ZP_FB/FC = address of undo record UndoCount
UndoPtr         lda #<UndoBuf
                sta ZP_FB
                lda #>UndoBuf
                sta ZP_FC
                ldx UndoCount
                lda #UNDO_REC
                ; fall through

; Adds X times A to ZP_FB/FC (address of record X in a table)
AddRecords      sta RecSize
                txa
                beq .done
-               lda ZP_FB
                clc
                adc RecSize
                sta ZP_FB
                bcc +
                inc ZP_FC
+               dex
                bne -
.done           rts

!zone CanTip
; Checks if the standing tower at X can be tipped in direction A.
; C=1: yes, the TipH cells it would lie on are in TipCells.
CanTip          sta TipDir
                lda Board,x
                sta TipH
                lda RowOf,x
                sta TipRow
                lda ColOf,x
                sta TipCol
                ldy #0
-               ldx TipDir
                lda TipRow
                clc
                adc DirDRow,x
                sta TipRow
                cmp #BOARD_N                    ; outside (also -1)?
                bcs .no
                lda TipCol
                clc
                adc DirDCol,x
                sta TipCol
                cmp #BOARD_N
                bcs .no
                ldx TipRow
                lda Mul6,x
                clc
                adc TipCol
                tax
                lda Board,x                     ; cell must be free
                bne .no
                txa
                sta TipCells,y
                iny
                cpy TipH
                bne -
                sec
                rts
.no             clc
                rts

!zone HasMoves
; C=1 if the player can reach a tower that can be tipped over
HasMoves        jsr CalcReach
                ldx #BOARD_SIZE-1
.cell           stx ScanPos
                lda Reach,x
                beq .next
                lda Board,x
                cmp #2                          ; standing tower 2..4
                bcc .next
                cmp #5
                bcs .next
                lda #DIR_E
                sta ScanDir
-               ldx ScanPos
                lda ScanDir
                jsr CanTip
                bcs .yes
                dec ScanDir
                bpl -
.next           ldx ScanPos
                dex
                bpl .cell
                clc
.yes            rts

!zone CalcReach
; Reach[i] = 1 for all cells the player can walk to: all boxes that are
; connected to the player's box
CalcReach       ldx #BOARD_SIZE-1
                lda #0
-               sta Reach,x
                dex
                bpl -
                ldx PlayerPos
                lda #1
                sta Reach,x
.pass           lda #0
                sta Changed
                ldx #BOARD_SIZE-1
.cell           lda Reach,x
                bne .next
                lda Board,x
                beq .next
                cpx #BOARD_N                    ; north
                bcc +
                lda Reach-BOARD_N,x
                bne .mark
+               cpx #BOARD_SIZE-BOARD_N         ; south
                bcs +
                lda Reach+BOARD_N,x
                bne .mark
+               lda ColOf,x                     ; west
                beq +
                lda Reach-1,x
                bne .mark
+               lda ColOf,x                     ; east
                cmp #BOARD_N-1
                beq .next
                lda Reach+1,x
                beq .next
.mark           lda #1
                sta Reach,x
                sta Changed
.next           dex
                bpl .cell
                lda Changed
                bne .pass
                rts

!zone SetStatus
; Copies the null terminated message at X/Y to the status label,
; filled up with spaces
SetStatus       stx ZP_FB
                sty ZP_FC
                ldy #0
-               lda (ZP_FB),y
                beq +
                sta StatusText,y
                iny
                bne -
+               lda #" "
-               cpy #STATUS_LEN
                bcs +
                sta StatusText,y
                iny
                bne -
+               rts

!zone LoadLevel
; Builds the board of level CurLevel (see "Levels" below)
LoadLevel       lda #<Levels
                sta ZP_FB
                lda #>Levels
                sta ZP_FC
                ldx CurLevel
                lda #LEVEL_SIZE
                jsr AddRecords
                ldy #BOARD_SIZE-1               ; the 6x6 matrix
-               lda (ZP_FB),y                   ; "1".."4": tower height
                sec
                sbc #"1"
                cmp #4
                bcc +
                lda #$ff                        ; everything else: empty
+               clc
                adc #1
                sta Board,y
                dey
                bpl -
                ldy #BOARD_SIZE+1               ; start row
                lda (ZP_FB),y
                tax
                dey                             ; start column
                lda (ZP_FB),y
                clc
                adc Mul6,x
                sta PlayerPos
                sta CursorPos
                lda #0
                sta UndoCount
                jsr ShowCursor
                jsr SetIdleState
                ; Level number
                ldx CurLevel
                inx
                txa
                ldx #"0"
-               cmp #10
                bcc +
                sbc #10
                inx
                bne -
+               stx LevelDigits
                ora #$30
                sta LevelDigits+1
                rts

!zone Control_Action_Paint
; X is ControlType
CtrlAction      rts                             ; Must be provided if new controls are registered

; X is ControlType
PaintCtrls      cpx #CT_PF_BOARD
                beq PaintBoard
                rts

; FDFE points to position of control in paint buffer
; 0203 points to position of control in color buffer
; Each board row is built in LineTop/LineBot/LineCol first
PaintBoard      jsr GUI_GetCSTMWindowColor      ; empty cells look like
                sta FloorColor                  ; the window background
                lda #0
                sta PaintCell
                lda #BOARD_N
                sta PaintRow
.row            lda #0
                sta PaintX
.cell           ldy PaintCell
                jsr CellLook
                ldx PaintX
                lda CellChars
                sta LineTop,x
                lda CellChars+1
                sta LineTop+1,x
                lda CellChars+2
                sta LineBot,x
                lda CellChars+3
                sta LineBot+1,x
                lda CellColor
                sta LineCol,x
                sta LineCol+1,x
                inc PaintCell
                inx
                inx
                stx PaintX
                cpx #BOARD_W
                bne .cell
                ldy #BOARD_W-1                  ; upper char row
-               lda LineTop,y
                sta (ZP_FD),y
                lda LineCol,y
                sta ($02),y
                dey
                bpl -
                jsr GUI_AddBufWidthToFD         ; one char down in paint buffer
                jsr GUI_AddBufWidthTo02         ; one char down in color buffer
                ldy #BOARD_W-1                  ; lower char row
-               lda LineBot,y
                sta (ZP_FD),y
                lda LineCol,y
                sta ($02),y
                dey
                bpl -
                jsr GUI_AddBufWidthToFD
                jsr GUI_AddBufWidthTo02
                dec PaintRow
                bne .row
                rts

; Y = cell index. Returns the 4 chars of the cell (TL, TR, BL, BR) in
; CellChars and its color in CellColor. Y is preserved.
CellLook        lda Board,y
                sta CellVal
                bne .box
                ; empty: a dot in the middle of the cell, the space
                ; char is filled with the color
                lda #APP_CHAR_FLOOR
                sta CellChars
                lda #APP_CHAR_BLANK
                sta CellChars+1
                sta CellChars+2
                sta CellChars+3
                lda FloorColor
                sta CellColor
                bne .cursor                     ; jmp
.box            and #%00000111                  ; color of the height
                tax
                lda HeightColor,x
                sta CellColor
                lda CellVal
                and #CELL_LYING
                beq .standing
                lda #APP_CHAR_LYING             ; lying tower: hatched
                sta CellChars
                sta CellChars+1
                sta CellChars+2
                sta CellChars+3
                bne .player                     ; jmp
.standing       lda PipMask,x                   ; standing tower: a box with
                sta PipBits                     ; as many pips as it is high
                ldx #0
-               lsr PipBits
                txa
                bcc +
                ora #4                          ; quadrant with pip
+               ora #APP_CHAR_CRATE
                sta CellChars,x
                inx
                cpx #4
                bne -
.player         cpy PlayerPos                   ; player on this box?
                bne .cursor
                ldx #3
-               txa
                ora #APP_CHAR_PLAYER
                sta CellChars,x
                dex
                bpl -
.cursor         lda State                       ; cursor shown?
                cmp #ST_DIR
                bcs .done
                lda Blink
                beq .done
                cpy CursorPos
                bne .done
                lda #SOLID_CHAR
                sta CellChars
                sta CellChars+1
                sta CellChars+2
                sta CellChars+3
                lda #COL_CURSOR
                sta CellColor
.done           rts

!zone Data
;----------------------------------------------------------------------
; Data
;----------------------------------------------------------------------
; Game related variables
CurLevel        !byte 0
State           !byte 0
PlayerPos       !byte 0
CursorPos       !byte 0
SelPos          !byte 0
ClickPos        !byte 0
TmpRow          !byte 0
Blink           !byte 0
BlinkCnt        !byte 0
UndoCount       !byte 0
TipDir          !byte 0
TipH            !byte 0
TipRow          !byte 0
TipCol          !byte 0
TipCells        !fill 4,0
ScanPos         !byte 0
ScanDir         !byte 0
Changed         !byte 0
RecSize         !byte 0
; Variables of PaintCtrls (not shared with the window proc code)
PaintCell       !byte 0
PaintRow        !byte 0
PaintX          !byte 0
CellVal         !byte 0
CellColor       !byte 0
FloorColor      !byte 0
PipBits         !byte 0
CellChars       !fill 4,0
LineTop         !fill BOARD_W,0
LineBot         !fill BOARD_W,0
LineCol         !fill BOARD_W,0
Board           !fill BOARD_SIZE,0
Reach           !fill BOARD_SIZE,0
UndoBuf         !fill MAX_UNDO * UNDO_REC,0

; Tables
Mul6            !byte 0,6,12,18,24,30
RowOf           !byte 0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2
                !byte 3,3,3,3,3,3,4,4,4,4,4,4,5,5,5,5,5,5
ColOf           !byte 0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5
                !byte 0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5
DirDRow         !byte $ff,1,0,0                 ; N, S, W, E
DirDCol         !byte 0,0,$ff,1
HeightColor     !byte 0,COL_RED,COL_YELLOW,COL_GREEN,COL_BLUE
; Pips per height, bit 0..3 = quadrant TL, TR, BL, BR
PipMask         !byte %0000,%0001,%1001,%0111,%1111

Str_Title_App   !pet "Pathfinder",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_Pathfinder  !byte WT_PATHFINDER, %00100001, 12, 2, BOARD_W + 4, BOARD_Y + BOARD_W + 3
                !byte <Str_Title_App, >Str_Title_App
                !byte <PF_WndProc, >PF_WndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
; (content row 0 belongs to the window header, so the labels start in row 1)
                ;0
                !byte CT_MENUBAR, <PFMenubar, >PFMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL, 1, 1, STATUS_LEN, 1
                !pet "Level "
LevelDigits     !pet "01/"
                !pet NUM_LEVELS / 10 + $30, NUM_LEVELS % 10 + $30, 0
                ;2
                !byte CT_LABEL, 1, 2, STATUS_LEN, 1
StatusText      !pet "              ",0
                ;3
                !byte CT_PF_BOARD, BOARD_X, BOARD_Y, BOARD_W, BOARD_W
                !pet 0
                ; closing zero byte
                !byte 0

; Status texts (at most STATUS_LEN chars)
Msg_Select      !pet "Select tower",0
Msg_Dir         !pet "Tip direction?",0
Msg_NoTower     !pet "No tower here",0
Msg_Target      !pet "It's the goal",0
Msg_Far         !pet "Not reachable",0
Msg_CantTip     !pet "No room there",0
Msg_Stuck       !pet "Stuck! U or R",0
Msg_Solved      !pet "Path found!",0

; Message boxes
Str_Mess_Help   !pet "Tip over towers to\build a path to the\red box. A tower lies\on as many cells as\it is high.\CRSR: move cursor\RETURN: select tower\CRSR: tip direction\U: Undo  R: Restart",0
Str_Mess_About  !pet "Pathfinder\A tip-over puzzle\for GUI64",0
Str_Mess_Solved !pet "Path found!\Key or click:\Next level",0
Str_Mess_AllDone !pet "All levels\solved!",0

; Definition of menu bar
PFMenubar       !word Menu_PF_Game, Menu_PF_Help
Str_PFMenubar   !pet "Game",0,"?",0
; Definition of menus
; Format: ID, max_str_len, item_count, StringList
Menu_PF_Game    !pet ID_MENU_GAME,7,5,"Restart",0,"Undo",0,"Next",0,"Prev",0,"Quit",0
Menu_PF_Help    !pet ID_MENU_HELP,5,2,"Help",0,"About",0

; Chars
; Definition of new chars (8 bytes each). Set pixels get the cell color,
; cleared pixels show the dark background (like the GUI64 charset).
; A cell is 2x2 chars (16x16 pixels).
APP_CHAR_CRATE  = APP_CHAR_0    ; 4 quadrants of a standing box
                                ; (+4: with pip, must be APP_CHAR_0)
APP_CHAR_PLAYER = APP_CHAR_8    ; 4 quadrants (must be a multiple of 4)
APP_CHAR_LYING  = APP_CHAR_12
APP_CHAR_FLOOR  = APP_CHAR_13
APP_CHAR_BLANK  = APP_CHAR_14   ; (GUI64's space char is not empty)
CharList
                ; 0: crate TL
                !byte %00000000,%01111111,%01111111,%01111111
                !byte %01111111,%01111111,%01111111,%01111111
                ; 1: crate TR
                !byte %00000000,%11111110,%11111110,%11111110
                !byte %11111110,%11111110,%11111110,%11111110
                ; 2: crate BL
                !byte %01111111,%01111111,%01111111,%01111111
                !byte %01111111,%01111111,%01111111,%00000000
                ; 3: crate BR
                !byte %11111110,%11111110,%11111110,%11111110
                !byte %11111110,%11111110,%11111110,%00000000
                ; 4: crate with pip TL
                !byte %00000000,%01111111,%01111111,%01110111
                !byte %01100011,%01110111,%01111111,%01111111
                ; 5: crate with pip TR
                !byte %00000000,%11111110,%11111110,%11101110
                !byte %11000110,%11101110,%11111110,%11111110
                ; 6: crate with pip BL
                !byte %01111111,%01111111,%01110111,%01100011
                !byte %01110111,%01111111,%01111111,%00000000
                ; 7: crate with pip BR
                !byte %11111110,%11111110,%11101110,%11000110
                !byte %11101110,%11111110,%11111110,%00000000
                ; 8: player on a box TL
                !byte %00000000,%01111111,%01111110,%01111100
                !byte %01111110,%01110000,%01101000,%01111000
                ; 9: player on a box TR
                !byte %00000000,%11111110,%01111110,%00111110
                !byte %01111110,%00001110,%00010110,%00011110
                ; 10: player on a box BL
                !byte %01111100,%01111110,%01111101,%01111011
                !byte %01111011,%01110011,%01111111,%00000000
                ; 11: player on a box BR
                !byte %00111110,%01111110,%10111110,%11011110
                !byte %11011110,%11001110,%11111110,%00000000
                ; 12: lying tower (hatched)
                !byte %11001100,%01100110,%00110011,%10011001
                !byte %11001100,%01100110,%00110011,%10011001
                ; 13: floor dot (window color, the dot is the dark background)
                !byte %11111111,%11111111,%11111111,%11111111
                !byte %11111111,%11111111,%11111100,%11111100
                ; 14: blank (window color)
                !byte %11111111,%11111111,%11111111,%11111111
                !byte %11111111,%11111111,%11111111,%11111111
NUM_APP_CHARS   = 15

; Levels
;------------------------------------------
; Each level is a 6x6 matrix, one !text line per row (north first):
;   x = nothing, 1 = red box (target), 2 = yellow tower (height 2),
;   3 = green tower (height 3), 4 = blue tower (height 4)
; followed by the start tower of the player: column, row (0..5).
; A level may use at most 1 red, 10 yellow, 4 green and 2 blue towers.
; New levels can simply be added at the end (NUM_LEVELS is counted).
; Solutions are given as <column><row><direction>. All levels were
; checked by a solver: each has exactly one solution.
;------------------------------------------
Levels
; Beginner l1
       !text "xxx3xx"
	   !text "3xxxxx"
	   !text "xxxx2x"
	   !text "xxxxxx"
	   !text "x1xxxx"
	   !text "xxxxxx"
       !byte 4,2 ; start: column, row
; Beginner l2
       !text "4xxx3x"
	   !text "xx2xx2"
	   !text "xxxxxx"
	   !text "xxx1xx"
	   !text "xxxxxx"
	   !text "4xxxx3"
       !byte 0,0 ; start: column, row
; Beginner l3
       !text "x3xxx3"
	   !text "xxxx4x"
	   !text "xxxxxx"
	   !text "xxxxxx"
	   !text "x1xxxx"
	   !text "xxxxx4"
       !byte 4,1 ; start: column, row
; Beginner l4
       !text "33xx3x"
	   !text "xxxxxx"
	   !text "xxxxxx"
	   !text "xxxxx1"
	   !text "2xxxxx"
	   !text "4xxxx4"
       !byte 5,5 ; start: column, row
; Beginner l5
       !text "x2xxx4"
	   !text "xxx2xx"
	   !text "x3xxxx"
	   !text "xxx2xx"
	   !text "xxxx4x"
	   !text "xx3xx1"
       !byte 1,0 ; start: column, row
; Beginner l6
       !text "xxxxxx"
	   !text "xxx2xx"
	   !text "x3xxxx"
	   !text "xxxxxx"
	   !text "4xxxxx"
	   !text "xx24x1"
       !byte 3,1 ; start: column, row
; Beginner l7
       !text "xxx1xx"
	   !text "x2xxxx"
	   !text "xxxxxx"
	   !text "xx2xxx"
	   !text "3x22xx"
	   !text "xxx2xx"
       !byte 3,5 ; start: column, row
; Beginner l8
       !text "3xxxxx"
	   !text "x33xxx"
	   !text "xx3xx2"
	   !text "xxxxx2"
	   !text "4xxxxx"
	   !text "xxxxx1"
       !byte 0,0 ; start: column, row
; Beginner l9
       !text "xxxxxx"
	   !text "xxxxxx"
	   !text "xx2xxx"
	   !text "x324xx"
	   !text "3x4x1x"
	   !text "2xxxxx"
       !byte 2,2 ; start: column, row
; Beginner l10
       !text "xxxxxx"
	   !text "xxxx1x"
	   !text "x323xx"
	   !text "xxx2xx"
	   !text "xxx2xx"
	   !text "4xxxxx"
       !byte 0,5 ; start: column, row	   


LevelsEnd
NUM_LEVELS      = (LevelsEnd - Levels) / LEVEL_SIZE

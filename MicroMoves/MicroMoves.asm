!to "MicroMoves.d64",d64,"micromoves.gui","micromoves disk"

; Micro Moves - a small Sokoban clone for GUI64
; Port of the BASIC program micromoves.bas
;
; Push all boxes onto the targets.
; Controls: CRSR keys or W/A/S/D to move, R to restart the level,
;           or click on a board cell in the same row/column as the
;           player to take one step in that direction.

!source "gui64.inc.asm"

!zone Constants
; Constants
WT_MICROMOVES    = 51 ; app window types start at 50
CT_MM_BOARD      = 50 ; app control types start at 50
ID_MENU_GAME     = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

; The level grid is 16 x 9 cells (as in the BASIC version).
; Only the columns 1..14 are shown, the rest is never used by a level.
BOARD_COLS       = 16
BOARD_ROWS       = 9
BOARD_SIZE       = BOARD_COLS * BOARD_ROWS
VIEW_COL0        = 1  ; first visible grid column
VIEW_COLS        = 14 ; number of visible grid columns

; Bits of a board cell
CELL_WALL        = %00000001
CELL_TARGET      = %00000010
CELL_BOX         = %00000100
CELL_PLAYER      = %00001000
CELL_INSIDE      = %00010000 ; floor reachable by the player

; Directions (added to a board index)
DIR_UP           = $f0 ; -16
DIR_DOWN         = 16
DIR_LEFT         = $ff ; -1
DIR_RIGHT        = 1

; Cursor keys. GUI64 scans the keyboard with its own tables: the
; CRSR up/down key gives KEY_CRSR_UD, the CRSR left/right key gives
; KEY_CRSR_LR (with and without SHIFT, key_shifted tells up from down
; and left from right, like GUI64's list box does it).
KEY_CRSR_UD      = $fb
KEY_CRSR_LR      = $f8

; Colors of the board cells
COL_WALL         = CL_RED
COL_FLOOR        = CL_MIDGRAY
COL_TARGET       = CL_LIGHTGREEN
COL_BOX          = CL_ORANGE
COL_BOX_ON_TGT   = CL_DARKGREEN
COL_PLAYER       = CL_YELLOW
SOLID_CHAR       = 160

!zone Init
*=$b000
                lda #WT_MICROMOVES              ; look for window with type "WT_MICROMOVES"
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
                ldx #<Wnd_MicroMoves            ; Create the window with
                ldy #>Wnd_MicroMoves            ; its controls
                jsr GUI_CreateWindowEx          ;
                ;
                jsr GUI_GetDesign               ; Z=1: WIN, Z=0: MAC
                beq +                           ;
                dec WindowHeight                ; For MAC design, the menu bar
                jsr GUI_UpdateWindow            ; is not in the window
+               ; Menu
                jsr GUI_SelectControl0          ; Associate the menu bar
                ldx #<Str_MMMenubar             ; strings with control 0
                ldy #>Str_MMMenubar             ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                ;
                lda #0                          ; start with
                sta CurLevel                    ; the first level
                jmp RestartLevel

!zone WndProc
; Window Proc (event handler for window)
MM_WndProc      jsr GUI_StdWndProc              ; MUST always be called
                lda wndParam1                   ; ProgramMode
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
                cmp #CT_MM_BOARD                ; was it the board?
                bne .leave                      ;
                jmp BoardClicked                ;
.leave          rts

; Invoked when an item in the game menu was clicked
GameMenuClicked lda CurMenuItem                 ; 0: Restart
                beq RestartLevel                ;
                cmp #1                          ; 1: Next
                beq NextLevel                   ;
                cmp #2                          ; 2: Prev
                beq PrevLevel                   ;
                jsr GUI_KillCurWindow           ; 3: Quit
                jmp GUI_Repaint                 ;

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

; Keyboard: A = key in actkey
KeyPressed      lda Solved                      ; level solved:
                bne NextLevel                   ; any key starts the next one
                lda actkey
                cmp #KEY_CRSR_UD                ; CRSR down,
                bne +
                ldx #DIR_DOWN
                lda key_shifted                 ; with SHIFT: up
                beq .move
                ldx #DIR_UP
                bne .move                       ; jmp
+               cmp #KEY_CRSR_LR                ; CRSR right,
                bne +
                ldx #DIR_RIGHT
                lda key_shifted                 ; with SHIFT: left
                beq .move
                ldx #DIR_LEFT
                bne .move                       ; jmp
+
                and #%01111111                  ; ignore shift for letters
                ldx #DIR_UP
                cmp #"W"
                beq .move
                ldx #DIR_DOWN
                cmp #"S"
                beq .move
                ldx #DIR_LEFT
                cmp #"A"
                beq .move
                ldx #DIR_RIGHT
                cmp #"D"
                beq .move
                cmp #"R"
                beq RestartLevel
                rts
.move           txa
                jmp TryMove

; Mouse: one step towards the clicked cell, if it is
; in the same row or column as the player
BoardClicked    lda Solved                      ; level solved:
                bne NextLevel                   ; a click starts the next one
                jsr GUI_GetMousePosInWnd        ; mouse coords relative to window
                lda MousePosInWndY
                sec
                sbc ControlPosY
                cmp #BOARD_ROWS
                bcs .done
                asl                             ; row * 16
                asl
                asl
                asl
                sta ZP_5F
                lda MousePosInWndX
                sec
                sbc ControlPosX
                cmp #VIEW_COLS
                bcs .done
                clc
                adc #VIEW_COL0
                ora ZP_5F
                sta ZP_60                       ; index of clicked cell
                eor PlayerPos                   ; same row?
                and #$f0
                bne .column
                lda ZP_60
                cmp PlayerPos
                beq .done                       ; clicked on player
                lda #DIR_RIGHT
                bcs .go
                lda #DIR_LEFT
                bne .go                         ; jmp
.column         lda ZP_60                       ; same column?
                eor PlayerPos
                and #$0f
                bne .done
                lda ZP_60
                cmp PlayerPos
                lda #DIR_DOWN
                bcs .go
                lda #DIR_UP
.go             jmp TryMove
.done           rts

!zone Game
; Moves the player one step. A = direction
TryMove         sta Direction
                clc
                adc PlayerPos
                sta NewPos
                tax
                lda Board,x
                and #CELL_WALL
                bne .blocked                    ; wall
                lda Board,x
                and #CELL_BOX
                beq .walk                       ; free floor
                ; push box
                txa
                clc
                adc Direction
                tay                             ; Y = cell behind the box
                lda Board,y
                and #CELL_WALL + CELL_BOX
                bne .blocked                    ; box can't be moved
                lda Board,x
                eor #CELL_BOX
                sta Board,x
                lda Board,y
                ora #CELL_BOX
                sta Board,y
.walk           ldx PlayerPos
                lda Board,x
                eor #CELL_PLAYER
                sta Board,x
                ldx NewPos
                stx PlayerPos
                lda Board,x
                ora #CELL_PLAYER
                sta Board,x
                jsr IncMoves
                jsr CountPlaced
                lda Placed
                cmp NumBoxes
                beq .solved
                jmp GUI_RepaintCurWindow
.solved         lda #1
                sta Solved
                jsr GUI_RepaintCurWindow
                ldx #<Str_Mess_Solved
                ldy #>Str_Mess_Solved
                lda CurLevel
                cmp #NUM_LEVELS-1
                bne +
                ldx #<Str_Mess_AllDone
                ldy #>Str_Mess_AllDone
+               jmp GUI_ShowMessage
.blocked        rts

; Increments the moves counter (4 decimal digits, stops at 9999)
IncMoves        ldx #3
-               inc MovesDigits,x
                lda MovesDigits,x
                cmp #"9"+1
                bne .done
                lda #"0"
                sta MovesDigits,x
                dex
                bpl -
                ; overflow
                lda #"9"
                ldx #3
-               sta MovesDigits,x
                dex
                bpl -
.done           rts

; Counts the boxes on targets and updates the label
CountPlaced     ldx #BOARD_SIZE
                ldy #0
-               lda Board-1,x
                and #CELL_BOX + CELL_TARGET
                cmp #CELL_BOX + CELL_TARGET
                bne +
                iny
+               dex
                bne -
                sty Placed
                tya
                ora #$30
                sta Str_Boxes
                rts

!zone LoadLevel
; Builds the board of level CurLevel and resets the labels
LoadLevel       lda #0
                sta Solved
                ldx #BOARD_SIZE                 ; clear board
-               sta Board-1,x
                dex
                bne -
                ldx CurLevel
                lda LevelPtrLo,x
                sta ZP_FB
                lda LevelPtrHi,x
                sta ZP_FC
                ; Walls: 2 bytes per row, one bit per cell
                ; the i-th map byte covers board index i*8 .. i*8+7
                ldy #0
                lda (ZP_FB),y
                sta MapBytes
                iny
                ldx #0                          ; board index
.mapByte        lda (ZP_FB),y
                sta ZP_5F
                lda #8
                sta BitCount
-               asl ZP_5F
                bcc +
                lda #CELL_WALL
                sta Board,x
+               inx
                dec BitCount
                bne -
                iny
                dec MapBytes
                bne .mapByte
                ; Boxes and targets
                lda (ZP_FB),y
                sta NumBoxes
                sta BoxCount
                ora #$30
                sta Str_Boxes+2
                iny
.box            lda (ZP_FB),y
                jsr PosToIndex
                lda Board,x
                ora #CELL_BOX
                sta Board,x
                iny
                lda (ZP_FB),y
                jsr PosToIndex
                lda Board,x
                ora #CELL_TARGET
                sta Board,x
                iny
                dec BoxCount
                bne .box
                ; Player
                lda (ZP_FB),y
                jsr PosToIndex
                stx PlayerPos
                lda Board,x
                ora #CELL_PLAYER
                sta Board,x
                jsr FloodFill
                ; Reset moves
                lda #"0"
                ldx #3
-               sta MovesDigits,x
                dex
                bpl -
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
                jmp CountPlaced

; Converts a level position (hi nibble = column, lo nibble = row)
; in A to a board index (row * 16 + column) in X. Y is preserved.
PosToIndex      pha
                asl
                asl
                asl
                asl
                sta ZP_60
                pla
                lsr
                lsr
                lsr
                lsr
                ora ZP_60
                tax
                rts

; Marks all cells reachable by the player as CELL_INSIDE,
; so the floor outside the walls is not painted
FloodFill       lda PlayerPos
                sta FillQueue
                jsr .mark
                lda #0
                sta FillHead
                lda #1
                sta FillTail
.next           ldx FillHead
                cpx FillTail
                beq .done
                lda FillQueue,x
                sta FillPos
                inc FillHead
                ; up
                lda FillPos
                cmp #BOARD_COLS
                bcc +
                sbc #BOARD_COLS                 ; C is set
                jsr .visit
+               ; down
                lda FillPos
                cmp #BOARD_SIZE - BOARD_COLS
                bcs +
                adc #BOARD_COLS                 ; C is clear
                jsr .visit
+               ; left
                lda FillPos
                and #$0f
                beq +
                ldx FillPos
                dex
                txa
                jsr .visit
+               ; right
                lda FillPos
                and #$0f
                cmp #$0f
                beq +
                ldx FillPos
                inx
                txa
                jsr .visit
+               jmp .next
.done           rts
; A = board index. Adds the cell to the queue if it is new floor.
.visit          tax
                lda Board,x
                and #CELL_WALL + CELL_INSIDE
                bne +
                ldy FillTail
                txa
                sta FillQueue,y
                inc FillTail
.mark           tax
                lda Board,x
                ora #CELL_INSIDE
                sta Board,x
+               rts

!zone Control_Action_Paint
; X is ControlType
CtrlAction      rts                             ; Must be provided if new controls are registered

; X is ControlType
PaintCtrls      cpx #CT_MM_BOARD
                beq PaintBoard
                rts

; FDFE points to position of control in paint buffer
; 0203 points to position of control in color buffer
PaintBoard      lda #<(Board + VIEW_COL0)
                sta ZP_FB
                lda #>(Board + VIEW_COL0)
                sta ZP_FC
                ldx #BOARD_ROWS
--              ldy #VIEW_COLS - 1
-               lda (ZP_FB),y
                beq +                           ; outside: keep window background
                jsr CellLook
                sta (ZP_FD),y
                lda CellColor
                sta ($02),y
+               dey
                bpl -
                jsr GUI_AddBufWidthToFD         ; one char down in paint buffer
                jsr GUI_AddBufWidthTo02         ; one char down in color buffer
                lda ZP_FB
                clc
                adc #BOARD_COLS
                sta ZP_FB
                bcc +
                inc ZP_FC
+               dex
                bne --
                rts

; A = cell bits (not zero)
; Returns char in A and color in CellColor. X and Y are preserved.
CellLook        sta CellFlags
                and #CELL_WALL
                beq .noWall
                lda #COL_WALL
                sta CellColor
                lda #APP_CHAR_WALL
                rts
.noWall         lda CellFlags
                and #CELL_BOX
                beq .noBox
                lda #COL_BOX
                sta CellColor
                lda #COL_BOX_ON_TGT
                jsr .onTarget
                lda #APP_CHAR_BOX
                rts
.noBox          lda CellFlags
                and #CELL_PLAYER
                beq .noPlayer
                lda #COL_PLAYER
                sta CellColor
                lda #COL_TARGET
                jsr .onTarget
                lda #APP_CHAR_PLAYER
                rts
.noPlayer       lda CellFlags
                and #CELL_TARGET
                beq .floor
                lda #COL_TARGET
                sta CellColor
                lda #APP_CHAR_TARGET
                rts
.floor          lda #COL_FLOOR
                sta CellColor
                lda #SOLID_CHAR
                rts
; A = color to use if the cell is a target
.onTarget       pha
                lda CellFlags
                and #CELL_TARGET
                beq +
                pla
                sta CellColor
                rts
+               pla
                rts

!zone Data
;----------------------------------------------------------------------
; Data
;----------------------------------------------------------------------
; Game related variables
CurLevel        !byte 0
PlayerPos       !byte 0
NewPos          !byte 0
Direction       !byte 0
NumBoxes        !byte 0
BoxCount        !byte 0
Placed          !byte 0
Solved          !byte 0
MapBytes        !byte 0
BitCount        !byte 0
CellFlags       !byte 0
CellColor       !byte 0
FillHead        !byte 0
FillTail        !byte 0
FillPos         !byte 0
Board           !fill BOARD_SIZE,0
FillQueue       !fill BOARD_SIZE,0

Str_Title_App   !pet "Micro Moves",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_MicroMoves  !byte WT_MICROMOVES, %00100001, 12, 3, 16, 16, <Str_Title_App, >Str_Title_App
                !byte <MM_WndProc, >MM_WndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
; (content row 0 belongs to the window header, so the labels start in row 1)
                ;0
                !byte CT_MENUBAR, <MMMenubar, >MMMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL, 1, 1, 14, 1
                !pet "Level "
LevelDigits     !pet "01"
                !pet "/23",0                    ; = NUM_LEVELS
                ;2
                !byte CT_LABEL, 1, 2, 10, 1
                !pet "Moves "
MovesDigits     !pet "0000",0
                ;3
                !byte CT_LABEL, 12, 2, 3, 1
Str_Boxes       !pet "0/0",0                    ; boxes on targets / boxes
                ;4
                !byte CT_MM_BOARD, 1, 4, VIEW_COLS, BOARD_ROWS
                !pet 0
                ; closing zero byte
                !byte 0

; Strings
Str_Mess_Help   !pet "Push all boxes onto\the targets.\Keys: CRSR/WASD\R: Restart level\Click: one step",0
Str_Mess_About  !pet "Micro Moves\A Sokoban clone\for GUI64",0
Str_Mess_Solved !pet "Level solved!\Key or click:\Next level",0
Str_Mess_AllDone !pet "All levels\solved!",0

; Definition of menu bar
MMMenubar       !word Menu_MM_Game, Menu_MM_Help
Str_MMMenubar   !pet "Game",0,"?",0
; Definition of menus
; Format: ID, max_str_len, item_count, StringList
Menu_MM_Game    !pet ID_MENU_GAME,7,4,"Restart",0,"Next",0,"Prev",0,"Quit",0
Menu_MM_Help    !pet ID_MENU_HELP,5,2,"Help",0,"About",0

; Chars
; Definition of new chars (8 bytes each). Set pixels get the cell color,
; cleared pixels show the dark background (like the GUI64 charset).
NUM_APP_CHARS   = 4
CharList        ; 0: Wall (bricks)
                APP_CHAR_WALL = APP_CHAR_0
                !byte %11101111,%11101111,%11101111,%00000000
                !byte %11111110,%11111110,%11111110,%00000000
                ; 1: Target
                APP_CHAR_TARGET = APP_CHAR_1
                !byte %11111111,%11100111,%11011011,%10111101
                !byte %10111101,%11011011,%11100111,%11111111
                ; 2: Box
                APP_CHAR_BOX = APP_CHAR_2
                !byte %00000000,%01111110,%01011010,%01100110
                !byte %01100110,%01011010,%01111110,%00000000
                ; 3: Player
                APP_CHAR_PLAYER = APP_CHAR_3
                !byte %11100111,%11100111,%10000001,%11100111
                !byte %11100111,%11011011,%11011011,%11111111

; Levels
;------------------------------------------
; File MicroMoves_levels.asm
; Level data of Micro Moves, taken 1:1 from
; the DATA lines of micromoves.bas
;
; Level format:
;   L            number of map bytes (2 per row)
;   L bytes      wall bitmap, 16 columns per row,
;                bit 7 of 1st byte = column 0
;   n            number of boxes
;   n * (b,t)    box position, target position
;   p            player position
; Positions: hi nibble = column, lo nibble = row
;------------------------------------------

; Level 1
;          #####
;       ####   #
;       #    # #
;       # $*.  #
;       #  *@###
;       ##$*.#
;        #   #
;        #####
Level00         !byte 16
                !byte $01,$f0,$0f,$10,$08,$50,$08,$10
                !byte $08,$70,$0c,$40,$04,$40,$07,$c0
                !byte 5
                !byte $73,$83,$63,$73,$74,$74,$75,$85
                !byte $65,$75
                !byte $84

; Level 2
;        ######
;        #  * ##
;       ## .$.@#
;       # *$ $*#
;       #  .$. #
;       #   *  #
;       ########
Level01         !byte 14
                !byte $07,$e0,$04,$30,$0c,$10,$08,$10
                !byte $08,$10,$08,$10,$0f,$f0
                !byte 8
                !byte $81,$81,$82,$72,$63,$92,$a3,$63
                !byte $73,$a3,$93,$74,$84,$94,$85,$85
                !byte $a2

; Level 3
;        ####
;        #  ###
;      ###@$  ##
;      #  .*.  #
;      # # $*$ #
;      #    .###
;      #######
Level02         !byte 14
                !byte $07,$80,$04,$e0,$1c,$30,$10,$10
                !byte $14,$10,$10,$70,$1f,$c0
                !byte 5
                !byte $72,$63,$73,$83,$84,$73,$74,$84
                !byte $94,$85
                !byte $62

; Level 4
;        #####
;      ###   ###
;      # $**.  #
;      #@$  .# #
;      # $ #.  #
;      ###   ###
;        #####
Level03         !byte 14
                !byte $07,$c0,$1c,$70,$10,$10,$10,$50
                !byte $11,$10,$1c,$70,$07,$c0
                !byte 5
                !byte $62,$82,$72,$62,$52,$72,$53,$83
                !byte $54,$84
                !byte $43

; Level 5
;         ######
;        ## .  #
;      ###  *  #
;      # $**$  #
;      #@*  # ##
;      ##.#   #
;       #   ###
;       #####
Level04         !byte 16
                !byte $03,$f0,$06,$10,$1c,$10,$10,$10
                !byte $10,$b0,$1a,$20,$08,$e0,$0f,$80
                !byte 6
                !byte $82,$81,$63,$82,$73,$63,$53,$73
                !byte $83,$54,$54,$55
                !byte $44

; Level 6
;       ########
;       #   #@ #
;       # .$.$ #
;       # .$.$ #
;       ##.$.$ #
;        #  ####
;        #  #
;        ####
Level05         !byte 16
                !byte $0f,$f0,$08,$90,$08,$10,$08,$10
                !byte $0c,$10,$04,$f0,$04,$80,$07,$80
                !byte 6
                !byte $72,$62,$92,$82,$73,$63,$93,$83
                !byte $74,$64,$94,$84
                !byte $91

; Level 7
;       #####
;       #   ####
;       #      #
;       #.*$*  #
;       # @#  ##
;       #.*$* #
;       #  #  #
;       #######
Level06         !byte 16
                !byte $0f,$80,$08,$f0,$08,$10,$08,$10
                !byte $09,$30,$08,$20,$09,$20,$0f,$e0
                !byte 6
                !byte $63,$53,$83,$63,$73,$83,$65,$55
                !byte $85,$65,$75,$85
                !byte $64

; Level 8
;        #####
;       ## .@#
;       # .*$###
;       #.*$   #
;       #*$  # #
;       #  ### #
;       #      #
;       #  #####
;       ####
Level07         !byte 18
                !byte $07,$c0,$0c,$40,$08,$70,$08,$10
                !byte $08,$50,$09,$d0,$08,$10,$09,$f0
                !byte $0f,$00
                !byte 6
                !byte $72,$71,$82,$62,$63,$72,$73,$53
                !byte $54,$63,$64,$54
                !byte $81

; Level 9
;       #####
;       #   ###
;       #     #
;       ##**$ ##
;       #  .*  #
;       # # ** #
;       #  @  ##
;       #######
Level08         !byte 16
                !byte $0f,$80,$08,$e0,$08,$20,$0c,$30
                !byte $08,$10,$0a,$10,$08,$30,$0f,$e0
                !byte 6
                !byte $63,$63,$73,$73,$83,$74,$84,$84
                !byte $85,$85,$95,$95
                !byte $76

; Level 10
;        #######
;        #  *  #
;        # *.* #
;        #  *  #
;       ## *  ##
;       # *$*  #
;       # @*   #
;       ###  ###
;         ####
Level09         !byte 18
                !byte $07,$f0,$04,$10,$04,$10,$04,$10
                !byte $0c,$30,$08,$10,$08,$10,$0e,$70
                !byte $03,$c0
                !byte 9
                !byte $81,$81,$72,$82,$92,$72,$83,$92
                !byte $74,$83,$65,$74,$85,$65,$75,$85
                !byte $76,$76
                !byte $66

; Level 11
;       ######
;       #    ###
;       #  #.  #
;       #  $*$ #
;       # .*.# #
;       ###$ @ #
;         #  ###
;         ####
Level10         !byte 16
                !byte $0f,$c0,$08,$70,$09,$10,$08,$10
                !byte $08,$50,$0e,$10,$02,$70,$03,$c0
                !byte 5
                !byte $83,$82,$73,$83,$93,$64,$74,$84
                !byte $75,$74
                !byte $95

; Level 12
;          ####
;       ####  ##
;       #  ... #
;       # $.$. #
;       ##$$$ ##
;        # @  #
;        ######
Level11         !byte 14
                !byte $01,$e0,$0f,$30,$08,$10,$08,$10
                !byte $0c,$30,$04,$20,$07,$e0
                !byte 5
                !byte $63,$72,$83,$82,$64,$92,$74,$73
                !byte $84,$93
                !byte $75

; Level 13
;         #####
;       ###   ##
;      ##  .#  #
;      #  #* # #
;      # $*@*$ #
;      #  #*   #
;      ##  .   #
;       ########
Level12         !byte 16
                !byte $03,$e0,$0e,$30,$18,$90,$12,$50
                !byte $10,$10,$12,$10,$18,$10,$0f,$f0
                !byte 6
                !byte $73,$72,$64,$73,$84,$64,$54,$84
                !byte $94,$75,$75,$76
                !byte $74

; Level 14
;      #####
;      #   #####
;      # #  *  #
;      # # .*@ #
;      # #**$ ##
;      #    ###
;      ###  #
;        #  #
;        ####
Level13         !byte 18
                !byte $1f,$00,$11,$f0,$14,$10,$14,$10
                !byte $14,$30,$10,$e0,$1c,$80,$04,$80
                !byte $07,$80
                !byte 5
                !byte $82,$82,$83,$73,$64,$83,$74,$64
                !byte $84,$74
                !byte $93

; Level 15
;        ####
;        #  ####
;      ###     #
;      #    ## #
;      # #.. # #
;      # ##* # #
;      #   *$$ #
;      #### @###
;         ####
Level14         !byte 18
                !byte $07,$80,$04,$f0,$1c,$10,$10,$d0
                !byte $14,$50,$16,$50,$10,$10,$1e,$70
                !byte $03,$c0
                !byte 4
                !byte $75,$64,$76,$74,$86,$75,$96,$76
                !byte $87

; Level 16
;       #####
;      ##   ###
;      #      ##
;      # # ##  #
;      #..*  # #
;      #  *  # #
;      ###*$$  #
;        #@ ####
;        ####
Level15         !byte 18
                !byte $0f,$80,$18,$e0,$10,$30,$15,$90
                !byte $10,$50,$10,$50,$1c,$10,$04,$f0
                !byte $07,$80
                !byte 5
                !byte $64,$44,$65,$54,$66,$64,$76,$65
                !byte $86,$66
                !byte $67

; Level 17
;        ####
;        #  #
;        #  ###
;       ##.   #
;       #. *# #
;       # *@$ #
;       ## $ ##
;        ##  #
;         ####
Level16         !byte 18
                !byte $07,$80,$04,$80,$04,$e0,$0c,$20
                !byte $08,$a0,$08,$20,$0c,$60,$06,$40
                !byte $03,$c0
                !byte 4
                !byte $74,$63,$65,$54,$85,$74,$76,$65
                !byte $75

; Level 18
;         ####
;      ####  #
;      #  #$ ###
;      #   $   #
;      #  .*.. #
;      ## *$ ###
;       ## @##
;        ####
Level17         !byte 16
                !byte $03,$c0,$1e,$40,$12,$70,$10,$10
                !byte $10,$10,$18,$70,$0c,$c0,$07,$80
                !byte 5
                !byte $72,$64,$73,$84,$74,$94,$65,$74
                !byte $75,$65
                !byte $76

; Level 19
;          #####
;       ####   #
;       #      #
;       # # # ##
;      ##.$ $.#
;      # .$#$.#
;      # @ #  #
;      #  #####
;      ####
Level18         !byte 18
                !byte $01,$f0,$0f,$10,$08,$10,$0a,$b0
                !byte $18,$20,$11,$20,$11,$20,$13,$e0
                !byte $1e,$00
                !byte 4
                !byte $64,$54,$84,$94,$65,$55,$85,$95
                !byte $56

; Level 20
;       ####
;       #  ####
;       #  $. #
;       #  $. #
;       #  $. #
;       ###$.##
;         #@ #
;         ####
Level19         !byte 16
                !byte $0f,$00,$09,$e0,$08,$20,$08,$20
                !byte $08,$20,$0e,$60,$02,$40,$03,$c0
                !byte 4
                !byte $72,$82,$73,$83,$74,$84,$75,$85
                !byte $76

; Level 21
;         ####
;         #  ###
;       ###    #
;       #  *.# #
;       #  $*  #
;       ### @###
;         #  #
;         ####
Level20         !byte 16
                !byte $03,$c0,$02,$70,$0e,$10,$08,$50
                !byte $08,$10,$0e,$70,$02,$40,$03,$c0
                !byte 3
                !byte $73,$83,$84,$73,$74,$84
                !byte $85

; Level 22
;        #####
;        # @ #
;      ###$ $###
;      #  $ $  #
;      # #* *# #
;      #  .#.  #
;      ## . . ##
;       ##   ##
;        #####
Level21         !byte 18
                !byte $07,$c0,$04,$40,$1c,$70,$10,$10
                !byte $14,$50,$11,$10,$18,$30,$0c,$60
                !byte $07,$c0
                !byte 6
                !byte $62,$64,$82,$84,$63,$65,$83,$85
                !byte $64,$66,$84,$86
                !byte $71

; Level 23
;        ########
;       ##  .  .##
;      ## . # $$ #
;      #     #. ##
;      ###  $$ $@#
;        ##   . ##
;         #######
Level22         !byte 14
                !byte $07,$f8,$0c,$0c,$18,$84,$10,$4c
                !byte $1c,$04,$06,$0c,$03,$f8
                !byte 5
                !byte $84,$a5,$94,$b1,$a2,$81,$b2,$a3
                !byte $b4,$62
                !byte $c4

NUM_LEVELS      = 23

LevelPtrLo      !byte <Level00,<Level01,<Level02,<Level03,<Level04,<Level05,<Level06,<Level07
                !byte <Level08,<Level09,<Level10,<Level11,<Level12,<Level13,<Level14,<Level15
                !byte <Level16,<Level17,<Level18,<Level19,<Level20,<Level21,<Level22
LevelPtrHi      !byte >Level00,>Level01,>Level02,>Level03,>Level04,>Level05,>Level06,>Level07
                !byte >Level08,>Level09,>Level10,>Level11,>Level12,>Level13,>Level14,>Level15
                !byte >Level16,>Level17,>Level18,>Level19,>Level20,>Level21,>Level22

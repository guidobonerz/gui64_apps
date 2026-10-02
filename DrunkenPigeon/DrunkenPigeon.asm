!to "DrunkenPigeon.d64",d64,"drunkpigeon.gui","pigeon disk"

; Drunken Pigeon - a Flappy Bird clone for GUI64 (MAC and WIN design)
;
; Pipes with gaps at random heights scroll from right to left. Press
; SPACE (or click into the playfield) to flap and fly the pigeon through
; the gaps. The pigeon had a drink too many: it sways, it never flaps
; with the same strength twice, and now and then it gets the hiccups.
; Every pipe passed is a point.
;
; How it works:
; * Every cell of the line holds 0 (no pipe) or the top row of the gap
;   of the pipe (1..MAX_GAP_TOP). A pipe is PIPE_W cells wide. The pipes
;   are drawn with 4 app chars: sky, pipe, and two edge chars
;   (pipe->sky, sky->pipe), which are redefined every frame for the fine
;   scroll position (0..7 pixels). Every 8 pixels, the cells are shifted
;   left by one char. The char of a screen column only depends on the
;   cell there and the next cell, so only the columns whose cells changed
;   are drawn again. A 5th app char is the scrolling ground.
; * The pigeon is sprite 6 (free in both designs: GUI64 uses 0-1 for the
;   mouse and, in the WIN design, 2-5 for the taskbar logo).
; * Like in RunBoyRun, the game runs in an "engine", which is GUI64's
;   frame handler (GUI_SetFrameHandler, called from GUI64's raster IRQ,
;   50 frames per second). The engine is copied to $c000 (app area in
;   GUI64's VIC bank, so the sprite data can be there, too) and draws
;   into the screen while the window is the current window. GUI64's
;   repaints use the same data (custom control and labels). Only one app
;   runs at a time, so the engine may use the same RAM as the engines of
;   the other apps. On EC_SHUTDOWN, the frame handling is stopped.
; * The app only uses the GUI64 API (gui64.inc.asm). The position of the
;   window comes from the current-window structure ($10-$1f): the GUI64
;   timer (GUI64 main loop) saves it in WinX/WinY, and the engine only
;   runs while the structure still shows the app window at this position
;   (in the IRQ, GUI64 may just be copying another window into it).

!source "gui64.inc.asm"

!zone Constants
WT_PIGEON        = 54 ; app window types start at 50
CT_PLAYFIELD     = 50 ; app control types start at 50
ID_MENU_GAME     = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

ENGINE_BASE      = $c000 ; engine is copied here

SPRITE_NO        = 6     ; apps for both designs may use sprites 6 and 7
SPRITE_BIT       = 1 << SPRITE_NO
PIGEON_COLOR     = CL_DARKGRAY

; Layout (content coordinates of the window)
PF_X             = 1  ; playfield control
PF_Y             = 2
PF_W             = 30
PF_H             = 13
PIPE_ROWS        = PF_H - 1 ; rows of the pipes, the last row is the ground
NUM_CELLS        = PF_W + 1 ; one more cell for the right edge
; Content row 0 is the second row of the window header, so the
; controls start in row 1
SCORE_Y          = 1  ; row of score and best
SCORE_X          = 1
BEST_X           = 20

; Pipes
PIPE_W           = 2  ; cells
SPACING          = 7  ; cells between two pipes
FIRST_SKY        = 4  ; cells before the first pipe (after the right edge)
GAP_ROWS         = 4
MAX_GAP_TOP      = PIPE_ROWS - GAP_ROWS - 1 ; at least one pipe row below
MAX_GAP_STEP     = 3  ; rows the gap moves at most from pipe to pipe

; Game over message: a box of MSG_H rows of MSG_W chars in the middle
; of the playfield (see MsgText)
MSG_W            = 22
MSG_H            = 4
MSG_X            = (PF_W - MSG_W) / 2 ; playfield column
MSG_Y            = (PIPE_ROWS - MSG_H) / 2 ; playfield row

; App chars. Set pixels have the window color (sky), the pipes are
; drawn with cleared (black) pixels. The order matters:
; char = CH_SKY + 2 * (pipe here) + (pipe in the next cell), and
; CH_SKY must be a multiple of 4 (see Mask).
CH_SKY           = APP_CHAR_0
CH_GS            = APP_CHAR_1 ; sky -> pipe
CH_SG            = APP_CHAR_2 ; pipe -> sky
CH_PIPE          = APP_CHAR_3
CH_GROUND        = APP_CHAR_4

; The pigeon (sprite: 24x21 pixels from bird.bin, see SpriteData)
PIG_COL          = 6  ; playfield column of the sprite
PIG_X            = PIG_COL * 8 ; in playfield pixels
HB_L             = 4  ; hit box in the sprite (the body, without
HB_R             = 20 ; the tips of tail, beak and wings)
HB_T             = 9
HB_B             = 13
DEAD_DY          = 4  ; the dead frame is drawn higher (its body is
                      ; at the rows 14..17)
GROUND_Y         = PIPE_ROWS * 8 ; top of the ground in playfield pixels
PIG_GROUND       = GROUND_Y - HB_B - 1 ; sprite y of the pigeon on the ground
START_Y          = 36
SWAY_MID         = 2  ; the pigeon sways 2 pixels left and right

; Parts of the window the engine has to redraw
DIRTY_PIPES      = 1
DIRTY_SCORE      = 2
DIRTY_BEST       = 4
DIRTY_ALL        = DIRTY_PIPES | DIRTY_SCORE | DIRTY_BEST

; Game states
ST_READY         = 0
ST_PLAY          = 1
ST_DEAD          = 2 ; hit a pipe, falls down
ST_OVER          = 3

; Speed in 1/16 pixels per frame
SPEED_START      = 16
SPEED_MAX        = 24
SPEED_STEP       = 2  ; faster every 8 points

; Physics: velocities in 1/16 pixels per frame (down is positive),
; gravity in 1/16 pixels per frame^2
GRAVITY          = 4
VEL_MAX          = 64
FLAP_VEL         = 40 ; a flap: -(FLAP_VEL + 0..FLAP_VAR)
FLAP_VAR         = 15
HICCUP           = 24 ; a hiccup lifts the pigeon a bit
HIC_CHANCE       = 1  ; per frame, out of 256
HIC_TIME         = 40 ; frames "*hic*" is shown
OVER_WAIT        = 25 ; frames until a new game can be started

!zone Init
*=$b000
                lda #WT_PIGEON                  ; look for window with type "WT_PIGEON"
                sta Param0                      ;
                jsr GUI_FindWndByType           ;
                bcc +                           ; if not found, start app
                stx Param0                      ; otherwise, make this window
                jmp GUI_SelectTopWindow         ; the top window and leave
                ; Start app
+               ; Copy engine to $c000
                lda #<EngineImage
                sta ZP_FB
                lda #>EngineImage
                sta ZP_FC
                lda #<ENGINE_BASE
                sta ZP_FD
                lda #>ENGINE_BASE
                sta ZP_FE
                ldx #ENGINE_PAGES
                ldy #0
-               lda (ZP_FB),y
                sta (ZP_FD),y
                iny
                bne -
                inc ZP_FC
                inc ZP_FE
                dex
                bne -
                ;
                ldx #<CharList                  ; Register the
                ldy #>CharList                  ; chars of the
                lda #5                         ; pipes and the ground
                jsr GUI_RegisterChars           ;
                ldx #<CtrlAction                ; Behavior of the playfield
                ldy #>CtrlAction                ; (void, events are handled
                jsr GUI_SetCtrlActionsRoutine   ; in the window proc)
                ldx #<PaintCtrls                ; Look of the
                ldy #>PaintCtrls                ; playfield
                jsr GUI_SetPaintCtrlsRoutine    ;
                ;
                ldx #<Wnd_Pigeon                ; Create the window with
                ldy #>Wnd_Pigeon                ; its controls
                jsr GUI_CreateWindowEx          ;
                lda #1                          ; WIN: content row 0 is below the
                sta RowOffset                   ; menu bar of the window
                jsr GUI_GetDesign               ; Z=1: WIN, Z=0: MAC
                beq +                           ; MAC: the window y is one row
                inc WindowPosY                  ; above the screen row, the menu bar
                dec WindowHeight                ; is at the top of the screen
                jsr GUI_UpdateWindow            ; confirm window changes
+               ; Menu
                jsr GUI_SelectControl0          ; Associate the menu bar
                ldx #<Str_PigMenubar            ; strings with control 0
                ldy #>Str_PigMenubar            ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                ; Labels show the text buffers of the engine
                jsr GUI_SelectControl1
                ldx #<ScoreText
                ldy #>ScoreText
                jsr GUI_SetCtrlString
                jsr GUI_SelectControl2
                ldx #<BestText
                ldy #>BestText
                jsr GUI_SetCtrlString
                jsr TrackWindow                 ; window position for the engine
                ldx #<TrackWindow               ; and keep it up to date
                ldy #>TrackWindow               ; (every 1/10 second)
                jsr GUI_InitTimer
                jsr GUI_StartTimer
                jmp EngineStart

; Timer handler (GUI64 main loop, not IRQ): if the app window is the
; current window, its position is saved for the engine
TrackWindow     lda WindowType
                cmp #WT_PIGEON
                bne +
                lda WindowPosX
                sta WinX
                lda WindowPosY
                sta WinY
+               rts

; Window Proc (event handler for window)
PigeonWndProc   jsr GUI_StdWndProc              ; MUST always be called
                lda wndParam0                   ; app shuts down (window closed)?
                cmp #EC_SHUTDOWN
                bne +
                jsr GUI_StopTimer               ; then stop the timer
                jmp StopEngine                  ; and the frame handler
+               jsr TrackWindow                 ; (the window is current here)
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
                beq GameMenuClicked             ;
                jmp HelpMenuClicked             ;
.normal         lda wndParam0                   ; event code
                cmp #EC_KEYPRESS
                bne +
                lda actkey
                cmp #" "                        ; SPACE?
                beq .flap
                rts
+               cmp #EC_DBLCLICK                ; (a quick second click)
                beq +
                cmp #EC_LBTNPRESS               ; click into the playfield?
                bne .leave
+               jsr GUI_IsInCurControl
                bcc .leave
                lda ControlType
                cmp #CT_PLAYFIELD
                bne .leave
.flap           lda #1                          ; the engine does the rest
                sta FlapReq
.leave          rts

; Invoked when an item in the game menu was clicked
GameMenuClicked lda CurMenuItem                 ; 0: New
                bne +
                php                             ; back to the start screen
                sei                             ; (the engine must not run
                jsr ResetGame                   ; in between)
                plp
                rts
+               jsr GUI_KillCurWindow           ; 1: Quit (sends EC_SHUTDOWN,
                jmp GUI_Repaint                 ; which stops the engine)

; Invoked when an item in the help menu was clicked
HelpMenuClicked lda CurMenuItem
                bne +
                ldx #<Str_Mess_Help             ; 0: Help
                ldy #>Str_Mess_Help
                jmp GUI_ShowMessage
+               ldx #<Str_Mess_About            ; 1: About
                ldy #>Str_Mess_About
                jmp GUI_ShowMessage

; Starts the game and the engine (GUI64's frame handler)
EngineStart     lda $dc04                       ; seed random generator
                ora #1                          ; (must not be 0)
                sta Seed
                lda $dc05
                sta Seed+1
                jsr GUI_GetScreenMem            ; high byte of the screen
                sta ScreenHi                    ; (MAC: $e0, WIN: $e4)
                jsr ResetGame
                ldx #<FrameHandler              ; GameFrame runs once
                ldy #>FrameHandler              ; per frame from now on
                jsr GUI_SetFrameHandler
                jmp GUI_StartFrameHandling

; X is ControlType
CtrlAction      rts                             ; Must be provided if new controls are registered

; X is ControlType
; FDFE points to position of control in paint buffer
; 0203 points to position of control in color buffer
PaintCtrls      cpx #CT_PLAYFIELD
                beq +
                rts
+               jsr GUI_GetCSTMWindowColor      ; (not in the zero page, the
                sta PaintColor                  ; GUI64 routines below use it)
                lda #0
                sta PaintRow
.row            ldy #PF_W-1
-               jsr CellChar
                sta (ZP_FD),y
                lda PaintColor
                sta ($02),y
                dey
                bpl -
                lda PaintRow
                cmp #PF_H-1
                beq +
                inc PaintRow
                jsr GUI_AddBufWidthToFD
                jsr GUI_AddBufWidthTo02
                jmp .row
+               rts

; Y = playfield column, PaintRow = row -> A = char there. Y is
; preserved. Must not use any variables of the engine, as the engine's
; IRQ can interrupt GUI64's repaint. (The engine's DrawPipes does the
; same with the table Mask.)
CellChar        lda State                       ; game over: the message
                cmp #ST_OVER                    ; is in front of the pipes
                bne .pipes
                lda PaintRow
                sec
                sbc #MSG_Y
                cmp #MSG_H
                bcs .pipes
                tax
                tya
                sec
                sbc #MSG_X
                cmp #MSG_W
                bcs .pipes
                adc MsgRowOfs,x                 ; (C=0)
                tax
                lda MsgText,x
                jmp PetToScr
.pipes          lda PaintRow
                cmp #PIPE_ROWS
                bne +
                lda #CH_GROUND
                rts
+               lda Cells,y                     ; top row of the gap (of the pipe
                ora Cells+1,y                   ; in this or the next cell)
                sta PaintTmp
                lda PaintRow
                sec
                sbc PaintTmp
                cmp #GAP_ROWS                   ; in the gap?
                bcc .sky
                lda Cells,y
                cmp #1                          ; C=1: pipe in this cell
                lda #0
                rol
                asl
                sta PaintTmp
                lda Cells+1,y
                cmp #1                          ; C=1: pipe in the next cell
                lda #CH_SKY
                adc PaintTmp                    ; CH_SKY + 2 * this + next
                rts
.sky            lda #CH_SKY
                rts

!zone Data
PaintColor      !byte 0
PaintRow        !byte 0
PaintTmp        !byte 0
Str_Title_App   !pet "Drunken Pigeon",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_Pigeon      !byte WT_PIGEON, %00100001, 4, 3, 32, 18, <Str_Title_App, >Str_Title_App
                !byte <PigeonWndProc, >PigeonWndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
                ;0
                !byte CT_MENUBAR, <PigMenubar, >PigMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL, SCORE_X, SCORE_Y, 10, 1
                !pet 0
                ;2
                !byte CT_LABEL, BEST_X, SCORE_Y, 9, 1
                !pet 0
                ;3
                !byte CT_PLAYFIELD, PF_X, PF_Y, PF_W, PF_H
                !pet 0
                ; closing zero byte
                !byte 0

; Strings
Str_Mess_Help   !pet "SPACE or click: flap\Fly through the gaps\Mind the hiccups!",0
Str_Mess_About  !pet "Drunken Pigeon\A Flappy Bird clone\for GUI64",0

; Definition of menu bar
PigMenubar      !word Menu_Pig_Game, Menu_Pig_Help
Str_PigMenubar  !pet "Game",0,"?",0
; Definition of menus
; Format: ID, max_str_len, item_count, StringList
Menu_Pig_Game   !pet ID_MENU_GAME,4,2,"New",0,"Quit",0
Menu_Pig_Help   !pet ID_MENU_HELP,5,2,"Help",0,"About",0

; Chars of the pipes and the ground (redefined by the engine for the
; fine scroll position, except sky and pipe)
CharList        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff ; sky
                !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff ; sky -> pipe
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; pipe -> sky
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; pipe
                !byte $00,$00,$dd,$ee,$77,$bb,$dd,$ee ; ground (see HatchTab)

;======================================================================
; Engine - runs at $c000, independent of the app code at $b000
;======================================================================
EngineImage
!pseudopc ENGINE_BASE {
!zone Engine
; Sprite data first: pointer = (address - $c000) / 64
SpriteData      ; 5 sprites: 0-3 wings, 4 dead
                ; 0: wings 0
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000110,%00000000,%00000000 ; .....XX.................
                !byte %00000011,%11000000,%00000000 ; ......XXXX..............
                !byte %00000000,%11100000,%00000000 ; ........XXX.............
                !byte %00000001,%11110000,%00000000 ; .......XXXXX............
                !byte %00000000,%01111000,%00000000 ; .........XXXX...........
                !byte %00000000,%11111100,%00000000 ; ........XXXXXX..........
                !byte %00000000,%11111110,%00000000 ; ........XXXXXXX.........
                !byte %00000000,%11111111,%00000000 ; ........XXXXXXXX........
                !byte %00000000,%01111111,%00000000 ; .........XXXXXXX........
                !byte %01110000,%00011110,%01111000 ; .XXX.......XXXX..XXXX...
                !byte %00111111,%11011111,%11101111 ; ..XXXXXXXX.XXXXXXXX.XXXX
                !byte %01111111,%11111111,%11111100 ; .XXXXXXXXXXXXXXXXXXXXX..
                !byte %00000111,%11111111,%10000000 ; .....XXXXXXXXXXXX.......
                !byte %00000000,%11000000,%00000000 ; ........XX..............
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
                ; 1: wings 1
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000011,%11110000,%00000000 ; ......XXXXXX............
                !byte %00000000,%11111100,%00000000 ; ........XXXXXX..........
                !byte %00000000,%01111111,%00000000 ; .........XXXXXXX........
                !byte %01110000,%00011110,%01111000 ; .XXX.......XXXX..XXXX...
                !byte %00111111,%11011111,%11101111 ; ..XXXXXXXX.XXXXXXXX.XXXX
                !byte %01111111,%11111111,%11111100 ; .XXXXXXXXXXXXXXXXXXXXX..
                !byte %00000111,%11111111,%10000000 ; .....XXXXXXXXXXXX.......
                !byte %00000000,%11000000,%00000000 ; ........XX..............
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
                ; 2: wings 2
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %01110000,%11111110,%01111000 ; .XXX....XXXXXXX..XXXX...
                !byte %00111111,%10111111,%11101111 ; ..XXXXXXX.XXXXXXXXX.XXXX
                !byte %01111111,%01111111,%11111100 ; .XXXXXXX.XXXXXXXXXXXXX..
                !byte %00000110,%11111111,%10000000 ; .....XX.XXXXXXXXX.......
                !byte %00000000,%11000000,%00000000 ; ........XX..............
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
                ; 3: wings 3
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %01110000,%00000000,%11111000 ; .XXX............XXXXX...
                !byte %00111111,%11111111,%11101111 ; ..XXXXXXXXXXXXXXXXX.XXXX
                !byte %01111111,%11111111,%11111100 ; .XXXXXXXXXXXXXXXXXXXXX..
                !byte %00000111,%11111111,%10000000 ; .....XXXXXXXXXXXX.......
                !byte %00000000,%11111111,%00000000 ; ........XXXXXXXX........
                !byte %00000000,%01111110,%00000000 ; .........XXXXXX.........
                !byte %00000000,%00111100,%00000000 ; ..........XXXX..........
                !byte %00000000,%01111000,%00000000 ; .........XXXX...........
                !byte %00000000,%00110000,%00000000 ; ..........XX............
                !byte %00000000,%11100000,%00000000 ; ........XXX.............
                !byte %00000001,%11000000,%00000000 ; .......XXX..............
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
                ; 4: dead
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000110,%01011000 ; .............XX..X.XX...
                !byte %00000000,%00000101,%01010100 ; .............X.X.X.X.X..
                !byte %00000001,%01000110,%01011000 ; .......X.X...XX..X.XX...
                !byte %00000000,%10000101,%01010000 ; ........X....X.X.X.X....
                !byte %00000000,%11000000,%00000000 ; ........XX..............
                !byte %00000111,%11111111,%10000000 ; .....XXXXXXXXXXXX.......
                !byte %01111111,%11000111,%11111100 ; .XXXXXXXXX...XXXXXXXXX..
                !byte %00111111,%10111111,%11101111 ; ..XXXXXXX.XXXXXXXXX.XXXX
                !byte %01110000,%01111100,%01111000 ; .XXX.....XXXXX...XXXX...
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
SpriteDataEnd
!if (SpriteDataEnd - SpriteData) != (5 * 64) {
!error "bird.bin must hold 5 sprites"
}
SPRITE_PTR0     = (SpriteData - $c000) / 64
FRAME_DEAD      = 4
WING_TICKS      = 4 ; frames per wing sprite

; Tables
WingSeq         !byte 0, 1, 2, 3, 1             ; sprites of the wing beat
WING_STEPS      = 5
; Mask for the row r of a column whose pipe has its gap at row g:
; Mask[PIPE_ROWS - 1 - r + g] is $fc in the gap (char -> CH_SKY),
; $ff otherwise
Mask            !fill PIPE_ROWS - GAP_ROWS, $ff
                !fill GAP_ROWS, $fc
                !fill MAX_GAP_TOP, $ff
SwayTab         !byte 0, 1, 2, 3, 4, 3, 2, 1    ; x offset of the pigeon
BobTab          !byte 0, 1, 2, 2, 2, 1, 0, 0    ; y offset while waiting
; Ground: rows 2..7, row k is HatchTab[(k - fine) & 3]
HatchTab        !byte $77, $bb, $dd, $ee
ShlTab          !byte $ff,$fe,$fc,$f8,$f0,$e0,$c0,$80
SprRegs         !byte $1b, $1c, $17, $1d

; Text buffers - all in one page (see PutText)
ScoreText       !pet "Score: 000",0
BestText        !pet "Best: 000",0
SCORE_DIGITS    = 7 ; offset of the digits in the texts
BEST_DIGITS     = 6
; Game over message (MSG_H rows of MSG_W chars)
MsgText         !pet "                      "
                !pet "      Game over       "
                !pet " Hit SPACE to restart "
                !pet "                      "
MsgTextEnd
TextsEnd
!if (MsgTextEnd - MsgText) != (MSG_W * MSG_H) {
!error "MsgText must have MSG_H rows of MSG_W chars"
}
MsgRowOfs       !byte 0, MSG_W, 2 * MSG_W, 3 * MSG_W
!if >ScoreText != >(TextsEnd - 1) {
!error "The text buffers must be in one page"
}

; Frame handler: called by GUI64 once per frame from its raster IRQ
; (line 0, I/O visible, GUI64 saves the registers). It must not call
; GUI64 routines except the IRQ-safe ones.
FrameHandler    jsr GameFrame
                lda $d015                       ; the pigeon on or off
                and #$ff - SPRITE_BIT
                ldy SprOn
                beq +
                ora #SPRITE_BIT
+               sta $d015
                rts

; Stops the frame handler and switches the sprite off. Called on
; EC_SHUTDOWN.
StopEngine      jsr GUI_StopFrameHandling       ; (IRQ-safe)
                lda #0
                sta SprOn
                lda $d015
                and #$ff - SPRITE_BIT
                sta $d015
                rts

;----------------------------------------------------------------------
; One frame
GameFrame       lda ProgramMode                 ; menu or dialog open?
                bne .pause
                lda WindowType                  ; only while this is the
                cmp #WT_PIGEON                  ; current (top) window
                bne .pause
                lda WindowBits                  ; minimized?
                and #BIT_WND_ISMINIMIZED
                bne .pause
                lda WindowPosX                  ; and only at the position
                cmp WinX                        ; saved by TrackWindow (not
                bne .pause                      ; while the window is moved or
                lda WindowPosY                  ; GUI64 selects another one)
                cmp WinY
                bne .pause
                jsr Update
                jmp Render
.pause          lda #0                          ; hide the pigeon
                sta SprOn
                sta FlapReq
                rts

;----------------------------------------------------------------------
; Game logic
Update          inc Anim
                lda #SWAY_MID                   ; the pigeon sways (unless
                ldx State                       ; it lies on the ground)
                cpx #ST_OVER
                beq +
                lda Anim
                lsr
                lsr
                lsr
                and #7
                tax
                lda SwayTab,x
+               sta SwayX
                lda State
                cmp #ST_READY
                beq .ready
                cmp #ST_OVER
                beq .over
                cmp #ST_DEAD
                beq .dead
                ; flying
                jsr Scroll
                lda FlapReq
                beq +
                jsr Flap
+               jsr Hiccup
                jsr Physics
                jsr Collide                     ; hit a pipe?
                bcc CheckGround
                lda #ST_DEAD                    ; yes: it drops
                sta State
                lda #0
                sta Vel
                beq CheckGround                 ; jmp
.dead           lda #0                          ; no flapping any more
                sta FlapReq
                jsr Physics
                jmp CheckGround
.ready          jsr Scroll                      ; (no pipes yet)
                lda Anim                        ; the pigeon hovers
                lsr
                lsr
                and #7
                tax
                lda BobTab,x
                clc
                adc #START_Y
                jsr SetPos
                lda FlapReq                     ; SPACE takes off
                beq .idle
                jmp StartPlay
.over           lda OverWait                    ; SPACE starts a new game
                beq +                           ; (after a moment)
                dec OverWait
                lda #0
                sta FlapReq
                rts
+               lda FlapReq
                beq .idle
                jsr ResetGame
                jmp StartPlay
.idle           rts

; Game over, if the pigeon reached the ground
CheckGround     lda PigY
                cmp #PIG_GROUND
                bcc +
                lda #PIG_GROUND
                jsr SetPos
                jmp GameOver
+               rts

StartPlay       lda #ST_PLAY
                sta State
                ; fall through
; A flap - never twice with the same strength
Flap            lda #0
                sta FlapReq
                jsr Random
                and #FLAP_VAR
                clc
                adc #FLAP_VEL
                sta Tmp
                lda #0                          ; upwards
                sec
                sbc Tmp
                sta Vel
                rts

; Now and then the pigeon hiccups
Hiccup          lda HicTimer                    ; not right after a hiccup
                beq +
                dec HicTimer
                rts
+               jsr Random
                cmp #HIC_CHANCE
                bcs .no
                lda Vel
                sec
                sbc #HICCUP
                sta Vel
                lda #HIC_TIME
                sta HicTimer
.no             rts

; Gravity and moving by Vel (signed, 1/16 pixels)
Physics         lda Vel
                clc
                adc #GRAVITY
                bmi +
                cmp #VEL_MAX
                bcc +
                lda #VEL_MAX
+               sta Vel
                ldx #0
                lda Vel
                bpl +
                dex
+               clc
                adc PosLo
                sta PosLo
                txa
                adc PosHi
                sta PosHi
                bpl +                           ; above the top?
                lda #0                          ; then it bumps its head
                sta PosLo
                sta PosHi
                sta Vel
+               sta Tmp                         ; PigY = Pos / 16
                lda PosLo
                lsr Tmp
                ror
                lsr Tmp
                ror
                lsr Tmp
                ror
                lsr Tmp
                ror
                sta PigY
                rts

; A = y in pixels -> PigY and Pos
SetPos          sta PigY
                ldx #0
                stx PosHi
                asl
                rol PosHi
                asl
                rol PosHi
                asl
                rol PosHi
                asl
                rol PosHi
                sta PosLo
                rts

; Returns C=1 if the hit box of the pigeon touches a pipe
Collide         lda Fine                        ; cell at the left side
                clc
                adc #PIG_X + HB_L
                lsr
                lsr
                lsr
                tax
                jsr .cell
                bcs .hit
                lda Fine                        ; cell at the right side
                clc
                adc #PIG_X + HB_R
                lsr
                lsr
                lsr
                tax
.cell           lda Cells,x
                beq .free
                asl                             ; top of the gap
                asl
                asl
                sta Tmp
                lda PigY
                clc
                adc #HB_T
                cmp Tmp
                bcc .hit                        ; above the gap
                lda Tmp                         ; bottom of the gap
                adc #GAP_ROWS * 8 - 1           ; (C=1)
                sta Tmp
                lda PigY
                clc
                adc #HB_B
                cmp Tmp
                bcs .hit                        ; below the gap
.free           clc
                rts
.hit            sec
                rts

; Pipes and ground stop, empty playfield, 0 points
ResetGame       lda Dirty
                ora #DIRTY_PIPES | DIRTY_SCORE
                sta Dirty
                ldx #PF_W-1                     ; all columns, to erase
                lda #$ff                        ; the game over message
-               sta Drawn,x
                dex
                bpl -
                ldx #NUM_CELLS-1
                lda #0
-               sta Cells,x
                dex
                bpl -
                sta SegPipe
                sta Fine
                sta SubPix
                sta Vel
                sta Score
                sta Score+1
                sta FlapReq
                sta HicTimer
                sta OverWait
                sta State                       ; ST_READY
                lda #FIRST_SKY
                sta SegLeft
                lda #(MAX_GAP_TOP + 1) / 2
                sta SegGap
                lda #SPEED_START
                sta Speed
                lda #START_Y
                jsr SetPos
                ldx #2                          ; "000" points
                lda #"0"
-               sta ScoreText+SCORE_DIGITS,x
                dex
                bpl -
                rts

GameOver        lda #ST_OVER
                sta State
                lda #OVER_WAIT
                sta OverWait
                lda #0
                sta HicTimer
                lda Best                        ; new best?
                cmp Score
                lda Best+1
                sbc Score+1
                bcs +
                lda Score
                sta Best
                lda Score+1
                sta Best+1
                ldx #2                          ; and its digits
-               lda ScoreText+SCORE_DIGITS,x
                sta BestText+BEST_DIGITS,x
                dex
                bpl -
+               lda Dirty                       ; draw the best and the
                ora #DIRTY_BEST | DIRTY_PIPES   ; message (see Render)
                sta Dirty
                rts

; Scrolls the pipes by Speed/16 pixels
Scroll          lda SubPix
                clc
                adc Speed
                pha
                and #15
                sta SubPix
                pla
                lsr
                lsr
                lsr
                lsr
                clc
                adc Fine
-               cmp #8
                bcc +
                sbc #8
                pha
                jsr ShiftCells
                pla
                jmp -
+               sta Fine
                rts

; Shifts the cells one char to the left and adds a new one
ShiftCells      lda Dirty
                ora #DIRTY_PIPES
                sta Dirty
                ldx #0
-               lda Cells+1,x
                sta Cells,x
                inx
                cpx #NUM_CELLS-1
                bne -
                jsr NextCell
                sta Cells+NUM_CELLS-1
                lda State                       ; a pipe passed the pigeon?
                cmp #ST_PLAY
                bne .done
                lda Cells+PIG_COL-1
                beq .done
                lda Cells+PIG_COL
                bne .done
                inc Score                       ; a point
                bne +
                inc Score+1
+               lda Score                       ; faster every 8 points
                and #7
                bne +
                lda Speed
                cmp #SPEED_MAX
                bcs +
                adc #SPEED_STEP
                sta Speed
+               ldx #2                          ; count the digits of the
-               inc ScoreText+SCORE_DIGITS,x    ; score text, too
                lda ScoreText+SCORE_DIGITS,x
                cmp #"9"+1
                bcc +
                lda #"0"
                sta ScoreText+SCORE_DIGITS,x
                dex
                bpl -
+               lda Dirty
                ora #DIRTY_SCORE
                sta Dirty
.done           rts

; Returns the next cell: 0 = no pipe, 1..MAX_GAP_TOP = top row of the
; gap of the pipe. No pipes before the game starts.
NextCell        lda State
                cmp #ST_PLAY
                beq +
                lda #0
                rts
+               lda SegLeft
                bne .same
                lda SegPipe                     ; new segment
                eor #1
                sta SegPipe
                beq .sky
                lda #2 * MAX_GAP_STEP + 1       ; pipe: the gap moves up to
                sta ModVal                      ; MAX_GAP_STEP rows
                jsr Random
                jsr Mod
                clc
                adc SegGap
                sec
                sbc #MAX_GAP_STEP
                bmi .low
                beq .low
                cmp #MAX_GAP_TOP + 1
                bcc +
                lda #MAX_GAP_TOP
                bne +                           ; jmp
.low            lda #1
+               sta SegGap
                lda #PIPE_W
                bne .len                        ; jmp
.sky            lda #SPACING
.len            sta SegLeft
.same           dec SegLeft
                lda SegPipe
                beq +
                lda SegGap
+               rts

;----------------------------------------------------------------------
; Drawing (directly into the screen, while the window is on top)
Render          jsr EdgeChars
                ; Only redraw what changed (the whole window was
                ; redrawn by GUI64 anyway, if something else changed)
                lda WinX                        ; everything, if the window
                cmp DrawnX                      ; was moved
                bne .all
                lda WinY
                cmp DrawnY
                beq .parts
.all            lda WinX
                sta DrawnX
                lda WinY
                sta DrawnY
                jsr PatchRows                   ; (and draw the ground)
                ldx #PF_W-1                     ; all columns
                lda #$ff
-               sta Drawn,x
                dex
                bpl -
                lda #DIRTY_ALL
                sta Dirty
.parts          lsr Dirty                       ; DIRTY_PIPES
                php
                bcc +
                jsr DrawPipes
+               lda State
                cmp #ST_OVER
                bne .scrub
                plp                             ; game over: the pipes stand
                bcs +                           ; still, the message is drawn
                lda Anim                        ; over them (after the pipes,
                and #15                         ; and now and then, in case
                bne .scrubbed                   ; GUI64 painted the window
+               jsr DrawMsg                     ; just before the game ended)
                jmp .scrubbed
.scrub          plp
                ldy ScrubCol                    ; and one column in any case:
                lda #$ff                        ; if the engine scrolled while
                sta Drawn,y                     ; GUI64 repainted the window,
                jsr DrawColumn                  ; the screen doesn't show what
                dey                             ; Drawn says
                bpl +
                ldy #PF_W-1
+               sty ScrubCol
.scrubbed
                lsr Dirty                       ; DIRTY_SCORE
                bcc .noScore
                lda #SCORE_Y
                jsr SetRow
                ldx #SCORE_X
                lda #<ScoreText
                ldy #10
                jsr PutText
.noScore        lsr Dirty                       ; DIRTY_BEST
                bcc .noBest
                lda #SCORE_Y
                jsr SetRow
                ldx #BEST_X
                lda #<BestText
                ldy #9
                jsr PutText
.noBest
                ; the pigeon: x = 24 + column * 8 + PIG_X + sway
                lda WinX
                clc
                adc #PF_X
                ldx #0
                stx Tmp
                asl
                rol Tmp
                asl
                rol Tmp
                asl
                rol Tmp
                clc
                adc #24 + PIG_X - SWAY_MID
                bcc +
                inc Tmp
+               clc
                adc SwayX
                bcc +
                inc Tmp
+               sta $d000+2*SPRITE_NO
                lda Tmp
                beq +
                lda $d010
                ora #SPRITE_BIT
                bne ++
+               lda $d010
                and #$ff - SPRITE_BIT
++              sta $d010
                lda WinY                        ; y = 50 + row * 8 + PigY
                clc
                adc RowOffset
                adc #1 + PF_Y
                asl
                asl
                asl
                clc
                adc #50
                clc
                adc PigY
                ldx State                       ; dead or game over:
                cpx #ST_DEAD                    ; the dead frame, a bit
                bcc +                           ; higher
                sbc #DEAD_DY                    ; (C=1)
+               sta $d001+2*SPRITE_NO
                lda #PIGEON_COLOR
                sta $d027+SPRITE_NO
                dec WingTick                    ; wing beat: next sprite
                bpl +                           ; every WING_TICKS frames
                lda #WING_TICKS-1
                sta WingTick
                inc WingStep
                lda WingStep
                cmp #WING_STEPS
                bcc +
                lda #0
                sta WingStep
+               lda State                       ; sprite frame
                cmp #ST_DEAD
                lda #FRAME_DEAD
                bcs +                           ; dead or game over
                ldx WingStep                    ; flapping wings
                lda WingSeq,x
+               clc
                adc #SPRITE_PTR0
                ldx ScreenHi                    ; pointer = screen + $3f8
                inx
                inx
                inx
                stx .ptr+2
.ptr            sta $03f8+SPRITE_NO             ; high byte is patched
                ldx #3                          ; in front, single color,
-               ldy SprRegs,x                   ; not expanded
                lda $d000,y
                and #$ff - SPRITE_BIT
                sta $d000,y
                dex
                bpl -
                lda #1
                sta SprOn
                rts

; Redefines the edge chars and the ground for the fine scroll position
EdgeChars       ldx Fine
                lda ShlTab,x                    ; sky part of sky->pipe
                sta Tmp
                lda #$34                        ; charset is under the I/O area
                sta $01                         ; (not GUI_MapOutIO: not IRQ-safe)
                ldx #7
-               lda Tmp                         ; pipe pixels are cleared
                sta APP_CHARSET+(CH_GS-APP_CHAR_0)*8,x
                eor #$ff
                sta APP_CHARSET+(CH_SG-APP_CHAR_0)*8,x
                txa                             ; ground: hatched rows 2..7
                sec
                sbc Fine
                and #3
                tay
                lda HatchTab,y
                cpx #2
                bcs +
                lda #0                          ; rows 0 and 1: a line
+               sta APP_CHARSET+(CH_GROUND-APP_CHAR_0)*8,x
                dex
                bpl -
                lda #$35
                sta $01
                rts

; Patches the screen addresses of the rows into DrawRows and draws the
; ground row
PatchRows       lda #PF_Y
                jsr SetRow                      ; PutChar -> row start + WinX
                ldx #0
-               lda PutChar+1
                clc
                adc #PF_X
                sta DrawRows+7,x
                lda PutChar+2
                adc #0
                sta DrawRows+8,x
                lda PutChar+1                   ; next row
                clc
                adc #40
                sta PutChar+1
                bcc +
                inc PutChar+2
+               txa
                clc
                adc #ROW_CODE_LEN
                tax
                cpx #PIPE_ROWS * ROW_CODE_LEN
                bne -
                lda PutChar+1                   ; the ground
                sta .gnd+1
                lda PutChar+2
                sta .gnd+2
                ldx #PF_X + PF_W - 1
                lda #CH_GROUND
.gnd            sta $ffff,x                     ; address is patched
                dex
                cpx #PF_X - 1
                bne .gnd
                rts

; Draws the columns of the pipes whose cells changed
DrawPipes       ldy #PF_W-1                     ; Y = playfield column
-               jsr DrawColumn
                dey
                bpl -
                rts

; Draws column Y of the pipes if its cells changed (Y is preserved).
; The chars of a column depend on the cell there and the next cell:
; key = gap row * 4 + 2 * (pipe here) + (pipe in the next cell).
DrawColumn      ldx Cells,y
                cpx #1                          ; C=1: pipe here
                lda Cells,y
                ora Cells+1,y                   ; gap row (the same, if both
                rol                             ; cells are pipe)
                ldx Cells+1,y
                cpx #1                          ; C=1: pipe in the next cell
                rol
                cmp Drawn,y                     ; changed?
                bne +
                rts
+               sta Drawn,y
                tax
                and #3
                ora #CH_SKY
                sta ColChar
                txa
                lsr
                lsr
                tax                             ; X = gap row
DrawRows        ; one block per row (ROW_CODE_LEN bytes, addresses patched)
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 0,x
DrawRows1       sta $ffff,y
ROW_CODE_LEN    = DrawRows1 + 3 - DrawRows
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 1,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 2,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 3,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 4,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 5,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 6,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 7,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 8,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 9,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 10,x
                sta $ffff,y
                lda ColChar
                and Mask + PIPE_ROWS - 1 - 11,x
                sta $ffff,y
DrawRowsEnd
!if (DrawRowsEnd - DrawRows) != (PIPE_ROWS * ROW_CODE_LEN) {
!error "DrawRows needs one block per row of the pipes"
}
                rts

; Draws the game over message
DrawMsg         ldx #0
-               stx MsgRow
                txa
                clc
                adc #PF_Y + MSG_Y
                jsr SetRow
                ldx MsgRow
                lda MsgRowOfs,x
                clc
                adc #<MsgText
                ldx #PF_X + MSG_X
                ldy #MSG_W
                jsr PutText
                ldx MsgRow
                inx
                cpx #MSG_H
                bne -
                rts

; A = content row of the window -> PutChar (in PutText) writes to
; this row
SetRow          clc
                adc WinY
                adc RowOffset
                adc #1                          ; title bar
                sta Tmp                         ; screen row * 40:
                asl                             ; row * 5 (< 128) ...
                asl
                adc Tmp
                ldx #0
                stx PutChar+2
                asl                             ; ... * 8
                rol PutChar+2
                asl
                rol PutChar+2
                asl
                rol PutChar+2                   ; (C=0)
                adc WinX
                sta PutChar+1
                lda PutChar+2
                adc ScreenHi
                sta PutChar+2
                rts
; Writes the PETSCII text at A (low byte, page of ScoreText) with
; length Y to content column X of the current row
PutText         sta .txt+1
                lda #>ScoreText
                sta .txt+2
                sty Tmp
                ldy #0
.txt            lda $ffff,y
                jsr PetToScr
PutChar         sta $ffff,x                     ; address is patched (SetRow)
                inx
                iny
                cpy Tmp
                bne .txt
                rts

; PETSCII in A -> GUI64 screen code in A (X and Y are preserved)
PetToScr        cmp #$c0
                bcc +
                sbc #$40                        ; $c0-$df -> $80-$9f
                rts
+               ora #$80                        ; $20-$5f -> $a0-$df
                rts

;----------------------------------------------------------------------
; 16 bit Galois LFSR, returns random byte in A. X and Y are preserved.
Random          lsr Seed+1
                ror Seed
                bcc +
                lda Seed+1
                eor #$b4
                sta Seed+1
+               lda Seed
                rts

; A <- A mod [ModVal]
Mod             sec
-               sbc ModVal
                bcs -
                adc ModVal
                rts

;----------------------------------------------------------------------
; Engine variables
RowOffset       !byte 0 ; content row 0 = window y + RowOffset + 1
Seed            !word 1
WinX            !byte 0
WinY            !byte 0
ScreenHi        !byte 0 ; high byte of the screen (GUI_GetScreenMem)
SprOn           !byte 0
FlapReq         !byte 0 ; set by the window proc
State           !byte 0
Cells           !fill NUM_CELLS,0 ; 0 = no pipe, else top row of the gap
Drawn           !fill PF_W,$ff    ; key of the drawn chars of each column
SegPipe         !byte 0
SegGap          !byte 0
SegLeft         !byte 0
Dirty           !byte DIRTY_ALL
DrawnX          !byte $ff ; window position of the last drawing
DrawnY          !byte $ff
Fine            !byte 0
SubPix          !byte 0
Speed           !byte 0
Score           !word 0
Best            !word 0
PigY            !byte 0 ; sprite y in the playfield (pixels)
PosLo           !byte 0 ; PigY in 1/16 pixels
PosHi           !byte 0
Vel             !byte 0 ; signed, 1/16 pixels per frame, down is positive
SwayX           !byte 0
HicTimer        !byte 0
OverWait        !byte 0
Anim            !byte 0
WingTick        !byte 0 ; frames until the next wing sprite
WingStep        !byte 0 ; index in WingSeq
ColChar         !byte 0
ScrubCol        !byte 0
Tmp             !byte 0
ModVal          !byte 0
MsgRow          !byte 0
EngineEnd
!if EngineEnd > $d000 {
!error "Engine overlaps the charset at $d000"
}
}
ENGINE_PAGES    = (EngineEnd - ENGINE_BASE + 255) / 256

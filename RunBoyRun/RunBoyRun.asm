!to "RunBoyRun.d64",d64,"runboyrun.gui","runboyrun disk"

; Run Boy Run - a one button runner for GUI64 (MAC and WIN design),
; in the style of Canabalt
;
; Buildings of random heights (3 levels) with gaps between them scroll
; from right to left, the runner runs over their roofs. Press SPACE (or
; click into the window) to jump over the gaps - the longer SPACE (or
; the mouse button) is held, the higher the jump. Running into the wall
; of a higher building ends the run. Every char the line scrolls is a step (16 bit counter). The
; game gets faster over time.
;
; How it works:
; * Every cell of the line holds 0 (gap) or the level of the building
;   (1..3). The rows of the levels and the row below level 1 are drawn
;   with 4 app chars: sky, building, and two edge chars (building->sky,
;   sky->building). A cell is building in a row if its level is at
;   least the level of the row, so the roof is the top of the building.
;   Every frame, the chars are redefined for the fine scroll position
;   (0..7 pixels, the windows of the buildings move, too), and every 8
;   pixels, the cells are shifted left by one char.
; * GUI64 has no key release event (and sends the mouse button release
;   only after the double click time), so the engine reads SPACE and
;   the fire lines of both ports (the mouse button) directly to find out
;   how long they are held.
; * The runner is sprite 6 (free in both designs: GUI64 uses 0-1 for
;   the mouse and, in the WIN design, 2-5 for the taskbar logo).
; * Like in Roaches, the game runs in an "engine", which is GUI64's
;   frame handler (GUI_SetFrameHandler, called from GUI64's raster IRQ,
;   50 frames per second). The engine is copied to $c400 (app area in
;   GUI64's VIC bank, so the sprite data can be there, too) and draws
;   the line and the step counter directly into the
;   screen while the window is the current window. GUI64's repaints use
;   the same data (custom control and labels). On EC_SHUTDOWN, the frame
;   handling is stopped.
; * The app only uses the GUI64 API (gui64.inc.asm). The position of the
;   window comes from the current-window structure ($10-$1f): the GUI64
;   timer (GUI64 main loop) saves it in WinX/WinY, and the engine only
;   runs while the structure still shows the app window at this position
;   (in the IRQ, GUI64 may just be copying another window into it).

!source "gui64.inc.asm"

!zone Constants
WT_RUNBOYRUN     = 53 ; app window types start at 50
CT_PLAYFIELD     = 50 ; app control types start at 50
ID_MENU_GAME     = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

ENGINE_BASE      = $c400 ; engine is copied here

SPRITE_NO        = 6     ; apps for both designs may use sprites 6 and 7
SPRITE_BIT       = 1 << SPRITE_NO
RUNNER_COLOR     = CL_BLACK

; Layout (content coordinates of the window)
PF_X             = 1  ; playfield control
PF_Y             = 2
PF_W             = 30
PF_H             = 9
NUM_LEVELS       = 3
GROUND_ROW       = 7  ; row of the roofs of the lowest buildings (level 1) in the playfield
TOP_ROW          = GROUND_ROW - NUM_LEVELS + 1 ; row of the highest roofs
RUNNER_COL       = 4  ; column of the runner in the window
NUM_CELLS        = PF_W + 1 ; one more cell for the right edge
FOOT_X           = (RUNNER_COL - PF_X) * 8 + 4 ; runner's foot in the line
; Game over message: MSG_H rows of MSG_W chars in the sky above the
; buildings (see MsgText), which the engine doesn't draw otherwise
MSG_W            = 20
MSG_H            = 2
MSG_X            = (PF_W - MSG_W) / 2 ; playfield column
MSG_Y            = 2                  ; playfield row
; Content row 0 is the second row of the window header, so the
; controls start in row 1
SCORE_Y          = 1  ; row of steps and best
STEPS_X          = 1
BEST_X           = 19

; App chars of the buildings. Set pixels have the window color (sky and
; lit windows), the buildings are drawn with cleared (black) pixels.
; The order matters: char = CH_GAP + 2 * (building here) + (building in
; the next cell)
CH_GAP           = APP_CHAR_0
CH_GS            = APP_CHAR_1 ; sky -> building
CH_SG            = APP_CHAR_2 ; building -> sky
CH_SOLID         = APP_CHAR_3
WINDOWS          = %01100110  ; lit windows in the rows 3 and 4 of a char

; Parts of the window the engine has to redraw
DIRTY_LINE       = 1 ; the buildings
DIRTY_STEPS      = 2 ; step counter
DIRTY_BEST       = 4
DIRTY_MSG        = 8 ; game over message (or its erasure)
DIRTY_ALL        = DIRTY_LINE | DIRTY_STEPS | DIRTY_BEST | DIRTY_MSG

; Game states
ST_READY         = 0
ST_RUN           = 1
ST_JUMP          = 2
ST_FALL          = 3
ST_OVER          = 4

; Speed in 1/16 pixels per frame
SPEED_START      = 32
SPEED_MAX        = 64
SPEED_STEP       = 2  ; faster every 64 steps

; Jump physics. Velocities in 1/16 pixels per frame (up is positive),
; gravity in 1/16 pixels per frame^2. While the button is held, the
; runner keeps rising without gravity for up to HOLD_MAX frames.
; Jump height: about 8 pixels without holding, up to 31 pixels held.
JUMP_VEL         = 32
GRAVITY          = 4
HOLD_MAX         = 12
VEL_MAX          = 96  ; max. falling speed
STEP_UP          = 4   ; the runner climbs a wall up to 4 pixels high
; Heights are biased by HBASE, so that they are always positive:
; HBASE is the top of a level 1 building, each level is 8 pixels higher.
HBASE            = 64
FALL_OUT         = HBASE - 16 ; game over below this height

!zone Init
*=$b000
                lda #WT_RUNBOYRUN               ; look for window with type "WT_RUNBOYRUN"
                sta Param0                      ;
                jsr GUI_FindWndByType           ;
                bcc +                           ; if not found, start app
                stx Param0                      ; otherwise, make this window
                jmp GUI_SelectTopWindow         ; the top window and leave
                ; Start app
+               ; Copy engine to ENGINE_BASE
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
                ldy #>CharList                  ; chars of
                lda #4                          ; the line
                jsr GUI_RegisterChars           ;
                ldx #<CtrlAction                ; Behavior of the playfield
                ldy #>CtrlAction                ; (void, events are handled
                jsr GUI_SetCtrlActionsRoutine   ; in the window proc)
                ldx #<PaintCtrls                ; Look of the
                ldy #>PaintCtrls                ; playfield
                jsr GUI_SetPaintCtrlsRoutine    ;
                ;
                ldx #<Wnd_RunBoyRun             ; Create the window with
                ldy #>Wnd_RunBoyRun             ; its controls
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
                ldx #<Str_RBRMenubar            ; strings with control 0
                ldy #>Str_RBRMenubar            ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                ; Labels show the text buffers of the engine
                jsr GUI_SelectControl1
                ldx #<StepsText
                ldy #>StepsText
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
                cmp #WT_RUNBOYRUN
                bne +
                lda WindowPosX
                sta WinX
                lda WindowPosY
                sta WinY
+               rts

; Window Proc (event handler for window)
RunBoyRunWndProc jsr GUI_StdWndProc             ; MUST always be called
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
                beq .jump
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
.jump           lda #1                          ; the engine does the rest
                sta JumpReq
.leave          rts

; Invoked when an item in the game menu was clicked
GameMenuClicked lda CurMenuItem                 ; 0: New
                bne +
                php                             ; back to the start screen
                sei                             ; (the engine must not run
                jsr ResetLine                   ; in between)
                lda #ST_READY
                sta State
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
                jsr ResetLine                   ; (State is ST_READY)
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
                lda #0                          ; the sky: only the game over
                sta PaintRow                    ; message
.sky            lda State
                cmp #ST_OVER
                bne .nextSky
                lda PaintRow
                sec
                sbc #MSG_Y
                cmp #MSG_H
                bcs .nextSky
                tax
                lda MsgRowOfs,x                 ; X = last char of the row
                clc
                adc #MSG_W-1
                tax
                ldy #MSG_X + MSG_W - 1
-               lda MsgText,x
                jsr PetToScr
                sta (ZP_FD),y
                lda PaintColor
                sta ($02),y
                dex
                dey
                cpy #MSG_X - 1
                bne -
.nextSky        jsr GUI_AddBufWidthToFD         ; go down to the highest level
                jsr GUI_AddBufWidthTo02
                inc PaintRow
                lda PaintRow
                cmp #TOP_ROW
                bne .sky
                ldx #NUM_LEVELS                 ; one row per level, and X=0:
                                                ; the row below level 1
.row            ldy #PF_W-1
-               jsr CellChar
                sta (ZP_FD),y
                lda PaintColor
                sta ($02),y
                dey
                bpl -
                dex
                bmi +
                jsr GUI_AddBufWidthToFD
                jsr GUI_AddBufWidthTo02
                jmp .row
+               rts

; Y = playfield column, X = level of the row (0: row below level 1)
; -> A = char there. X and Y are preserved. Must not use any variables
; of the engine, as the engine's IRQ can interrupt GUI64's repaint.
; (The engine's Render uses the tables Level3Chars etc. instead.)
CellChar        stx PaintLevel
                txa
                bne +
                inc PaintLevel                  ; row below level 1: like level 1
+               lda Cells,y
                cmp PaintLevel                  ; C=1: building in this cell
                lda #0
                rol
                asl
                sta PaintChar
                lda Cells+1,y
                cmp PaintLevel                  ; C=1: building in the next cell
                lda #CH_GAP
                adc PaintChar                   ; CH_GAP + 2 * this + next
                rts

!zone Data
PaintColor      !byte 0
PaintRow        !byte 0
PaintLevel      !byte 0
PaintChar       !byte 0
Str_Title_App   !pet "Run Boy Run",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_RunBoyRun   !byte WT_RUNBOYRUN, %00100001, 4, 7, 32, 14, <Str_Title_App, >Str_Title_App
                !byte <RunBoyRunWndProc, >RunBoyRunWndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
                ;0
                !byte CT_MENUBAR, <RBRMenubar, >RBRMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL, STEPS_X, SCORE_Y, 12, 1
                !pet 0
                ;2
                !byte CT_LABEL, BEST_X, SCORE_Y, 11, 1
                !pet 0
                ;3
                !byte CT_PLAYFIELD, PF_X, PF_Y, PF_W, PF_H
                !pet 0
                ; closing zero byte
                !byte 0

; Strings
Str_Mess_Help   !pet "SPACE or click: jump\Hold it: jump higher\Don't hit the walls",0
Str_Mess_About  !pet "Run Boy Run\A one button runner\for GUI64",0

; Definition of menu bar
RBRMenubar      !word Menu_RBR_Game, Menu_RBR_Help
Str_RBRMenubar  !pet "Game",0,"?",0
; Definition of menus
; Format: ID, max_str_len, item_count, StringList
Menu_RBR_Game   !pet ID_MENU_GAME,4,2,"New",0,"Quit",0
Menu_RBR_Help   !pet ID_MENU_HELP,5,2,"Help",0,"About",0

; Chars of the buildings (all but the sky are redefined by the engine)
CharList        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff ; sky
                !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff ; sky -> building
                !byte $00,$00,$00,WINDOWS,WINDOWS,$00,$00,$00 ; building -> sky
                !byte $00,$00,$00,WINDOWS,WINDOWS,$00,$00,$00 ; building

;======================================================================
; Engine - runs at $c400, independent of the app code at $b000
;======================================================================
EngineImage
!pseudopc ENGINE_BASE {
!zone Engine
; Sprite data first: pointer = (address - $c000) / 64
SpriteData      ; 0: start
                !byte %00001100,0,0, %00001100,0,0, %00011000,0,0, %00011000,0,0
                !byte %00011100,0,0, %00011000,0,0, %00011000,0,0, %00011000,0,0
                !fill 64-24,0
                ; 1: run 1
                !byte %00011000,0,0, %00011000,0,0, %00110000,0,0, %01111100,0,0
                !byte %10110000,0,0, %01010000,0,0, %00001000,0,0, %00000100,0,0
                !fill 64-24,0
                ; 2: run 2
                !byte %00011000,0,0, %00011000,0,0, %01110100,0,0, %01111000,0,0
                !byte %00110000,0,0, %11010000,0,0, %00001000,0,0, %00001000,0,0
                !fill 64-24,0
                ; 3: run 3
                !byte %00011000,0,0, %00011000,0,0, %00110000,0,0, %00111000,0,0
                !byte %00110100,0,0, %00110000,0,0, %01100000,0,0, %00110000,0,0
                !fill 64-24,0
                ; 4: run 4
                !byte %00011000,0,0, %00011000,0,0, %00110000,0,0, %00110000,0,0
                !byte %00111100,0,0, %00110000,0,0, %01010000,0,0, %10100000,0,0
                !fill 64-24,0
                ; 5: run 5
                !byte %00011000,0,0, %00011000,0,0, %00110000,0,0, %00110000,0,0
                !byte %00011100,0,0, %00111000,0,0, %00100100,0,0, %01000100,0,0
                !fill 64-24,0
                ; 6: run 6
                !byte %00011000,0,0, %00011000,0,0, %01110000,0,0, %10110000,0,0
                !byte %00111000,0,0, %01110000,0,0, %11001000,0,0, %00000100,0,0
                !fill 64-24,0
                ; 7: jump: take-off
                !byte %00011000,0,0, %00011000,0,0, %00110000,0,0, %00110000,0,0
                !byte %00111000,0,0, %00100100,0,0, %01000000,0,0, %01000000,0,0
                !fill 64-24,0
                ; 8: jump: rising
                !byte %00011000,0,0, %00011000,0,0, %00110000,0,0, %00110000,0,0
                !byte %00111100,0,0, %00110010,0,0, %00100000,0,0, %01000000,0,0
                !fill 64-24,0
                ; 9: jump: top
                !byte %00001100,0,0, %00011100,0,0, %00110000,0,0, %00111000,0,0
                !byte %00110100,0,0, %00011010,0,0
                !fill 64-18,0
                ; 10: jump: falling
                !byte %00011010,0,0, %00011100,0,0, %00111000,0,0, %01011000,0,0
                !byte %00011000,0,0, %00001100,0,0, %00001100,0,0, %00000100,0,0
                !fill 64-24,0
                ; 11: jump: landing
                !byte %00011000,0,0, %00011010,0,0, %00111100,0,0, %01011000,0,0
                !byte %01011000,0,0, %00011000,0,0, %00001000,0,0, %00001000,0,0
                !fill 64-24,0
SPRITE_PTR0     = (SpriteData - $c000) / 64
FRAME_START     = 0   ; standing (before the game starts)
FRAME_RUN       = 1   ; run: 6 frames, the next one every RUN_STEP
RUN_FRAMES      = 6   ; pixels scrolled (so the feet match the ground)
RUN_STEP        = 5
!if (RUN_STEP * 16) <= (SPEED_MAX) {
!error "RUN_STEP too small: max. one run frame per video frame"
}
FRAME_JUMP      = 7   ; jump: 5 frames, selected by the velocity
JUMP_FRAMES     = 5
; Lowest velocity of the jump frames 7-10 (+$80, so that they compare
; unsigned; below the last one: frame 11)
JumpVels        !byte 128+24, 128+8, 128-8, 128-32

; Chars of the rows of the levels, index = cell * 4 + next cell
; (a cell is building in the row of level L if its level is >= L)
Level3Chars     !byte CH_GAP, CH_GAP, CH_GAP, CH_GS,    CH_GAP, CH_GAP, CH_GAP, CH_GS
                !byte CH_GAP, CH_GAP, CH_GAP, CH_GS,    CH_SG,  CH_SG,  CH_SG,  CH_SOLID
Level2Chars     !byte CH_GAP, CH_GAP, CH_GS,  CH_GS,    CH_GAP, CH_GAP, CH_GS,  CH_GS
                !byte CH_SG,  CH_SG,  CH_SOLID, CH_SOLID, CH_SG, CH_SG, CH_SOLID, CH_SOLID
Level1Chars     !byte CH_GAP, CH_GS,  CH_GS,  CH_GS,    CH_SG,  CH_SOLID, CH_SOLID, CH_SOLID
                !byte CH_SG,  CH_SOLID, CH_SOLID, CH_SOLID, CH_SG, CH_SOLID, CH_SOLID, CH_SOLID

; Text buffers - all in one page (see PutText)
StepsText       !pet "Steps: 00000",0
BestText        !pet "Best: 00000",0
STEPS_DIGITS    = 7 ; offset of the digits in the texts
BEST_DIGITS     = 6
; Game over message (MSG_H rows of MSG_W chars)
MsgText         !pet "     Game over      "
                !pet "Hit SPACE to restart"
MsgTextEnd
MsgBlank        !fill MSG_W, $20
TextsEnd
!if (MsgTextEnd - MsgText) != (MSG_W * MSG_H) {
!error "MsgText must have MSG_H rows of MSG_W chars"
}
!if >StepsText != >(TextsEnd - 1) {
!error "The text buffers must be in one page"
}
MsgRowOfs       !byte 0, MSG_W

; Frame handler: called by GUI64 once per frame from its raster IRQ
; (line 0, I/O visible, GUI64 saves the registers). It must not call
; GUI64 routines except the IRQ-safe ones.
FrameHandler    jsr GameFrame
                lda $d015                       ; the runner on or off
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
                cmp #WT_RUNBOYRUN               ; current (top) window
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
.pause          lda #0                          ; hide the runner
                sta SprOn
                sta JumpReq
                rts

;----------------------------------------------------------------------
; Game logic
Update          lda State
                cmp #ST_READY
                beq .waiting
                cmp #ST_OVER
                bne .playing
.waiting        lda JumpReq                     ; SPACE starts a new game
                beq +
                jsr NewGame
+               lda #0
                sta JumpReq
                rts
.playing        jsr Scroll
                lda AnimSub                     ; run animation: next frame
                clc                             ; every RUN_STEP pixels
                adc Speed
                cmp #RUN_STEP * 16
                bcc ++
                sbc #RUN_STEP * 16
                ldx Anim
                inx
                cpx #RUN_FRAMES
                bcc +
                ldx #0
+               stx Anim
++              sta AnimSub
                jsr ReadHold
                lda State
                cmp #ST_RUN
                bne .air
                ; running
                lda JumpReq
                beq +
                lda #0                          ; jump
                sta JumpReq
                sta HoldT
                lda #JUMP_VEL
                sta Vel
                lda #ST_JUMP
                sta State
                rts
+               jsr FootSurface                 ; still ground under the foot?
                bcc .off
                cmp Height
                beq .onGround
.off            lda #0                          ; ran over the edge
                sta Vel
                lda #ST_JUMP
                sta State
.onGround       rts
                ; in the air (ST_JUMP: can land, ST_FALL: hit a wall)
.air            lda #0                          ; no jumping in the air
                sta JumpReq
                lda Height
                sta OldH
                ldx #GRAVITY
                lda Vel                         ; while rising and the
                beq .accel                      ; button is held, the
                bmi .accel                      ; runner flies without
                lda Held                        ; gravity for a while
                beq .release
                lda HoldT
                cmp #HOLD_MAX
                bcs .accel
                inc HoldT
                ldx #0
                beq .accel                      ; jmp
.release        lda #HOLD_MAX                   ; released: the jump can't
                sta HoldT                       ; be extended any more
.accel          stx Tmp
                lda Vel
                sec
                sbc Tmp
                bpl +
                cmp #256-VEL_MAX
                bcs +
                lda #256-VEL_MAX
+               sta Vel
                jsr Move
                lda State
                cmp #ST_FALL
                beq .out
                jsr FootSurface                 ; roof under the foot?
                bcc .out
                sta Tmp                         ; its surface
                lda Height
                cmp Tmp
                beq .onTop
                bcs .above
                lda OldH                        ; below the surface: came
                cmp Tmp                         ; from above it?
                bcs .land
                lda Height                      ; almost high enough?
                adc #STEP_UP                    ; (C=0)
                cmp Tmp
                bcs .land
                lda #ST_FALL                    ; no: hit the wall
                sta State
                lda Vel
                bmi +
                lda #0
                sta Vel
+               rts
.onTop          lda Vel                         ; not while rising
                beq .land
                bpl .above
.land           lda Tmp
                jsr SetHeight
                lda #ST_RUN
                sta State
.above          rts
.out            lda Height                      ; fell down?
                cmp #FALL_OUT
                bcs +
                jmp GameOver
+               rts

; Returns C=1 and A = height of the surface, if the cell under the
; runner's foot is solid, C=0 if it is a gap.
FootSurface     lda Fine
                clc
                adc #FOOT_X
                lsr
                lsr
                lsr
                tax
                lda Cells,x
                clc
                beq +                           ; gap: C=0
                sec                             ; (level - 1) * 8 + HBASE
                sbc #1
                asl
                asl
                asl
                adc #HBASE
                sec
+               rts

; Moves the runner by Vel (signed, 1/16 pixels)
Move            ldx #0
                lda Vel
                bpl +
                dex
+               clc
                adc PosLo
                sta PosLo
                txa
                adc PosHi
                sta PosHi
                asl                             ; Height = Pos / 16
                asl
                asl
                asl
                sta Tmp
                lda PosLo
                lsr
                lsr
                lsr
                lsr
                ora Tmp
                sta Height
                rts

; A = height in pixels -> Height and Pos
SetHeight       sta Height
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

; Held <> 0 while SPACE or the mouse button is held. SPACE is read from
; the keyboard matrix (column 7, row 4) - the same line as the fire
; button (left mouse button) in port 1. The fire line of port 2 is
; bit 4 of $dc00.
ReadHold        lda $dc00
                tax
                lda #$7f
                sta $dc00
                lda $dc01                       ; SPACE or port 1
                and $dc00                       ; port 2
                stx $dc00
                and #$10
                eor #$10                        ; $10 if pressed
                sta Held
                rts

NewGame         jsr ResetLine
                lda #ST_RUN
                sta State
                rts

; Solid line on level 1, start speed, 0 steps
ResetLine       lda Dirty
                ora #DIRTY_LINE | DIRTY_MSG     ; (erases the message)
                sta Dirty
                ldx #NUM_CELLS-1
                lda #1
-               sta Cells,x
                dex
                bpl -
                sta SegSolid
                sta SegLevel
                lda #8                          ; 8 more solid cells
                sta SegLeft
                lda #HBASE
                jsr SetHeight
                lda #0
                sta Fine
                sta SubPix
                sta Vel
                sta Steps
                sta Steps+1
                sta JumpReq
                lda #SPEED_START
                sta Speed
                ldx #4                          ; "00000" steps
                lda #"0"
-               sta StepsText+STEPS_DIGITS,x
                dex
                bpl -
                lda Dirty
                ora #DIRTY_STEPS
                sta Dirty
                rts

GameOver        lda #ST_OVER
                sta State
                lda Steps                       ; new best?
                cmp Best
                lda Steps+1
                sbc Best+1
                bcc +
                lda Steps
                sta Best
                lda Steps+1
                sta Best+1
                ldx #4                          ; and its digits
-               lda StepsText+STEPS_DIGITS,x
                sta BestText+BEST_DIGITS,x
                dex
                bpl -
+               lda Dirty                       ; draw the best and the
                ora #DIRTY_BEST | DIRTY_MSG     ; message
                sta Dirty
                rts

; Scrolls the line by Speed/16 pixels
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
                ora #DIRTY_LINE
                sta Dirty
                ldx #0
-               lda Cells+1,x
                sta Cells,x
                inx
                cpx #NUM_CELLS-1
                bne -
                jsr NextCell
                sta Cells+NUM_CELLS-1
                lda State                       ; count the steps
                cmp #ST_FALL                    ; (not while falling)
                beq .done
                inc Steps
                bne +
                inc Steps+1
+               lda Steps                       ; faster every 64 steps
                and #63
                bne +
                lda Speed
                cmp #SPEED_MAX
                bcs +
                adc #SPEED_STEP
                sta Speed
+               ldx #4                          ; count the digits of the
-               inc StepsText+STEPS_DIGITS,x    ; steps text, too
                lda StepsText+STEPS_DIGITS,x
                cmp #"9"+1
                bcc +
                lda #"0"
                sta StepsText+STEPS_DIGITS,x
                dex
                bpl -
+               lda Dirty
                ora #DIRTY_STEPS
                sta Dirty
.done           rts

; Returns the next cell of the line: 0 = gap, 1..3 = level of the building
NextCell        lda SegLeft
                bne .same
                lda SegSolid                    ; new segment
                eor #1
                sta SegSolid
                beq .gap
                lda Speed                       ; solid: 5 + speed / 16 + 0..7
                lsr
                lsr
                lsr
                lsr
                clc
                adc #5
                sta Tmp
                jsr Random
                and #7
                clc
                adc Tmp
                sta SegLeft
                lda #NUM_LEVELS                 ; random level 1..3
                sta ModVal
                jsr Random
                jsr Mod
                clc
                adc #1
                sta SegLevel
                bne .same                       ; jmp
.gap            lda Speed                       ; gap: 2 .. speed / 8
                lsr
                lsr
                lsr
                sec
                sbc #1
                sta ModVal
                jsr Random
                jsr Mod
                clc
                adc #2
                sta SegLeft
.same           dec SegLeft
                lda SegSolid
                beq +
                lda SegLevel
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
                lda #DIRTY_ALL
                sta Dirty
.parts          lsr Dirty                       ; DIRTY_LINE
                bcc .noLine
                ; the buildings: all rows (levels 3, 2, 1 and the row
                ; below level 1) at once
                lda #PF_Y + TOP_ROW
                jsr SetRow
                ldx #0                          ; patch the addresses of
-               lda PutChar+1                   ; the rows (one row down
                sta .lv3+1,x                    ; per level)
                clc
                adc #40
                sta PutChar+1
                lda PutChar+2
                sta .lv3+2,x
                adc #0
                sta PutChar+2
                txa
                clc
                adc #.lv2 - .lv3
                tax
                cpx #3 * (.lv2 - .lv3)
                bne -
                lda PutChar+1                   ; the row below level 1
                sta .lv0+1
                lda PutChar+2
                sta .lv0+2
                ldy #PF_X + PF_W - 1            ; Y = content column
.cell           lda Cells - PF_X,y              ; cell * 4 + next cell
                asl
                asl
                ora Cells - PF_X + 1,y
                tax
                lda Level3Chars,x
.lv3            sta $ffff,y                     ; addresses are patched
                lda Level2Chars,x
.lv2            sta $ffff,y
                lda Level1Chars,x
                sta $ffff,y
.lv0            sta $ffff,y                     ; (same chars as level 1)
                dey
                cpy #PF_X - 1
                bne .cell
.noLine         lsr Dirty                       ; DIRTY_STEPS
                bcc .noSteps
                lda #SCORE_Y
                jsr SetRow
                ldx #STEPS_X
                lda #<StepsText
                ldy #12
                jsr PutText
.noSteps        lsr Dirty                       ; DIRTY_BEST
                bcc .noBest
                lda #SCORE_Y
                jsr SetRow
                ldx #BEST_X
                lda #<BestText
                ldy #11
                jsr PutText
.noBest         lsr Dirty                       ; DIRTY_MSG
                bcc .noMsg
                jsr DrawMsg
.noMsg
                ; the runner
                lda WinX                        ; x = 24 + column * 8
                clc
                adc #RUNNER_COL
                ldx #0
                stx Tmp
                asl
                rol Tmp
                asl
                rol Tmp
                asl
                rol Tmp
                clc
                adc #24
                sta $d000+2*SPRITE_NO
                lda Tmp
                adc #0
                beq +
                lda $d010
                ora #SPRITE_BIT
                bne ++
+               lda $d010
                and #$ff - SPRITE_BIT
++              sta $d010
                lda Height                      ; y = 50 + row * 8 - 8 - height
                sec                             ; (height above level 1,
                sbc #HBASE                      ; signed)
                sta Tmp
                lda WinY
                clc
                adc RowOffset
                adc #1 + PF_Y + GROUND_ROW
                asl
                asl
                asl
                clc
                adc #50 - 9                     ; (the feet are in sprite
                sec                             ; row 7)
                sbc Tmp
                sta $d001+2*SPRITE_NO
                lda #RUNNER_COLOR
                sta $d027+SPRITE_NO
                lda State                       ; sprite frame
                cmp #ST_RUN
                beq .runFrame
                cmp #ST_READY
                bne .jumpFrame
                lda #FRAME_START
                beq .frame                      ; jmp
.runFrame       lda Anim
                clc
                adc #FRAME_RUN
                bpl .frame                      ; jmp
.jumpFrame      lda Vel                         ; in the air: by velocity
                eor #$80                        ; (signed -> unsigned)
                ldx #0
-               cmp JumpVels,x
                bcs +
                inx
                cpx #JUMP_FRAMES - 1
                bcc -
+               txa
                adc #FRAME_JUMP - 1             ; (C = 1 here)
.frame          clc
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
                ldx #0                          ; visible unless the game is over
                lda State
                cmp #ST_OVER
                beq +
                inx
+               stx SprOn
                rts

; Redefines the building chars for the fine scroll position. Building
; pixels are cleared, sky and lit windows are set:
; building = windows (scrolled), sky -> building = building | left
; part, building -> sky = building | right part
EdgeChars       ldx Fine
                lda ShlTab,x                    ; left part (8 - Fine pixels)
                sta Tmp
                eor #$ff                        ; right part
                sta ModVal                      ; (free here)
                txa
                and #3                          ; (windows repeat every 4 pixels)
                tax
                lda WinTab,x
                sta .win+1
                lda #$34                        ; charset is under the I/O area
                sta $01                         ; (not GUI_MapOutIO: not IRQ-safe)
                ldx #7
-               lda #0                          ; rows 3 and 4: windows
                cpx #3
                bcc +
                cpx #5
                bcs +
.win            lda #0                          ; windows (patched)
+               sta APP_CHARSET+(CH_SOLID-APP_CHAR_0)*8,x
                tay
                ora Tmp
                sta APP_CHARSET+(CH_GS-APP_CHAR_0)*8,x
                tya
                ora ModVal
                sta APP_CHARSET+(CH_SG-APP_CHAR_0)*8,x
                dex
                bpl -
                lda #$35
                sta $01
                rts
SprRegs         !byte $1b, $1c, $17, $1d
ShlTab          !byte $ff,$fe,$fc,$f8,$f0,$e0,$c0,$80
WinTab          !byte WINDOWS, ((WINDOWS << 1) & $ff) | (WINDOWS >> 7) ; rotated left by 0..3 pixels
                !byte ((WINDOWS << 2) & $ff) | (WINDOWS >> 6), ((WINDOWS << 3) & $ff) | (WINDOWS >> 5)

; Draws the game over message, or erases it (if the game isn't over)
DrawMsg         ldx #0
-               stx MsgRow
                txa
                clc
                adc #PF_Y + MSG_Y
                jsr SetRow
                ldx MsgRow
                lda #<MsgBlank
                ldy State
                cpy #ST_OVER
                bne +
                lda MsgRowOfs,x
                clc
                adc #<MsgText
+               ldx #PF_X + MSG_X
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
; Writes the PETSCII text at A (low byte, page of StepsText) with
; length Y to content column X of the current row
PutText         sta .txt+1
                lda #>StepsText
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


;----------------------------------------------------------------------
; Engine variables
RowOffset       !byte 0 ; content row 0 = window y + RowOffset + 1
Seed            !word 1
WinX            !byte 0
WinY            !byte 0
ScreenHi        !byte 0 ; high byte of the screen (GUI_GetScreenMem)
SprOn           !byte 0
JumpReq         !byte 0 ; set by the window proc
Held            !byte 0 ; SPACE or mouse button held
State           !byte 0
Cells           !fill NUM_CELLS,0 ; 0 = gap, 1..3 = level
SegSolid        !byte 0
SegLevel        !byte 0
SegLeft         !byte 0
Dirty           !byte DIRTY_ALL
DrawnX          !byte $ff ; window position of the last drawing
DrawnY          !byte $ff
Fine            !byte 0
SubPix          !byte 0
Speed           !byte 0
Steps           !word 0
Best            !word 0
Height          !byte 0 ; of the runner's foot in pixels (biased by HBASE)
OldH            !byte 0
PosLo           !byte 0 ; Height in 1/16 pixels
PosHi           !byte 0
Vel             !byte 0 ; signed, 1/16 pixels per frame, up is positive
HoldT           !byte 0 ; frames the jump was extended
Anim            !byte 0 ; run frame 0..RUN_FRAMES-1
AnimSub         !byte 0 ; 1/16 pixels scrolled since the last run frame
Tmp             !byte 0
ModVal          !byte 0
MsgRow          !byte 0
EngineEnd
!if EngineEnd > $d000 {
!error "Engine overlaps the charset at $d000"
}
}
ENGINE_PAGES    = (EngineEnd - ENGINE_BASE + 255) / 256

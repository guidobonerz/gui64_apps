!to "Cannonball.d64",d64,"cannonball.gui","cannonball disk"

; Cannonball - an artillery game for two players for GUI64 (MAC and WIN
; design)
;
; Each player has a cannon on a tower, with a city in between. The
; players take turns: CRSR up/down sets the angle of the barrel,
; CRSR left/right the power of the shot, SPACE fires. Buildings block
; the shots, and every building hit loses a piece. A hit on the other
; cannon is a point, and both cannons move to new heights in a new city.
;
; How it works:
; * The playfield is a map of PF_W x PF_H cells (sky, wall, ground and
;   the 2x2 chars of each cannon), drawn with 11 app chars. The cannons
;   are redefined (GUI_RegisterChars) whenever an angle changes. The
;   colors only come from PaintCtrls (GUI64's color buffer): a cell only
;   changes from wall to sky during a round, and the sky has no set
;   pixels, so its color doesn't matter.
; * The flying ball and the explosions are sprite 7 (apps for both
;   designs may use sprites 6 and 7).
; * Like in Drunken Pigeon, the flight runs in an "engine", which is
;   GUI64's frame handler (GUI_SetFrameHandler, called from GUI64's
;   raster IRQ, 50 frames per second). It is copied to $c000 (in GUI64's
;   VIC bank, so the sprite data can be there, too) and writes into the
;   screen (GUI_GetScreenMem) while the window is the current window: the
;   map row by row (in case it changed during a repaint of GUI64), the
;   broken walls and the status line. On EC_SHUTDOWN, the frame handling
;   is stopped.
; * Aiming, firing and building a new city run in GUI64's main loop
;   (window proc and timer handler). A new city is built by the timer
;   handler when the engine asks for it, followed by
;   GUI_RepaintCurWindow for the new colors.
; * The app only uses the GUI64 API (gui64.inc.asm). The position of the
;   window comes from the current-window structure ($10-$1f): the GUI64
;   timer saves it in WinX/WinY, and the engine only runs while the
;   structure still shows the app window at this position.

!source "gui64.inc.asm"

!zone Constants
WT_CANNON        = 55 ; app window types start at 50
CT_PLAYFIELD     = 50 ; app control types start at 50
ID_MENU_GAME     = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

ENGINE_BASE      = $c000 ; engine is copied here

SPRITE_NO        = 7     ; apps for both designs may use sprites 6 and 7
SPRITE_BIT       = 1 << SPRITE_NO
BALL_COLOR       = CL_WHITE
BOOM_COLOR1      = CL_YELLOW
BOOM_COLOR2      = CL_ORANGE

; Cursor keys (see MicroMoves): key_shifted tells up from down and left
; from right
KEY_CRSR_UD      = $fb
KEY_CRSR_LR      = $f8

; Layout (content coordinates of the window)
PF_X             = 1  ; playfield control
PF_Y             = 2
PF_W             = 36
PF_H             = 15
GROUND_ROW       = PF_H - 1
STATUS_X         = 1  ; status line (label)
STATUS_Y         = 1
STATUS_W         = PF_W

; The city
P1_COL           = 1          ; left columns of the cannons (2x2 chars)
P2_COL           = PF_W - 3
TOWER_W          = 3          ; the towers are 3 columns wide
MAX_TOWER        = 7          ; tower height: 1..MAX_TOWER rows
CITY_L           = TOWER_W + 1        ; buildings in the columns
CITY_R           = PF_W - TOWER_W - 2 ; CITY_L..CITY_R
MIN_BLD_W        = 2          ; buildings are 2..4 columns wide
BLD_W_VAR        = 3
MIN_BLD_H        = 2          ; and 2..9 rows high
BLD_H_VAR        = 8

; Map cells. Screen code = CH_FIRST + cell. A cannon is 2x2 cells
; (top left, top right, bottom left, bottom right), the order matters
; (owner = (cell - M_CANNON1) / 4).
M_SKY            = 0
M_WALL           = 1
M_GROUND         = 2
M_CANNON1        = 3
M_CANNON2        = 7
NUM_CHARS        = 11
CANNON_FRAMES    = 5 ; images of a cannon (angles)
CH_FIRST         = APP_CHAR_0 ; must be a multiple of 8 (ora)

COL_GROUND       = CL_BROWN
COL_P1           = CL_LIGHTGREEN
COL_P2           = CL_ROSE

; Shots. Velocity in 1/256 pixels per frame is
; Power * 160 * sin/cos(Angle) / 16, gravity in 1/256 pixels per frame^2
MAX_ANGLE        = 90
MAX_POWER        = 99
START_ANGLE      = 45
START_POWER      = 60
GRAVITY          = 10

; Game states
ST_AIM           = 0 ; the player whose turn it is aims (window proc)
ST_FLY           = 1 ; the ball flies (engine)
ST_BOOM          = 2 ; hit a building or missed, then the next turn
ST_HIT           = 3 ; hit the other cannon, then a new city
ST_WAIT          = 4 ; waiting for the new city (timer handler)

BOOM_TIME        = 25 ; frames
MISS_TIME        = 15
HIT_TIME         = 100

; Sprite frames (SprFrame)
FR_BALL          = 0
FR_BOOM          = 1
FR_BIGBOOM       = 2
FR_NONE          = $ff

; Offsets in the status text
TX_SCORE1        = 3
TX_MARK1         = 6
TX_ANGLE         = 15
TX_POWER         = 25
TX_MARK2         = 29
TX_SCORE2        = 34

!zone Init
*=$b000
                lda #WT_CANNON                   ; look for window with type "WT_CANNON"
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
                ; Addresses of the map rows
                ldx #0
                lda #<Map
                ldy #>Map
-               sta MapLo,x
                pha
                tya
                sta MapHi,x
                pla
                clc
                adc #PF_W
                bcc +
                iny
+               inx
                cpx #PF_H
                bne -
                ; The first city
                lda $dc04                       ; seed random generator
                ora #1                          ; (must not be 0)
                sta Seed
                lda $dc05
                sta Seed+1
                jsr NewRound
                jsr UpdateGuns                  ; registers the chars
                ;
                ldx #<CtrlAction                ; Behavior of the playfield
                ldy #>CtrlAction                ; (void, events are handled
                jsr GUI_SetCtrlActionsRoutine   ; in the window proc)
                ldx #<PaintCtrls                ; Look of the
                ldy #>PaintCtrls                ; playfield
                jsr GUI_SetPaintCtrlsRoutine    ;
                ;
                ldx #<Wnd_Cannon                 ; Create the window with
                ldy #>Wnd_Cannon                 ; its controls
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
                ldx #<Str_CannonMenubar          ; strings with control 0
                ldy #>Str_CannonMenubar          ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                ; The label shows the status text of the engine
                jsr GUI_SelectControl1
                ldx #<StatusText
                ldy #>StatusText
                jsr GUI_SetCtrlString
                jsr TrackWindow                 ; window position for the engine
                ldx #<TimerProc                 ; and keep it up to date
                ldy #>TimerProc                 ; (every 1/10 second)
                jsr GUI_InitTimer
                jsr GUI_StartTimer
                jmp EngineStart

; Timer handler (GUI64 main loop, not IRQ): saves the window position
; for the engine and builds a new city when the engine asks for it
TimerProc       jsr TrackWindow
                lda RoundReq
                beq +
                lda WindowType                  ; only while the window is
                cmp #WT_CANNON                   ; current (it is repainted)
                bne +
                lda ProgramMode                 ; and no menu or dialog is
                bne +                           ; open
                jsr NewRound
                lda #0
                sta RoundReq
                lda #1
                sta StatusReq
                jsr GUI_RepaintCurWindow        ; the new colors
                lda #ST_AIM                     ; and the next shot
                sta State
+               rts

; If the app window is the current window, its position is saved for
; the engine
TrackWindow     lda WindowType
                cmp #WT_CANNON
                bne +
                lda WindowPosX
                sta WinX
                lda WindowPosY
                sta WinY
+               rts

; Window Proc (event handler for window)
CannonWndProc   jsr GUI_StdWndProc              ; MUST always be called
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
                bne .leave
                lda State                       ; keys only while aiming
                cmp #ST_AIM
                bne .leave
                ldx Turn
                lda actkey
                cmp #KEY_CRSR_UD
                bne .notUD
                lda key_shifted
                beq .down
                lda Angle,x                     ; CRSR up: steeper
                cmp #MAX_ANGLE
                bcs .leave
                inc Angle,x
                bcc .angle                      ; jmp
.down           lda Angle,x                     ; CRSR down: flatter
                beq .leave
                dec Angle,x
.angle          jsr UpdateGuns
                jmp .status
.notUD          cmp #KEY_CRSR_LR
                bne .notLR
                lda key_shifted
                beq .right
                lda Power,x                     ; CRSR left: less power
                cmp #2
                bcc .leave
                dec Power,x
                bcs .status                     ; jmp
.right          lda Power,x                     ; CRSR right: more power
                cmp #MAX_POWER
                bcs .leave
                inc Power,x
.status         lda #1                          ; the engine updates the
                sta StatusReq                   ; status line
                rts
.notLR          cmp #" "                        ; SPACE fires
                bne .leave
                jmp Fire
.leave          rts

; Invoked when an item in the game menu was clicked
GameMenuClicked lda CurMenuItem                 ; 0: New
                bne +
                php                             ; (the engine must not run
                sei                             ; in between)
                lda #0
                sta Score
                sta Score+1
                sta Turn
                lda #FR_NONE
                sta SprFrame
                lda #ST_WAIT                    ; the timer handler builds
                sta State                       ; a new city
                lda #1
                sta RoundReq
                sta StatusReq
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

; Starts the engine (GUI64's frame handler)
EngineStart     jsr GUI_GetScreenMem            ; high byte of the screen
                sta ScreenHi                    ; (MAC: $e0, WIN: $e4)
                ldx #<FrameHandler              ; FrameHandler runs once
                ldy #>FrameHandler              ; per frame from now on
                jsr GUI_SetFrameHandler
                jmp GUI_StartFrameHandling

; X is ControlType
CtrlAction      rts                             ; Must be provided if new controls are registered

; X is ControlType
; FDFE points to position of control in paint buffer
; 0203 points to position of control in color buffer
; Must not use any variables or code of the engine (the engine's IRQ
; can interrupt GUI64's repaint).
PaintCtrls      cpx #CT_PLAYFIELD
                beq +
                rts
+               lda #0
                sta PaintRow
.row            ldx PaintRow
                lda MapLo,x
                sta .map+1
                lda MapHi,x
                sta .map+2
                ldy #PF_W-1
.map            lda $ffff,y                     ; address is patched
                tax
                ora #CH_FIRST
                sta (ZP_FD),y
                lda CellColor,x
                bpl +
                lda BldCol,y                    ; walls: color of the building
+               sta ($02),y
                dey
                bpl .map
                lda PaintRow
                cmp #PF_H-1
                beq +
                inc PaintRow
                jsr GUI_AddBufWidthToFD
                jsr GUI_AddBufWidthTo02
                jmp .row
+               rts

;----------------------------------------------------------------------
; Aiming and firing (main loop)

; Copies the cannons for the angles of both players into CharList and
; registers the chars
UpdateGuns      lda Angle                       ; player 1
                jsr AngleFrame
                jsr FrameOffset
                ldx #0
-               lda CannonTab1,y
                sta CharList+M_CANNON1*8,x
                iny
                inx
                cpx #32
                bne -
                lda Angle+1                     ; player 2
                jsr AngleFrame
                jsr FrameOffset
                ldx #0
-               lda CannonTab2,y
                sta CharList+M_CANNON2*8,x
                iny
                inx
                cpx #32
                bne -
                ldx #<CharList
                ldy #>CharList
                lda #NUM_CHARS
                jmp GUI_RegisterChars

; A = angle (0..90) -> A = Y = image of the cannon (0..CANNON_FRAMES-1).
; X is preserved.
AngleFrame      ldy #0
-               cmp FrameLimit,y
                bcc +
                iny
                cpy #CANNON_FRAMES-1
                bne -
+               tya
                rts

; A = image -> Y = its offset in CannonTab1/2 (32 bytes per image)
FrameOffset     asl
                asl
                asl
                asl
                asl
                tay
                rts

; Fires the ball of the current player
Fire            ldx Turn                        ; start at the muzzle
                lda Angle,x
                jsr AngleFrame
                cpx #1                          ; (player 2: the mirrored
                bcc +                           ; muzzles)
                adc #CANNON_FRAMES-1            ; (C=1)
+               sta Muzzle
                lda GunRow,x                    ; y = row * 8 + MuzzleY
                asl
                asl
                asl
                ldy Muzzle
                clc
                adc MuzzleY,y
                sta BY1
                lda #0
                sta BY2
                sta BX2
                lda #$80
                sta BX0
                sta BY0
                lda GunCol,x                    ; x = col * 8 + MuzzleX
                sta BX1
                asl BX1
                rol BX2
                asl BX1
                rol BX2
                asl BX1
                rol BX2
                lda BX1
                ldy Muzzle
                clc
                adc MuzzleX,y
                sta BX1
                bcc +
                inc BX2
+
                ; vx = Power * cos(Angle) (to the other player)
                lda #MAX_ANGLE
                sec
                sbc Angle,x
                tay
                lda SinTab,y
                jsr MulPower
                sta VXL
                stx VXH
                ldx Turn                        ; player 2 shoots to the left
                beq +
                lda #0
                sec
                sbc VXL
                sta VXL
                lda #0
                sbc VXH
                sta VXH
+               ; vy = -Power * sin(Angle) (up)
                ldx Turn
                ldy Angle,x
                lda SinTab,y
                jsr MulPower
                sta MulA
                lda #0
                sec
                sbc MulA
                sta VYL
                lda #0
                stx MulA
                sbc MulA
                sta VYH
                lda #FR_BALL
                sta SprFrame
                lda #ST_FLY                     ; the engine takes over
                sta State
                rts

; A = table value (0..160) -> A/X = lo/hi of A * Power / 16 of the
; current player
MulPower        sta MulB
                ldx Turn
                lda Power,x
                sta MulA
                lda #0                          ; MulA * MulB -> A (hi), MulA (lo)
                ldx #8
                lsr MulA
-               bcc +
                clc
                adc MulB
+               ror
                ror MulA
                dex
                bne -
                ldx #4                          ; / 16
-               lsr
                ror MulA
                dex
                bne -
                tax
                lda MulA
                rts

;----------------------------------------------------------------------
; A new city (main loop): new heights for the cannons and new buildings
NewRound        ldx #0                          ; sky, and the ground in
.clear          lda MapLo,x                     ; the bottom row
                sta ZP_FB
                lda MapHi,x
                sta ZP_FC
                lda #M_SKY
                cpx #GROUND_ROW
                bne +
                lda #M_GROUND
+               ldy #PF_W-1
-               sta (ZP_FB),y
                dey
                bpl -
                inx
                cpx #PF_H
                bne .clear
                ; The towers with the cannons
                ldx #0
.tower          stx Player
-               lda #MAX_TOWER                  ; a new height: 1..MAX_TOWER,
                jsr RandMod                     ; not the old one
                clc
                adc #1
                cmp TowerH,x
                beq -
                sta TowerH,x
                lda #GROUND_ROW
                sec
                sbc TowerH,x
                sta FillTop
                sec
                sbc #2
                sta GunRow,x
                lda TowerL,x
                sta FillCol
                lda #TOWER_W
                sta Count
-               lda #M_GROUND
                jsr FillColumn
                inc FillCol
                dec Count
                bne -
                ldx Player                      ; the cannon on top
                lda GunCol,x
                sta FillCol
                lda CannonCell,x
                ldy GunRow,x
                jsr PutCell                     ; top left
                inc FillCol
                clc
                adc #1
                jsr PutCell                     ; top right
                dec FillCol
                iny
                adc #1
                jsr PutCell                     ; bottom left
                inc FillCol
                adc #1
                jsr PutCell                     ; bottom right
                ldx Player
                inx
                cpx #2
                bne .tower
                ; The buildings
                lda #CITY_L
                sta FillCol
.building       lda #BLD_W_VAR                  ; width
                jsr RandMod
                clc
                adc #MIN_BLD_W
                sta Count
                lda #BLD_H_VAR                  ; height
                jsr RandMod
                clc
                adc #MIN_BLD_H
                sta FillTop
                lda #GROUND_ROW
                sec
                sbc FillTop
                sta FillTop
                jsr Random                      ; color
                and #3
                tax
                lda BldColors,x
                sta BldColor
-               ldx FillCol
                cpx #CITY_R+1
                bcs .done
                lda BldColor
                sta BldCol,x
                lda #M_WALL
                jsr FillColumn
                inc FillCol
                dec Count
                bne -
                jsr Random                      ; a gap of 0 or 1 columns
                and #1
                clc
                adc FillCol
                sta FillCol
                jmp .building
.done           rts

; Fills column FillCol from row FillTop down to the ground with cell A
FillColumn      ldy FillTop
-               cpy #GROUND_ROW
                bcs +
                jsr PutCell
                iny
                bne -                           ; jmp
+               rts

; Puts cell A into column FillCol, row Y (A and Y are preserved)
PutCell         pha
                lda MapLo,y
                sta ZP_FB
                lda MapHi,y
                sta ZP_FC
                sty CellRow
                ldy FillCol
                pla
                sta (ZP_FB),y
                ldy CellRow
                rts

; 16 bit Galois LFSR, returns random byte in A. X and Y are preserved.
Random          lsr Seed+1
                ror Seed
                bcc +
                lda Seed+1
                eor #$b4
                sta Seed+1
+               lda Seed
                rts

; A random number 0..A-1 (X and Y are preserved)
RandMod         sta ModVal
                jsr Random
                sec
-               sbc ModVal
                bcs -
                adc ModVal
                rts

!zone Data
; Variables of the main loop (not used by the engine)
PaintRow        !byte 0
Seed            !word 1
ModVal          !byte 0
MulA            !byte 0
MulB            !byte 0
Player          !byte 0
FillCol         !byte 0
FillTop         !byte 0
Count           !byte 0
CellRow         !byte 0
BldColor        !byte 0
TowerH          !byte 0, 0

; Per player
TowerL          !byte 0, PF_W - TOWER_W         ; left column of the tower
GunCol          !byte P1_COL, P2_COL
CannonCell      !byte M_CANNON1, M_CANNON2      ; first cell of the cannon

; Per image of the cannon: the smallest angle of the next image, and the
; muzzle (pixels from the top left of the cannon) of player 1 and 2
FrameLimit      !byte 14, 37, 56, 78
MuzzleX         !byte 15, 14, 11, 7, 3
                !byte 0, 1, 4, 8, 12
MuzzleY         !byte 10, 5, 2, 1, 1
                !byte 10, 5, 2, 1, 1
Muzzle          !byte 0

; Colors of the cells ($ff: color of the building in the column)
CellColor       !byte CL_BLACK, $ff, COL_GROUND
                !byte COL_P1, COL_P1, COL_P1, COL_P1
                !byte COL_P2, COL_P2, COL_P2, COL_P2
BldColors       !byte CL_LIGHTGRAY, CL_CYAN, CL_MIDGRAY, CL_LIGHTBLUE

; 160 * sin(angle), angle = 0..90 degrees
SinTab          !byte 0,3,6,8,11,14,17,19,22,25,28,31,33,36,39,41
                !byte 44,47,49,52,55,57,60,63,65,68,70,73,75,78,80,82
                !byte 85,87,89,92,94,96,99,101,103,105,107,109,111,113,115,117
                !byte 119,121,123,124,126,128,129,131,133,134,136,137,139,140,141,143
                !byte 144,145,146,147,148,149,150,151,152,153,154,155,155,156,157,157
                !byte 158,158,158,159,159,159,160,160,160,160,160

Str_Title_App   !pet "Cannonball",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_Cannon      !byte WT_CANNON, %00100001, 1, 2, PF_W + 2, PF_Y + PF_H + 3, <Str_Title_App, >Str_Title_App
                !byte <CannonWndProc, >CannonWndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
                ;0
                !byte CT_MENUBAR, <CannonMenubar, >CannonMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL, STATUS_X, STATUS_Y, STATUS_W, 1
                !pet 0
                ;2
                !byte CT_PLAYFIELD, PF_X, PF_Y, PF_W, PF_H
                !pet 0
                ; closing zero byte
                !byte 0

; Strings
Str_Mess_Help   !pet "CRSR up/down: angle\CRSR left/right: power\SPACE: fire\Hit the other cannon!",0
Str_Mess_About  !pet "Cannonball\A game for two players\for GUI64",0

; Definition of menu bar
CannonMenubar   !word Menu_Cannon_Game, Menu_Cannon_Help
Str_CannonMenubar !pet "Game",0,"?",0
; Definitions of menus
; Format: ID, max_str_len, item_count, StringList
Menu_Cannon_Game !pet ID_MENU_GAME,4,2,"New",0,"Quit",0
Menu_Cannon_Help !pet ID_MENU_HELP,5,2,"Help",0,"About",0

; App chars (the cannons are copied in from CannonTab1/2). Set pixels
; have the color of the cell (see CellColor), the background is black.
CharList        !byte $00,$00,$00,$00,$00,$00,$00,$00 ; sky
                !byte $ff,$99,$99,$ff,$ff,$99,$99,$ff ; wall with windows
                !byte $f7,$f7,$f7,$00,$7f,$7f,$7f,$00 ; ground (bricks)
                !fill 2 * 4 * 8, 0                    ; cannons 1 and 2
CharListEnd
!if (CharListEnd - CharList) != (NUM_CHARS * 8) {
!error "CharList must hold NUM_CHARS chars"
}

; Cannons, 2x2 chars per image
CannonTab1      ; player 1: 0, 27, 45, 65, 90 degrees
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 0: top left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 0: top right
                !byte $fc,$fe,$c6,$fe,$fe,$fe,$fe,$fe ; 0: bottom left
                !byte $00,$fe,$fe,$fe,$00,$00,$00,$00 ; 0: bottom right
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 1: top left
                !byte $00,$00,$00,$00,$0c,$3e,$fc,$f0 ; 1: top right
                !byte $fc,$fe,$c6,$fe,$fe,$fe,$fe,$fe ; 1: bottom left
                !byte $c0,$00,$00,$00,$00,$00,$00,$00 ; 1: bottom right
                !byte $00,$00,$00,$00,$00,$01,$03,$01 ; 2: top left
                !byte $00,$00,$30,$70,$e0,$c0,$80,$00 ; 2: top right
                !byte $fc,$fe,$c6,$fe,$fe,$fe,$fe,$fe ; 2: bottom left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 2: bottom right
                !byte $00,$03,$03,$07,$07,$0e,$0e,$00 ; 3: top left
                !byte $00,$00,$80,$00,$00,$00,$00,$00 ; 3: top right
                !byte $fc,$fe,$c6,$fe,$fe,$fe,$fe,$fe ; 3: bottom left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 3: bottom right
                !byte $00,$38,$38,$38,$38,$38,$38,$00 ; 4: top left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 4: top right
                !byte $fc,$fe,$c6,$fe,$fe,$fe,$fe,$fe ; 4: bottom left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 4: bottom right
CannonTab2      ; player 2: player 1 mirrored
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 0: top left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 0: top right
                !byte $00,$7f,$7f,$7f,$00,$00,$00,$00 ; 0: bottom left
                !byte $3f,$7f,$63,$7f,$7f,$7f,$7f,$7f ; 0: bottom right
                !byte $00,$00,$00,$00,$30,$7c,$3f,$0f ; 1: top left
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 1: top right
                !byte $03,$00,$00,$00,$00,$00,$00,$00 ; 1: bottom left
                !byte $3f,$7f,$63,$7f,$7f,$7f,$7f,$7f ; 1: bottom right
                !byte $00,$00,$0c,$0e,$07,$03,$01,$00 ; 2: top left
                !byte $00,$00,$00,$00,$00,$80,$c0,$80 ; 2: top right
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 2: bottom left
                !byte $3f,$7f,$63,$7f,$7f,$7f,$7f,$7f ; 2: bottom right
                !byte $00,$00,$01,$00,$00,$00,$00,$00 ; 3: top left
                !byte $00,$c0,$c0,$e0,$e0,$70,$70,$00 ; 3: top right
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 3: bottom left
                !byte $3f,$7f,$63,$7f,$7f,$7f,$7f,$7f ; 3: bottom right
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 4: top left
                !byte $00,$1c,$1c,$1c,$1c,$1c,$1c,$00 ; 4: top right
                !byte $00,$00,$00,$00,$00,$00,$00,$00 ; 4: bottom left
                !byte $3f,$7f,$63,$7f,$7f,$7f,$7f,$7f ; 4: bottom right
CannonTabEnd
!if (CannonTabEnd - CannonTab1) != (2 * CANNON_FRAMES * 32) {
!error "CannonTab1/2 must hold CANNON_FRAMES images"
}

;======================================================================
; Engine - runs at $c000, independent of the app code at $b000
;======================================================================
EngineImage
!pseudopc ENGINE_BASE {
!zone Engine
; Sprite data first: pointer = (address - $c000) / 64
SpriteData      ; 0: ball
                !byte %01110000,%00000000,%00000000 ; .XXX....................
                !byte %11111000,%00000000,%00000000 ; XXXXX...................
                !byte %11111000,%00000000,%00000000 ; XXXXX...................
                !byte %11111000,%00000000,%00000000 ; XXXXX...................
                !byte %01110000,%00000000,%00000000 ; .XXX....................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
                ; 1: explosion
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00100000,%00000000 ; ..........X.............
                !byte %00000000,%00100110,%00000000 ; ..........X..XX.........
                !byte %00000000,%00110110,%00000000 ; ..........XX.XX.........
                !byte %00000001,%10111100,%00000000 ; .......XX.XXXX..........
                !byte %00000001,%11111111,%10000000 ; .......XXXXXXXXXX.......
                !byte %00000000,%01111111,%10000000 ; .........XXXXXXXX.......
                !byte %00000000,%01111110,%00000000 ; .........XXXXXX.........
                !byte %00000000,%11111110,%00000000 ; ........XXXXXXX.........
                !byte %00000001,%10011011,%00000000 ; .......XX..XX.XX........
                !byte %00000000,%00011000,%00000000 ; ...........XX...........
                !byte %00000000,%00010000,%00000000 ; ...........X............
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte $00
                ; 2: big explosion
                !byte %00000000,%00000000,%00000000 ; ........................
                !byte %00000001,%00000011,%10000000 ; .......X......XXX.......
                !byte %00000011,%10000111,%10000000 ; ......XXX....XXXX.......
                !byte %00000011,%11000111,%10000000 ; ......XXXX...XXXX.......
                !byte %00000001,%11101111,%00000000 ; .......XXXX.XXXX........
                !byte %00000001,%11111111,%00000000 ; .......XXXXXXXXX........
                !byte %00000001,%10000001,%00000000 ; .......XX......X........
                !byte %00000000,%00111100,%11111100 ; ..........XXXX..XXXXXX..
                !byte %00111110,%01111110,%01111100 ; ..XXXXX..XXXXXX..XXXXX..
                !byte %00111110,%11111111,%01111000 ; ..XXXXX.XXXXXXXX.XXXX...
                !byte %00011110,%11111111,%01100000 ; ...XXXX.XXXXXXXX.XX.....
                !byte %00000010,%11111111,%00000000 ; ......X.XXXXXXXX........
                !byte %00000000,%01111110,%01000000 ; .........XXXXXX..X......
                !byte %00000011,%00111100,%11100000 ; ......XX..XXXX..XXX.....
                !byte %00000111,%10000001,%11110000 ; .....XXXX......XXXXX....
                !byte %00001111,%11111100,%11111000 ; ....XXXXXXXXXX..XXXXX...
                !byte %00001111,%00111100,%00111000 ; ....XXXX..XXXX....XXX...
                !byte %00001100,%00011100,%00000000 ; ....XX.....XXX..........
                !byte %00000000,%00011100,%00000000 ; ...........XXX..........
                !byte %00000000,%00011100,%00000000 ; ...........XXX..........
                !byte %00000000,%00001000,%00000000 ; ............X...........
                !byte $00
SpriteDataEnd
!if (SpriteDataEnd - SpriteData) != (3 * 64) {
!error "SpriteData must hold 3 sprites"
}
SPRITE_PTR0     = (SpriteData - $c000) / 64

; Per sprite frame: offset of the center, color
SprOfsX         !byte 2, 12, 12
SprOfsY         !byte 2, 10, 10
SprRegs         !byte $1b, $1c, $17, $1d

; Status line
StatusText      !pet "P1:00 <  Angle 45  Power 50  > P2:00",0
!if (TX_SCORE2 + 2) != STATUS_W {
!error "StatusText must be STATUS_W chars long"
}

; Frame handler: called by GUI64 once per frame from its raster IRQ
; (line 0, I/O visible, GUI64 saves the registers). It must not call
; GUI64 routines except the IRQ-safe ones.
FrameHandler    jsr GameFrame
                lda $d015                       ; the sprite on or off
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
                cmp #WT_CANNON                   ; current (top) window
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
.pause          lda #0                          ; hide the sprite
                sta SprOn
                rts

;----------------------------------------------------------------------
; Game logic
Update          inc Anim
                lda State
                cmp #ST_FLY
                beq Fly
                cmp #ST_BOOM
                beq .boom
                cmp #ST_HIT
                beq .hit
                rts
.boom           dec Timer                       ; then the other player
                bne .rts
                lda #ST_AIM
                beq .next                       ; jmp (ST_AIM = 0)
.hit            dec Timer                       ; then the other player in
                bne .rts                        ; a new city (see TimerProc)
                lda #1
                sta RoundReq
                lda #ST_WAIT
.next           sta State
                lda Turn
                eor #1
                sta Turn
                lda #FR_NONE
                sta SprFrame
                lda #1
                sta StatusReq
.rts            rts

; Moves the ball and checks what it hit
Fly             lda VYL                         ; gravity
                clc
                adc #GRAVITY
                sta VYL
                bcc +
                inc VYH
+               ldx #0                          ; x += vx (24 bit)
                lda VXH
                bpl +
                dex
+               lda BX0
                clc
                adc VXL
                sta BX0
                lda BX1
                adc VXH
                sta BX1
                txa
                adc BX2
                sta BX2
                ldx #0                          ; y += vy (24 bit)
                lda VYH
                bpl +
                dex
+               lda BY0
                clc
                adc VYL
                sta BY0
                lda BY1
                adc VYH
                sta BY1
                txa
                adc BY2
                sta BY2
                ; Left or right of the playfield?
                lda BX2
                bmi Miss
                cmp #>(PF_W * 8)
                bcc +
                bne Miss
                lda BX1
                cmp #<(PF_W * 8)
                bcs Miss
+               lda BY2                         ; above the playfield: there
                bmi .free                       ; is nothing to hit
                bne Miss
                lda BY1
                cmp #PF_H * 8
                bcs Miss
                lsr                             ; Y = row
                lsr
                lsr
                tay
                lda BX2                         ; X = column
                lsr
                lda BX1
                ror
                lsr
                lsr
                tax
                lda MapLo,y
                sta .cell+1
                sta .break+1
                lda MapHi,y
                sta .cell+2
                sta .break+2
.cell           lda $ffff,x                     ; address is patched
                beq .free                       ; sky
                cmp #M_WALL
                bne +
                lda #M_SKY                      ; a piece of the building
.break          sta $ffff,x                     ; breaks off
                jsr DrawRow
                jmp Boom
+               cmp #M_GROUND
                beq Boom
                sec                             ; a cannon: whose?
                sbc #M_CANNON1
                lsr
                lsr
                cmp Turn
                bne Hit
.free           rts                             ; (the own one)

Miss            lda #FR_NONE
                sta SprFrame
                lda #MISS_TIME
                bne +                           ; jmp
Boom            lda #FR_BOOM
                sta SprFrame
                lda #BOOM_TIME
+               sta Timer
                lda #ST_BOOM
                sta State
                rts

Hit             ldx Turn                        ; a point
                inc Score,x
                lda Score,x
                cmp #100
                bcc +
                lda #0
                sta Score,x
+               lda #1
                sta StatusReq
                lda #FR_BIGBOOM
                sta SprFrame
                lda #HIT_TIME
                sta Timer
                lda #ST_HIT
                sta State
                rts

;----------------------------------------------------------------------
; Drawing (directly into the screen, while the window is on top)
Render          ldy ScrubRow                    ; one row of the map per
                jsr DrawRow                     ; frame (in case GUI64
                ldy ScrubRow                    ; repainted the window with
                iny                             ; an older map)
                cpy #PF_H
                bcc +
                lda #1                          ; and the status line now
                sta StatusReq                   ; and then
                ldy #0
+               sty ScrubRow
                lda StatusReq
                beq +
                lda #0
                sta StatusReq
                jsr DrawStatus
+               ; The sprite
                ldx SprFrame
                bmi .hide
                lda BY2                         ; above the playfield
                beq +
.hide           jmp .off
+
                lda WinX                        ; x = 24 + column * 8 + BX
                clc
                adc #PF_X
                ldy #0
                sty Tmp
                asl
                rol Tmp
                asl
                rol Tmp
                asl
                rol Tmp
                clc
                adc #24
                bcc +
                inc Tmp
+               clc
                adc BX1
                sta Tmp+1
                lda Tmp
                adc BX2
                sta Tmp
                lda Tmp+1
                sec
                sbc SprOfsX,x
                sta $d000+2*SPRITE_NO
                lda Tmp
                sbc #0
                beq +
                lda $d010
                ora #SPRITE_BIT
                bne ++
+               lda $d010
                and #$ff - SPRITE_BIT
++              sta $d010
                lda WinY                        ; y = 50 + row * 8 + BY
                clc
                adc RowOffset
                adc #1 + PF_Y
                asl
                asl
                asl
                clc
                adc #50
                clc
                adc BY1
                sec
                sbc SprOfsY,x
                sta $d001+2*SPRITE_NO
                lda #BALL_COLOR                 ; color
                cpx #FR_BALL
                beq ++
                lda Anim                        ; explosions flicker
                and #4
                beq +
                lda #BOOM_COLOR1
                bne ++                          ; jmp
+               lda #BOOM_COLOR2
++              sta $d027+SPRITE_NO
                txa                             ; sprite frame
                clc
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
.off            lda #0
                sta SprOn
                rts

; Draws row Y of the map
DrawRow         lda MapLo,y
                sta .map+1
                lda MapHi,y
                sta .map+2
                tya
                clc
                adc #PF_Y
                jsr SetRow
                lda RowLo
                clc
                adc #PF_X
                sta .scr+1
                lda RowHi
                adc #0
                sta .scr+2
                ldx #PF_W-1
.map            lda $ffff,x                     ; addresses are patched
                ora #CH_FIRST
.scr            sta $ffff,x
                dex
                bpl .map
                rts

; Writes the numbers of the current player and the scores into the
; status text and draws it
DrawStatus      ldx Score
                ldy #TX_SCORE1
                jsr PutNum
                ldx Score+1
                ldy #TX_SCORE2
                jsr PutNum
                ldy Turn
                ldx Angle,y
                ldy #TX_ANGLE
                jsr PutNum
                ldy Turn
                ldx Power,y
                ldy #TX_POWER
                jsr PutNum
                lda #" "                        ; the marker points at the
                sta StatusText+TX_MARK1         ; current player
                sta StatusText+TX_MARK2
                ldx #TX_MARK1
                lda #"<"
                ldy Turn
                beq +
                ldx #TX_MARK2
                lda #">"
+               sta StatusText,x
                lda #STATUS_Y
                jsr SetRow
                lda RowLo
                clc
                adc #STATUS_X
                sta .txt+1
                lda RowHi
                adc #0
                sta .txt+2
                ldy #STATUS_W-1
-               lda StatusText,y
                jsr PetToScr
.txt            sta $ffff,y                     ; address is patched
                dey
                bpl -
                rts

; Writes X (0..99) as two digits to StatusText+Y
PutNum          txa
                ldx #"0"
-               cmp #10
                bcc +
                sbc #10
                inx
                bne -                           ; jmp
+               ora #"0"
                sta StatusText+1,y
                txa
                sta StatusText,y
                rts

; A = content row of the window -> RowLo/RowHi = screen address of
; its content column 0
SetRow          clc
                adc WinY
                adc RowOffset
                adc #1                          ; title bar
                sta Tmp                         ; screen row * 40:
                asl                             ; row * 5 (< 128) ...
                asl
                adc Tmp
                ldx #0
                stx RowHi
                asl                             ; ... * 8
                rol RowHi
                asl
                rol RowHi
                asl
                rol RowHi                       ; (C=0)
                adc WinX
                sta RowLo
                lda RowHi
                adc ScreenHi
                sta RowHi
                rts

; PETSCII in A -> GUI64 screen code in A (X and Y are preserved)
PetToScr        cmp #$c0
                bcc +
                sbc #$40                        ; $c0-$df -> $80-$9f
                rts
+               ora #$80                        ; $20-$5f -> $a0-$df
                rts

;----------------------------------------------------------------------
; Variables of the engine. Also written by the main loop: only while
; the engine doesn't use them (State) or single bytes as requests.
RowOffset       !byte 0 ; content row 0 = window y + RowOffset + 1
WinX            !byte 0
WinY            !byte 0
ScreenHi        !byte 0 ; high byte of the screen (GUI_GetScreenMem)
SprOn           !byte 0
SprFrame        !byte FR_NONE
State           !byte ST_AIM
Turn            !byte 0 ; 0: player 1, 1: player 2
Angle           !byte START_ANGLE, START_ANGLE
Power           !byte START_POWER, START_POWER
Score           !byte 0, 0
GunRow          !byte 0, 0 ; map row of the barrels
StatusReq       !byte 1 ; draw the status line
RoundReq        !byte 0 ; build a new city (TimerProc)
Timer           !byte 0
Anim            !byte 0
ScrubRow        !byte 0
BX0             !byte 0 ; ball x in 1/256 pixels (24 bit)
BX1             !byte 0
BX2             !byte 0
BY0             !byte 0 ; ball y in 1/256 pixels (24 bit, signed)
BY1             !byte 0
BY2             !byte 0
VXL             !word 0 ; velocity in 1/256 pixels per frame
VXH = VXL + 1
VYL             !word 0
VYH = VYL + 1
RowLo           !byte 0
RowHi           !byte 0
Tmp             !word 0
EngineEnd
; Not part of the image (initialized by the app)
Map             = EngineEnd             ; PF_H rows of PF_W cells
BldCol          = Map + PF_W * PF_H     ; color of the building per column
MapLo           = BldCol + PF_W         ; addresses of the map rows
MapHi           = MapLo + PF_H
EngineBssEnd    = MapHi + PF_H
!if EngineBssEnd > $d000 {
!error "Engine overlaps the charset at $d000"
}
}
EngineImageEnd
ENGINE_PAGES    = (EngineEnd - ENGINE_BASE + 255) / 256
!if EngineImageEnd > ENGINE_BASE {
!error "App and engine image overlap the engine at $c000"
}

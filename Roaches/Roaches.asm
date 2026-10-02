!to "Roaches.d64",d64,"roaches.gui","roaches disk"

; Roaches - a fun app for GUI64
;
; Black cockroaches live under the app window. Move the window and
; they run for cover under it again. Now and then one of them sneaks
; out to have a look around. Minimize the window (or switch to another
; one) and they panic.
;
; How it works:
; * The roaches are sprites, starting with sprite 7 downwards. GUI64
;   uses 0 and 1 for the mouse, and in the WIN design 2-5 for the
;   taskbar logo. So there are 4 roaches (sprites 7-4) in the MAC design
;   and 2 (sprites 7 and 6) in the WIN design.
; * They are moved by GUI64's frame handler (GUI_SetFrameHandler,
;   called from GUI64's raster IRQ), so they move smoothly at 50 frames
;   per second.
; * The frame handler and the sprite data ("engine") are copied to
;   $c000, which is in the VIC bank of GUI64 ($c000-$ffff) and belongs to
;   the app area.
; * The app only uses the GUI64 API (gui64.inc.asm). The rectangle of
;   the app window comes from the current-window structure ($10-$1f),
;   read by the GUI64 timer (GUI64 main loop, every 1/10 second): in the
;   IRQ, GUI64 may just be copying another window into it. The roaches
;   only hide under the window while it is the current window: if it is
;   minimized or another window is activated, they panic.
; * On EC_SHUTDOWN (the window is closed), the timer and the frame
;   handling are stopped and the sprites are switched off.

!source "gui64.inc.asm"

!zone Constants
WT_ROACHES       = 52 ; app window types start at 50
ID_BTN_BYE       = 2  ; control index of the button
ID_MENU_FILE     = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

ENGINE_BASE      = $c000 ; engine is copied here

MAX_ROACHES      = 4 ; MAC design (sprites 7-4)
WIN_ROACHES      = 2 ; WIN design (sprites 7 and 6, see above)
ROACH_COLOR      = CL_BLACK
MAX_Y_MAC        = 234 ; lowest sprite y (16 pixel roach on the screen)
MAX_Y_WIN        = 204 ; sprite must end before the taskbar (line 226)

; Roach states
ST_HOME          = 0 ; running to its hiding place under the window
ST_IDLE          = 1 ; hidden under the window
ST_WANDER        = 2 ; exploring the screen

!zone Init
*=$b000
                lda #WT_ROACHES                 ; look for window with type "WT_ROACHES"
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
                ldx #<Wnd_Roaches               ; Create the window with
                ldy #>Wnd_Roaches               ; its controls
                jsr GUI_CreateWindowEx          ;
                lda #0                          ; WIN: the window y
                sta RowOffset                   ; holds screen rows
                lda #WIN_ROACHES - 1
                sta LastRoach
                lda #%11000000                  ; sprites 7 and 6
                sta SprMask
                lda #MAX_Y_WIN
                sta MaxY
                jsr GUI_GetDesign               ; Z=1: WIN, Z=0: MAC
                beq +                           ;
                ; MAC
                lda #MAX_ROACHES - 1
                sta LastRoach
                lda #%11110000                  ; sprites 7-4
                sta SprMask
                lda #MAX_Y_MAC
                sta MaxY
                inc RowOffset                   ; MAC: rows below the menu bar
                inc WindowPosY                  ; increment Y coord of app window
                dec WindowHeight                ; decrement height of app window
                jsr GUI_UpdateWindow            ; confirm window changes
                ldy #ID_BTN_BYE                 ; set ID and
                lda #BIT_CTRL_DBLFRAME_RGT + BIT_CTRL_DBLFRAME_BTM
                jsr GUI_SelectCtrl_AddBits      ; add bits to the button
                inc ControlPosX                 ; increment X coord of button
                jsr GUI_UpdateControl           ; confirm control changes
+               ; Menu
                jsr GUI_SelectControl0          ; Associate the menu bar
                ldx #<Str_RMenubar              ; strings with control 0
                ldy #>Str_RMenubar              ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                jsr TrackWindow                 ; window rectangle for the
                ldx #<TrackWindow               ; engine, kept up to date
                ldy #>TrackWindow               ; (every 1/10 second)
                jsr GUI_InitTimer
                jsr GUI_StartTimer
                jsr EngineStart                 ; release the roaches
                ldx #<RoachFrame                ; and let them run
                ldy #>RoachFrame                ; in every frame
                jsr GUI_SetFrameHandler
                jmp GUI_StartFrameHandling

; Timer handler (GUI64 main loop, not IRQ): the rectangle of the app
; window for the engine. Only the current window is in the zero page,
; so if it's another one, the roaches have no shelter.
TrackWindow     lda WindowType
                cmp #WT_ROACHES
                beq +
                lda #BIT_WND_ISMINIMIZED        ; not the current window
                sta Cur
                rts
+               php                             ; the engine must not see
                sei                             ; half of the rectangle
                lda WindowBits
                and #BIT_WND_ISMINIMIZED
                sta Cur
                lda WindowPosX
                sta Cur+1
                lda WindowPosY
                sta Cur+2
                lda WindowWidth
                sta Cur+3
                lda WindowHeight
                sta Cur+4
                plp
                rts

; Window Proc (event handler for window)
RoachesWndProc  jsr GUI_StdWndProc              ; MUST always be called
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
                cmp #ID_MENU_FILE               ;
                beq .quit                       ; File: Quit (only item)
                jmp HelpMenuClicked             ;
.normal         lda wndParam0                   ; event code
                cmp #EC_LBTNRELEASE             ; left mouse button released?
                bne .leave
                jsr GUI_IsInCurControl          ; mouse in a control?
                bcc .leave
                lda ControlIndex
                cmp #ID_BTN_BYE                 ; the button?
                bne .leave
.quit           jsr GUI_KillCurWindow           ; kill the app window (sends
                jmp GUI_Repaint                 ; EC_SHUTDOWN, see above)
.leave          rts

; Invoked when an item in the help menu was clicked
HelpMenuClicked lda CurMenuItem
                bne +
                ldx #<Str_Mess_Help             ; 0: Help
                ldy #>Str_Mess_Help
                jmp GUI_ShowMessage
+               ldx #<Str_Mess_About            ; 1: About
                ldy #>Str_Mess_About
                jmp GUI_ShowMessage

!zone Data
Str_Title_App   !pet "Roaches",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_Roaches     !byte WT_ROACHES, %00100001, 10, 9, 20, 9, <Str_Title_App, >Str_Title_App
                !byte <RoachesWndProc, >RoachesWndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
                ;0
                !byte CT_MENUBAR, <RMenubar, >RMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL_ML, 1, 1, 18, 2
                !pet "Something lives\under this window.",0
                ;2
                !byte CT_BUTTON, 6, 3, 7, 3
                !pet " Bye ",0
                ; closing zero byte
                !byte 0

; Strings
Str_Mess_Help   !pet "Move the window:\the roaches hide\under it again.\Minimize it or\switch windows:\they panic.",0
Str_Mess_About  !pet "Roaches\A fun app\for GUI64",0

; Definition of menu bar
RMenubar        !word Menu_R_File, Menu_R_Help
Str_RMenubar    !pet "File",0,"?",0
; Definition of menus
; Format: ID, max_str_len, item_count, StringList
Menu_R_File     !pet ID_MENU_FILE,4,1,"Quit",0
Menu_R_Help     !pet ID_MENU_HELP,5,2,"Help",0,"About",0

;======================================================================
; Engine - runs at $c000, independent of the app code at $b000
;======================================================================
EngineImage
!pseudopc ENGINE_BASE {
!zone Engine
; Sprite data first: the sprite pointers are (address - $c000) / 64 = 0..7
SpriteData
;------------------------------------------
; File Roaches_sprites.asm
; Cockroach sprites (16x16 in a 24x21 sprite, generated).
; 4 directions (up, right, down, left) x 2 walking poses
;------------------------------------------
; up A
;   ...X........X...
;   ....X......X....
;   .....X....X.....
;   ......XXXX......
;   .X...XXXXXX.....
;   ..XXXXXXXXXXX...
;   .....XXXXXX..X..
;   X....XXXXXX.....
;   .XXXXXXXXXXXXX..
;   .....XXXXXX...X.
;   .X...XXXXXX.....
;   ..XXXXXXXXXXX...
;   .....XXXXXX..X..
;   ......XXXX....X.
;   ......XXXX......
;   .......XX.......
                !byte $10,$08,$00,$08,$10,$00,$04,$20,$00,$03,$c0,$00,$47,$e0,$00,$3f
                !byte $f8,$00,$07,$e4,$00,$87,$e0,$00,$7f,$fc,$00,$07,$e2,$00,$47,$e0
                !byte $00,$3f,$f8,$00,$07,$e4,$00,$03,$c2,$00,$03,$c0,$00,$01,$80,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; up B
;   ...X........X...
;   ....X......X....
;   .....X....X.....
;   ......XXXX......
;   .....XXXXXX...X.
;   ...XXXXXXXXXXX..
;   ..X..XXXXXX.....
;   .....XXXXXX....X
;   ..XXXXXXXXXXXXX.
;   .X...XXXXXX.....
;   .....XXXXXX...X.
;   ...XXXXXXXXXXX..
;   ..X..XXXXXX.....
;   .X....XXXX......
;   ......XXXX......
;   .......XX.......
                !byte $10,$08,$00,$08,$10,$00,$04,$20,$00,$03,$c0,$00,$07,$e2,$00,$1f
                !byte $fc,$00,$27,$e0,$00,$07,$e1,$00,$3f,$fe,$00,$47,$e0,$00,$07,$e2
                !byte $00,$1f,$fc,$00,$27,$e0,$00,$43,$c0,$00,$03,$c0,$00,$01,$80,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; right A
;   ........X.......
;   .....X.X...X....
;   ....X..X..X.....
;   ....X..X..X....X
;   ....X..X..X...X.
;   ...XXXXXXXXX.X..
;   .XXXXXXXXXXXX...
;   XXXXXXXXXXXXX...
;   XXXXXXXXXXXXX...
;   .XXXXXXXXXXXX...
;   ...XXXXXXXXX.X..
;   ....X..X..X...X.
;   ....X..X..X....X
;   ...X...X.X......
;   ..X...X.........
;   ................
                !byte $00,$80,$00,$05,$10,$00,$09,$20,$00,$09,$21,$00,$09,$22,$00,$1f
                !byte $f4,$00,$7f,$f8,$00,$ff,$f8,$00,$ff,$f8,$00,$7f,$f8,$00,$1f,$f4
                !byte $00,$09,$22,$00,$09,$21,$00,$11,$40,$00,$22,$00,$00,$00,$00,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; right B
;   ................
;   ..X...X.........
;   ...X...X.X......
;   ....X..X..X....X
;   ....X..X..X...X.
;   ...XXXXXXXXX.X..
;   .XXXXXXXXXXXX...
;   XXXXXXXXXXXXX...
;   XXXXXXXXXXXXX...
;   .XXXXXXXXXXXX...
;   ...XXXXXXXXX.X..
;   ....X..X..X...X.
;   ....X..X..X....X
;   ....X..X..X.....
;   .....X.X...X....
;   ........X.......
                !byte $00,$00,$00,$22,$00,$00,$11,$40,$00,$09,$21,$00,$09,$22,$00,$1f
                !byte $f4,$00,$7f,$f8,$00,$ff,$f8,$00,$ff,$f8,$00,$7f,$f8,$00,$1f,$f4
                !byte $00,$09,$22,$00,$09,$21,$00,$09,$20,$00,$05,$10,$00,$00,$80,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; down A
;   .......XX.......
;   ......XXXX......
;   .X....XXXX......
;   ..X..XXXXXX.....
;   ...XXXXXXXXXXX..
;   .....XXXXXX...X.
;   .X...XXXXXX.....
;   ..XXXXXXXXXXXXX.
;   .....XXXXXX....X
;   ..X..XXXXXX.....
;   ...XXXXXXXXXXX..
;   .....XXXXXX...X.
;   ......XXXX......
;   .....X....X.....
;   ....X......X....
;   ...X........X...
                !byte $01,$80,$00,$03,$c0,$00,$43,$c0,$00,$27,$e0,$00,$1f,$fc,$00,$07
                !byte $e2,$00,$47,$e0,$00,$3f,$fe,$00,$07,$e1,$00,$27,$e0,$00,$1f,$fc
                !byte $00,$07,$e2,$00,$03,$c0,$00,$04,$20,$00,$08,$10,$00,$10,$08,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; down B
;   .......XX.......
;   ......XXXX......
;   ......XXXX....X.
;   .....XXXXXX..X..
;   ..XXXXXXXXXXX...
;   .X...XXXXXX.....
;   .....XXXXXX...X.
;   .XXXXXXXXXXXXX..
;   X....XXXXXX.....
;   .....XXXXXX..X..
;   ..XXXXXXXXXXX...
;   .X...XXXXXX.....
;   ......XXXX......
;   .....X....X.....
;   ....X......X....
;   ...X........X...
                !byte $01,$80,$00,$03,$c0,$00,$03,$c2,$00,$07,$e4,$00,$3f,$f8,$00,$47
                !byte $e0,$00,$07,$e2,$00,$7f,$fc,$00,$87,$e0,$00,$07,$e4,$00,$3f,$f8
                !byte $00,$47,$e0,$00,$03,$c0,$00,$04,$20,$00,$08,$10,$00,$10,$08,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; left A
;   ................
;   .........X...X..
;   ......X.X...X...
;   X....X..X..X....
;   .X...X..X..X....
;   ..X.XXXXXXXXX...
;   ...XXXXXXXXXXXX.
;   ...XXXXXXXXXXXXX
;   ...XXXXXXXXXXXXX
;   ...XXXXXXXXXXXX.
;   ..X.XXXXXXXXX...
;   .X...X..X..X....
;   X....X..X..X....
;   .....X..X..X....
;   ....X...X.X.....
;   .......X........
                !byte $00,$00,$00,$00,$44,$00,$02,$88,$00,$84,$90,$00,$44,$90,$00,$2f
                !byte $f8,$00,$1f,$fe,$00,$1f,$ff,$00,$1f,$ff,$00,$1f,$fe,$00,$2f,$f8
                !byte $00,$44,$90,$00,$84,$90,$00,$04,$90,$00,$08,$a0,$00,$01,$00,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; left B
;   .......X........
;   ....X...X.X.....
;   .....X..X..X....
;   X....X..X..X....
;   .X...X..X..X....
;   ..X.XXXXXXXXX...
;   ...XXXXXXXXXXXX.
;   ...XXXXXXXXXXXXX
;   ...XXXXXXXXXXXXX
;   ...XXXXXXXXXXXX.
;   ..X.XXXXXXXXX...
;   .X...X..X..X....
;   X....X..X..X....
;   ......X.X...X...
;   .........X...X..
;   ................
                !byte $01,$00,$00,$08,$a0,$00,$04,$90,$00,$84,$90,$00,$44,$90,$00,$2f
                !byte $f8,$00,$1f,$fe,$00,$1f,$ff,$00,$1f,$ff,$00,$1f,$fe,$00,$2f,$f8
                !byte $00,$44,$90,$00,$84,$90,$00,$02,$88,$00,$00,$44,$00,$00,$00,$00
                !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00

; Called from the app after the window was created
EngineStart     jsr GUI_GetScreenMem            ; sprite pointers are at the
                clc                             ; end of the screen
                adc #>$03f8
                sta SprPtrStore+2
                lda $dc04                       ; seed random generator
                ora #1                          ; (must not be 0)
                sta Seed
                lda $dc05
                sta Seed+1
                lda #$ff                        ; force RectChanged
                sta Last+1                      ; in the first frame
                ldx LastRoach
-               jsr NewWanderTarget             ; start at random
                lda TXLO,x                      ; positions on the screen
                sta RXLO,x
                lda TXHI,x
                sta RXHI,x
                lda TY,x
                sta RY,x
                lda #ST_HOME
                sta STATE,x
                txa                             ; start one after
                asl                             ; the other
                asl
                asl
                asl
                sta PAUSE,x
                jsr Random
                and #3
                sta DIR,x
                dex
                bpl -
                rts

; Stops the frame handler and switches the sprites off. Called on
; EC_SHUTDOWN.
StopEngine      jsr GUI_StopFrameHandling       ; (IRQ-safe)
                lda SprMask
                eor #$ff
                and $d015
                sta $d015
                rts

;----------------------------------------------------------------------
; Frame handler: called by GUI64 once per frame from its raster IRQ
; (line 0, I/O visible, GUI64 saves the registers). It must not call
; GUI64 routines except the IRQ-safe ones.
RoachFrame      ldx #4                          ; window moved or resized?
-               lda Cur,x                       ; (Cur: see TrackWindow)
                cmp Last,x
                bne .changed
                dex
                bpl -
                bmi .wander                     ; jmp
.changed        ldx #4
-               lda Cur,x
                sta Last,x
                dex
                bpl -
                jsr RectChanged
.wander         ; Now and then, a roach sneaks out
                dec FrameCnt
                bne .roaches
                jsr Random
                bmi .roaches                    ; 50%
                jsr Random
                and LastRoach                   ; (1 or 3)
                tax
                lda STATE,x
                cmp #ST_IDLE
                bne .roaches
                lda #ST_WANDER
                sta STATE,x
                jsr NewWanderTarget
.roaches        ldx LastRoach
-               jsr UpdateRoach
                dex
                bpl -
                jmp WriteSprites

; The window was moved, resized, minimized or restored
RectChanged     lda #0                          ; shelter only if the window
                sta Shelter                     ; isn't minimized and big enough
                lda Cur
                bne +
                lda Cur+3
                cmp #2
                bcc +
                lda Cur+4
                cmp #2
                bcc +
                inc Shelter
+               ; WinL = x * 8 + 24
                lda #0
                sta WinL+1
                lda Cur+1
                asl
                rol WinL+1
                asl
                rol WinL+1
                asl
                rol WinL+1
                clc
                adc #24
                sta WinL
                bcc +
                inc WinL+1
+               ; WinR = WinL + width * 8
                lda #0
                sta Tmp2
                lda Cur+3
                asl
                rol Tmp2
                asl
                rol Tmp2
                asl
                rol Tmp2
                clc
                adc WinL
                sta WinR
                lda Tmp2
                adc WinL+1
                sta WinR+1
                ; WinT = (y + RowOffset) * 8 + 50
                lda Cur+2
                clc
                adc RowOffset
                asl
                asl
                asl
                clc
                adc #50
                sta WinT
                ; WinB = WinT + height * 8
                lda Cur+4
                asl
                asl
                asl
                clc
                adc WinT
                bcc +
                lda #255
+               sta WinB
                ; New targets for all roaches
                ldx LastRoach
.next           lda Shelter
                beq .panic
                lda STATE,x
                cmp #ST_IDLE                    ; hidden roaches need a moment
                bne +                           ; to notice
                jsr Random
                and #15
                sta PAUSE,x
+               lda #ST_HOME
                sta STATE,x
                jsr NewHideSpot
                jmp .cont
.panic          lda #ST_WANDER
                sta STATE,x
                jsr NewWanderTarget
.cont           dex
                bpl .next
                rts

; Random hiding place under the window (not under the title bar)
; for roach X. X is preserved.
NewHideSpot     lda Cur+3                       ; column 0..width-1
                sta ModVal
                jsr Random
                jsr Mod
                ldy #0
                sty Tmp2
                asl
                rol Tmp2
                asl
                rol Tmp2
                asl
                rol Tmp2
                clc                             ; center of the roach in the
                adc WinL                        ; middle of the char
                sta Tmp
                lda Tmp2
                adc WinL+1
                sta Tmp2
                lda Tmp                         ; sprite position = center - 8,
                sec                             ; center = char + 4
                sbc #4
                sta TXLO,x
                lda Tmp2
                sbc #0
                sta TXHI,x
                ldy Cur+4                       ; row 1..height-1
                dey
                sty ModVal
                jsr Random
                jsr Mod
                clc
                adc #1
                asl
                asl
                asl
                clc
                adc WinT
                bcs +
                sec
                sbc #4
                cmp MaxY                        ; keep it on the screen
                bcc ++
+               lda MaxY
++              sta TY,x
                rts

; Random position on the screen for roach X. X is preserved.
NewWanderTarget jsr Random                      ; x = 24..310
                sta Tmp
                jsr Random
                and #31
                clc
                adc Tmp
                sta Tmp
                lda #0
                adc #0
                sta Tmp2
                lda Tmp
                clc
                adc #24
                sta TXLO,x
                lda Tmp2
                adc #0
                sta TXHI,x
                lda MaxY                        ; y = 50..MaxY
                sec
                sbc #49
                sta ModVal
                jsr Random
                jsr Mod
                clc
                adc #50
                sta TY,x
                rts

;----------------------------------------------------------------------
; Moves roach X one step towards its target. X is preserved.
UpdateRoach     lda PAUSE,x
                beq +
                dec PAUSE,x
                rts
+               lda STATE,x
                cmp #ST_IDLE
                bne +
                rts                             ; hidden, nothing to do
+               ldy #2                          ; running for cover: fast
                cmp #ST_WANDER
                bne +
                ldy #1                          ; exploring: slow
+               sty Speed
                ; distance in x
                lda TXLO,x
                sec
                sbc RXLO,x
                sta DLo
                lda TXHI,x
                sbc RXHI,x
                sta DHi
                jsr AbsClamp
                sta ADX
                sty SGX
                ; distance in y
                lda TY,x
                sec
                sbc RY,x
                sta DLo
                lda #0
                sbc #0
                sta DHi
                jsr AbsClamp
                sta ADY
                sty SGY
                ora ADX
                bne .move
                jmp Arrived
.move           ; step in x
                lda ADX
                cmp Speed
                bcc +
                lda Speed
+               ldy SGX
                bne .left
                clc
                adc RXLO,x
                sta RXLO,x
                bcc .stepY
                inc RXHI,x
                bcs .stepY                      ; jmp
.left           sta Tmp
                lda RXLO,x
                sec
                sbc Tmp
                sta RXLO,x
                bcs .stepY
                dec RXHI,x
.stepY          lda ADY
                cmp Speed
                bcc +
                lda Speed
+               ldy SGY
                bne .up
                clc
                adc RY,x
                sta RY,x
                jmp .dir
.up             sta Tmp
                lda RY,x
                sec
                sbc Tmp
                sta RY,x
.dir            ; look in the direction of the longer way
                lda ADX
                cmp ADY
                bcc .vertical
                lda SGX                         ; 0: right, 1: left
                asl
                ora #1
                bne .setDir                     ; jmp
.vertical       lda SGY                         ; 0: down, 1: up
                eor #1
                asl
.setDir         sta DIR,x
                inc ANIM,x                      ; move the legs
                ; stop and go
                jsr Random
                cmp #3
                bcs +
                jsr Random
                and #15
                adc #4
                sta PAUSE,x
+               rts

; Roach X reached its target
Arrived         lda STATE,x
                cmp #ST_HOME
                bne .looked
                lda Shelter
                beq .looked
                lda #ST_IDLE                    ; hidden
                sta STATE,x
                rts
.looked         jsr Random                      ; have a look around
                and #63
                adc #20
                sta PAUSE,x
                lda Shelter
                beq +
                lda #ST_HOME                    ; and go home
                sta STATE,x
                jmp NewHideSpot
+               lda #ST_WANDER                  ; no window to hide under
                sta STATE,x
                jmp NewWanderTarget

; DHi/DLo = signed distance
; Returns A = min(|distance|, 255) and Y = 0 (positive) or 1 (negative)
AbsClamp        ldy #0
                lda DHi
                bpl +
                lda #0
                sec
                sbc DLo
                sta DLo
                lda #0
                sbc DHi
                sta DHi
                ldy #1
+               lda DHi
                beq +
                lda #255
                rts
+               lda DLo
                rts

; Is roach X hidden under the window? C=1: yes
; The roach slips under the window when its center does.
IsHidden        lda Shelter
                beq .no
                lda RXLO,x                      ; center x = x + 8
                clc
                adc #8
                sta Tmp
                lda RXHI,x
                adc #0
                sta Tmp2
                lda Tmp                         ; center x >= WinL?
                cmp WinL
                lda Tmp2
                sbc WinL+1
                bcc .no
                lda Tmp                         ; center x < WinR?
                cmp WinR
                lda Tmp2
                sbc WinR+1
                bcs .no
                lda RY,x                        ; center y = y + 8
                clc
                adc #8
                cmp WinT
                bcc .no
                cmp WinB
                bcs .no
                sec
                rts
.no             clc
                rts

;----------------------------------------------------------------------
; Roach X is sprite SprNo,x (7, 6, 5, 4)
WriteSprites    lda #0
                sta MsbBits
                sta EnaBits
                ldx LastRoach
-               ldy SprNo,x
                lda ANIM,x                      ; sprite = dir * 2 + pose
                lsr
                lsr
                and #1
                sta Tmp
                lda DIR,x
                asl
                ora Tmp
                clc
                adc #(SpriteData - ENGINE_BASE) / 64
SprPtrStore     sta $03f8,y                     ; high byte: screen (EngineStart)
                lda #ROACH_COLOR
                sta $d027,y
                tya                             ; position registers
                asl
                tay
                lda RXLO,x
                sta $d000,y
                lda RY,x
                sta $d001,y
                lda RXHI,x
                beq +
                lda BitTab,x
                ora MsbBits
                sta MsbBits
+               jsr IsHidden
                bcs +
                lda BitTab,x
                ora EnaBits
                sta EnaBits
+               dex
                bpl -
                lda SprMask                     ; X bit 8 and enable
                eor #$ff
                tay
                and $d010
                ora MsbBits
                sta $d010
                tya
                and $d015
                ora EnaBits
                sta $d015
                ldx #3                          ; in front of the chars,
-               ldy SprRegs,x                   ; single color, not expanded
                lda SprMask
                eor #$ff
                and $d000,y
                sta $d000,y
                dex
                bpl -
                rts

SprNo           !byte 7, 6, 5, 4
BitTab          !byte $80, $40, $20, $10
SprRegs         !byte $1b, $1c, $17, $1d
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
RowOffset       !byte 0 ; 1 if window y is counted below the menu bar (MAC)
LastRoach       !byte 0 ; number of roaches - 1 (MAC: 3, WIN: 1)
SprMask         !byte 0 ; their sprites (MAC: 7-4, WIN: 7 and 6)
MaxY            !byte 0 ; lowest sprite position (above the taskbar in WIN)
Seed            !word 1
FrameCnt        !byte 0
Cur             !fill 5,0 ; minimized, x, y, width, height of window (TrackWindow)
Last            !fill 5,0
Shelter         !byte 0 ; 1 if roaches can hide under the window
WinL            !word 0 ; window rectangle in sprite coordinates
WinR            !word 0
WinT            !byte 0
WinB            !byte 0
Speed           !byte 0
DLo             !byte 0
DHi             !byte 0
ADX             !byte 0
ADY             !byte 0
SGX             !byte 0
SGY             !byte 0
Tmp             !byte 0
Tmp2            !byte 0
ModVal          !byte 0
MsbBits         !byte 0
EnaBits         !byte 0
; Per roach
RXLO            !fill MAX_ROACHES,0 ; sprite position
RXHI            !fill MAX_ROACHES,0
RY              !fill MAX_ROACHES,0
TXLO            !fill MAX_ROACHES,0 ; target position
TXHI            !fill MAX_ROACHES,0
TY              !fill MAX_ROACHES,0
STATE           !fill MAX_ROACHES,0
PAUSE           !fill MAX_ROACHES,0
DIR             !fill MAX_ROACHES,0
ANIM            !fill MAX_ROACHES,0
EngineEnd
}
ENGINE_PAGES    = (EngineEnd - ENGINE_BASE + 255) / 256

!to "RainRadar.d64",d64,"rainradar.gui","rainradar disk"

; RainRadar - precipitation forecast for the next two hours (GUI64,
; MAC and WIN design), similar to Buienalarm
;
; Choose "Name" or "Koordinaten", enter a place name or coordinates
; ("51.08,6.32" or "51.08 6.32") and press RETURN (or click "Refresh").
; A name is looked up with the Open-Meteo geocoding API. Then the app
; loads the 15 minute precipitation forecast (Open-Meteo, for Germany
; based on DWD ICON-D2).
; The curve shows the next two hours (one column = 5 minutes, values
; between the 15 minute steps are interpolated) on a logarithmic scale:
; light (< 1 mm/h), moderate (1-5 mm/h) and heavy (> 5 mm/h) rain.
; The forecast is refreshed every 5 minutes while the window is active.
;
; Network: Ultimate 64 / Ultimate II+ / C64U, "Command Interface" must
; be enabled in the Ultimate settings. The app talks plain HTTP over the
; TCP socket commands of the Ultimate Command Interface (network target).
;
; The app only uses the GUI64 API (gui64.inc.asm) and the Ultimate
; Command Interface registers ($df1c-$df1f).

!source "gui64.inc.asm"

!zone Constants
WT_RAINRADAR     = 57 ; app window types start at 50
CT_RR_GRAPH      = 50 ; app control types start at 50
ID_MENU_RADAR    = 10 ; menu IDs start at 10
ID_MENU_HELP     = 11

; Control indices (see Wnd_RainRadar)
CTRL_EDIT        = 2
CTRL_BUTTON      = 3
CTRL_MODE_NAME   = 11               ; radio buttons (one each, side by
CTRL_MODE_COORDS = 12               ; side; HilIndex 0: selected)

MODE_NAME        = 0                ; radio button index
MODE_COORDS      = 1

PLACE_LEN        = 16               ; max. length of the place name input
TEXT_LEN         = 32               ; status and summary line
NAME_MAX         = 22               ; place name shown in the status line
NUM_MAX          = 10               ; latitude/longitude digits

GRAPH_X          = 8
GRAPH_Y          = 8
GRAPH_W          = 24               ; 24 columns of 5 minutes = 2 hours
GRAPH_H          = 8                ; 8 rows of 8 pixels = 64 levels
NUM_VALUES       = 9                ; 15 minute values (0..120 minutes)

REFRESH_TICKS    = 3000             ; 5 minutes (timer ticks are 1/10 s)
READ_TRIES       = 1500             ; socket read retries (~10 ms each)

KEY_RETURN       = $fc

; Colors
COL_LIGHT        = CL_LIGHTBLUE
COL_MODERATE     = CL_YELLOW
COL_HEAVY        = CL_RED
COL_GRID         = CL_DARKGRAY
LEVEL_MODERATE   = 33               ; heights from which a column is
LEVEL_HEAVY      = 49               ; drawn in the next color

; Ultimate Command Interface
UCI_CONTROL      = $df1c            ; write
UCI_STATUS       = $df1c            ; read
UCI_CMD_DATA     = $df1d            ; write
UCI_IDENT        = $df1d            ; read ($c9)
UCI_RESP_DATA    = $df1e
UCI_STATUS_DATA  = $df1f
UCI_ID           = $c9
UCI_PUSH_CMD     = %00000001
UCI_DATA_ACC     = %00000010
UCI_ABORT        = %00000100
UCI_STATE        = %00110000        ; 00 idle, 01 busy, 10/11 data
UCI_STATE_BUSY   = %00010000
UCI_STAT_AV      = %01000000
UCI_TARGET_NET   = 3
NET_TCP_CONNECT  = $07
NET_SOCKET_CLOSE = $09
NET_SOCKET_READ  = $10
NET_SOCKET_WRITE = $11
READ_CHUNK       = 256

!zone Init
*=$b000
                lda #WT_RAINRADAR               ; look for window with type "WT_RAINRADAR"
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
                ldx #<CtrlAction                ; Behavior of the graph control
                ldy #>CtrlAction                ; (void, events are handled
                jsr GUI_SetCtrlActionsRoutine   ; in the window proc)
                ;
                ldx #<PaintCtrls                ; Look of the
                ldy #>PaintCtrls                ; graph control
                jsr GUI_SetPaintCtrlsRoutine    ;
                ;
                ldx #<Wnd_RainRadar             ; Create the window with
                ldy #>Wnd_RainRadar             ; its controls
                jsr GUI_CreateWindowEx          ;
                ;
                jsr GUI_GetDesign               ; Z=1: WIN, Z=0: MAC
                beq +                           ;
                dec WindowHeight                ; For MAC design, the menu bar
                jsr GUI_UpdateWindow            ; is not in the window
+               ; Menu
                jsr GUI_SelectControl0          ; Associate the menu bar
                ldx #<Str_RRMenubar             ; strings with control 0
                ldy #>Str_RRMenubar             ;
                lda #2                          ; 2 strings
                jsr GUI_SetCtrlStringList       ;
                ; Input mode: name (selected) or coordinates
                lda #CTRL_MODE_NAME
                jsr GUI_SelectControl
                lda #0
                sta ControlHilIndex
                ldx #<Str_ModeName
                ldy #>Str_ModeName
                lda #1
                jsr GUI_SetCtrlStringList
                lda #CTRL_MODE_COORDS
                jsr GUI_SelectControl
                lda #1
                sta ControlHilIndex
                ldx #<Str_ModeCoords
                ldy #>Str_ModeCoords
                lda #1
                jsr GUI_SetCtrlStringList
                ; Place input
                ldx #PLACE_LEN-1                ; preset with DefaultPlace
-               lda #" "                        ; (filled up with spaces)
                sta EditBuf,x
                dex
                bpl -
                ldx #0
-               lda DefaultPlace,x
                beq +
                sta EditBuf,x
                inx
                cpx #PLACE_LEN
                bne -
+               stx PendingFetch                ; fetch at once if preset
                txa
                pha                             ; caret position
                lda #CTRL_EDIT
                jsr GUI_SelectControl
                lda #<Forbidden                 ; chars that would break
                sta ControlIndex+EditSL_Forbidden ; the URL
                lda #>Forbidden
                sta ControlIndex+EditSL_Forbidden+1
                ldx #<EditBuf
                ldy #>EditBuf
                jsr GUI_SetCtrlString
                pla
                ldx #PLACE_LEN
                jsr GUI_SetEditSLInfo
                jsr FocusEdit
                ;
                ldx #<TimerProc                 ; auto refresh
                ldy #>TimerProc                 ; (every 1/10 second)
                jsr GUI_InitTimer
                jmp GUI_StartTimer

; Keyboard input goes to the place input
FocusEdit       lda #CTRL_EDIT
                sta WindowFocCtrl
                jmp GUI_UpdateWindow

; Timer handler (GUI64 main loop, not IRQ): first fetch of a preset place
; and refresh every 5 minutes
TimerProc       lda RefreshCnt                  ; count ticks up to
                cmp #<REFRESH_TICKS             ; REFRESH_TICKS
                lda RefreshCnt+1
                sbc #>REFRESH_TICKS
                bcs +
                inc RefreshCnt
                bne +
                inc RefreshCnt+1
+               lda WindowType                  ; only while the window is
                cmp #WT_RAINRADAR               ; the current one,
                bne .rts
                lda WindowBits                  ; not minimized
                and #BIT_WND_ISMINIMIZED
                bne .rts
                lda ProgramMode                 ; and no menu or dialog is
                bne .rts                        ; open
                lda PendingFetch
                beq +
                jmp DoFetch
+               lda HaveCoords                  ; refresh due?
                beq .rts
                lda RefreshCnt
                cmp #<REFRESH_TICKS
                lda RefreshCnt+1
                sbc #>REFRESH_TICKS
                bcc .rts
                jmp Refresh
.rts            rts

!zone WndProc
; Window Proc (event handler for window)
RR_WndProc      lda wndParam0                   ; keys go to the place input:
                cmp #EC_KEYPRESS                ; GUI64 passes them to the
                bne +                           ; selected control, which is
                lda wndParam1                   ; the last painted one after
                bne +                           ; a repaint
                jsr FocusEdit
                lda #CTRL_EDIT
                jsr GUI_SelectControl
+               jsr GUI_StdWndProc              ; MUST always be called
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
                cmp #ID_MENU_RADAR              ;
                bne +                           ;
                jmp RadarMenuClicked            ;
+               jmp HelpMenuClicked             ;
.normal         lda wndParam0                   ; event code
                cmp #EC_KEYPRESS                ;
                bne +                           ;
                lda actkey                      ; RETURN: fetch
                cmp #KEY_RETURN                 ; (other keys go to the
                bne .leave                      ; place input)
                jmp DoFetch                     ;
+               cmp #EC_LBTNPRESS               ; radio button clicked?
                bne +
                jmp SyncMode
+               cmp #EC_LBTNRELEASE             ; left mouse button released?
                bne .leave
                jsr GUI_IsInCurControl          ; mouse in a control?
                bcc .focus
                lda ControlIndex
                cmp #CTRL_BUTTON                ; the button?
                bne +
                jmp DoFetch
.focus          jmp FocusEdit                   ; keys go to the input again
.leave          rts

; Two radio buttons side by side: GUI64 selects a clicked one (HilIndex
; 0), so if the one of the other mode got selected, switch the mode and
; deselect the one of the old mode
SyncMode        lda Mode
                eor #1
                clc
                adc #CTRL_MODE_NAME
                jsr GUI_SelectControl           ; the other mode's button
                lda ControlHilIndex
                bne .leave                      ; not clicked
                lda Mode                        ; deselect the old one
                clc
                adc #CTRL_MODE_NAME
                jsr GUI_SelectControl
                lda #1
                sta ControlHilIndex
                jsr GUI_UpdateControl
                lda Mode
                eor #1
                sta Mode
                ldx #<Msg_HintName
                ldy #>Msg_HintName
                lda Mode
                beq +
                ldx #<Msg_HintCoords
                ldy #>Msg_HintCoords
+               jmp ShowStatusFocus

; Invoked when an item in the radar menu was clicked
RadarMenuClicked
                lda CurMenuItem                 ; 0: Refresh
                bne +
                jmp DoFetch
+               jsr GUI_KillCurWindow           ; 1: Quit (sends EC_SHUTDOWN,
                jmp GUI_Repaint                 ; which stops the timer)

HelpMenuClicked lda CurMenuItem
                bne +
                ldx #<Str_Mess_Help             ; 0: Help
                ldy #>Str_Mess_Help
                jmp GUI_ShowMessage
+               ldx #<Str_Mess_About            ; 1: About
                ldy #>Str_Mess_About
                jmp GUI_ShowMessage

!zone DoFetch
; Looks up the entered place and loads its forecast
DoFetch         lda #0
                sta PendingFetch
                jsr ReadInput
                lda InputLen
                bne +
                ldx #<Msg_EnterPlace
                ldy #>Msg_EnterPlace
                jmp ShowStatusFocus
+               lda UCI_IDENT                   ; Ultimate Command Interface?
                cmp #UCI_ID
                beq +
                ldx #<Msg_NoUltimate
                ldy #>Msg_NoUltimate
                jmp ShowStatusFocus
+               lda #CTRL_MODE_NAME             ; mode as shown by the radio
                jsr GUI_SelectControl           ; buttons
                lda ControlHilIndex             ; 0: "Name" selected
                beq +
                lda #MODE_COORDS
+               sta Mode
                beq .byName
                jsr ParseCoords                 ; coordinates: no lookup
                bcs .found
                ldx #<Msg_BadCoords
                ldy #>Msg_BadCoords
                jmp ShowStatusFocus
.byName         ldx #<Msg_Search
                ldy #>Msg_Search
                jsr ShowStatus
                ; 1st query: "ae", "oe", "ue" replaced by umlauts
                lda #0
                sta GeoFound
                lda #1
                jsr GeoQuery
                bcs .netError
                lda DidSubst                    ; nothing replaced: done
                beq .geoDone
                lda GeoFound                    ; found the place as typed
                beq +                           ; (except for the umlauts)?
                jsr NameMatches
                bcs .geoDone
+               ; 2nd query: as typed (e.g. "Soest")
                lda #0
                jsr GeoQuery
                bcs .netError
.geoDone        lda GeoFound
                bne +
                ldx #<Msg_NotFound
                ldy #>Msg_NotFound
                jmp ShowStatusFocus
+
.found          lda #1
                sta HaveCoords
                jsr Refresh
                jmp FocusEdit
.netError       ldx #<Msg_NetError
                ldy #>Msg_NetError
                jmp ShowStatusFocus

; Loads the forecast for the found place
Refresh         lda #0
                sta RefreshCnt
                sta RefreshCnt+1
                ldx #<Msg_Load
                ldy #>Msg_Load
                jsr ShowStatus
                jsr BuildForecastReq
                ldx #<Host_Forecast
                ldy #>Host_Forecast
                jsr HttpGet
                bcc +
                ldx #<Msg_NetError
                ldy #>Msg_NetError
                jmp ShowStatus
+               jsr ParseForecast
                bcs +
                ldx #<Msg_NoData
                ldy #>Msg_NoData
                jmp ShowStatus
+               jsr CalcGraph
                jsr BuildSummary
                jsr BuildTimeLine
                ; Status line: place name and country (coordinates: no
                ; country)
                ldx #<StatusText
                ldy #>StatusText
                jsr OutInit
                ldx #0
-               cpx PlaceNameLen
                beq +
                lda PlaceName,x
                jsr Asc2Pet
                jsr OutCharX
                inx
                bne -
+               lda PlaceCC
                beq .pad
                lda #" "
                jsr OutChar
                lda #"("
                jsr OutChar
                lda PlaceCC
                jsr Asc2Pet
                jsr OutChar
                lda PlaceCC+1
                jsr Asc2Pet
                jsr OutChar
                lda #")"
                jsr OutChar
.pad            lda #TEXT_LEN
                jsr OutPad
                jmp GUI_RepaintCurWindow

; Shows the message at X/Y in the status line (and paints the window)
ShowStatus      stx .msg
                sty .msg+1
                ldx #<StatusText
                ldy #>StatusText
                jsr OutInit
                ldx .msg
                ldy .msg+1
                jsr OutStr
                lda #TEXT_LEN
                jsr OutPad
                jmp GUI_RepaintCurWindow
.msg            !word 0

ShowStatusFocus jsr ShowStatus
                jmp FocusEdit

!zone Input
; Input length without trailing spaces in InputLen,
; the input as lower case ASCII in TypedLow
ReadInput       ldx #PLACE_LEN
-               lda EditBuf-1,x
                cmp #" "
                bne +
                dex
                bne -
+               stx InputLen
                lda #0                          ; end marker (ParseCoords)
                sta TypedLow,x
                dex
                bmi .done
-               lda EditBuf,x
                jsr Pet2AscLow
                sta TypedLow,x
                dex
                bpl -
.done           rts

; C=1 if the found name (umlauts as "ae", "oe", "ue", "ss") is the input
NameMatches     lda GeoNameLen
                cmp InputLen
                bne .no
                tax
-               dex
                bmi .yes
                lda GeoCmp,x
                cmp TypedLow,x
                beq -
.no             clc
                rts
.yes            sec
                rts

; Coordinates input "lat,lon" (separated by ",", ";" or spaces): takes
; them as place (the input as name, no country). C=1: ok
ParseCoords     lda #<TypedLow
                sta ZP_FB
                lda #>TypedLow
                sta ZP_FC
                jsr SkipSep
                ldx #<GeoLat
                ldy #>GeoLat
                jsr CopyNumber
                stx GeoLatLen
                txa
                beq .bad
                jsr PeekCh                      ; a separator must follow
                jsr IsSep
                bne .bad
                jsr SkipSep
                ldx #<GeoLon
                ldy #>GeoLon
                jsr CopyNumber
                stx GeoLonLen
                txa
                beq .bad
                jsr SkipSep
                jsr PeekCh                      ; nothing else may follow
                bne .bad
                ldx InputLen                    ; name: the input as typed
-               dex
                bmi +
                lda TypedLow,x
                sta GeoName,x
                jmp -
+               lda InputLen
                sta GeoNameLen
                lda #0
                sta GeoCC
                jsr CommitPlace
                sec
                rts
.bad            clc
                rts

; Skips separators in the received data / input at ZP_FB/FC
SkipSep         jsr PeekCh
                jsr IsSep
                bne +
                jsr IncFB
                jmp SkipSep
+               rts

; Z=1 if A is a separator
IsSep           cmp #' '
                beq +
                cmp #','
                beq +
                cmp #';'
+               rts

!zone Geocoding
; Asks the geocoding API for the input. A=1: replace "ae", "oe", "ue"
; by umlauts (DidSubst=1 if something was replaced).
; C=1: network error. Found place (GeoFound=1) in Place*.
GeoQuery        sta Subst
                lda #0
                sta DidSubst
                ldx #<ReqBuf
                ldy #>ReqBuf
                jsr OutInit
                ldx #<Req_Geo1
                ldy #>Req_Geo1
                jsr OutStr
                lda #0
                sta UrlIdx
.char           ldx UrlIdx
                cpx InputLen
                bcs .end
                lda TypedLow,x
                inc UrlIdx
                ldy Subst                       ; umlaut?
                beq .plain
                ldy TypedLow+1,x
                cpy #'e'
                bne .plain
                inx
                cpx InputLen
                bcs .plain
                ldy #2
-               cmp UmlBase,y
                beq .umlaut
                dey
                bpl -
.plain          cmp #'a'                        ; a-z, 0-9, "-", "." as is
                bcc +
                cmp #'z'+1
                bcc .out
+               cmp #'0'
                bcc +
                cmp #'9'+1
                bcc .out
+               cmp #'-'
                beq .out
                cmp #'.'
                beq .out
                jsr OutHex                      ; everything else as %xx
                jmp .char
.out            jsr OutChar
                jmp .char
.umlaut         inc UrlIdx                      ; skip the "e"
                lda #1
                sta DidSubst
                lda #$c3                        ; UTF-8: $c3 $a4/$b6/$bc
                jsr OutHex
                lda UmlUtf,y
                jsr OutHex
                jmp .char
.end            ldx #<Req_Geo2
                ldy #>Req_Geo2
                jsr OutStr
                ldx #<Host_Geo
                ldy #>Host_Geo
                jsr HttpGet
                bcs .rts
                jsr ParseGeo
                bcc +
                jsr CommitPlace
+               clc
.rts            rts

; Writes A as "%xx"
OutHex          pha
                lda #'%'
                jsr OutChar
                pla
                pha
                lsr
                lsr
                lsr
                lsr
                tax
                lda HexDigits,x
                jsr OutChar
                pla
                and #$0f
                tax
                lda HexDigits,x
                jmp OutChar

; Takes the parsed place (GeoName, GeoLat, GeoLon, GeoCC)
CommitPlace     lda #1
                sta GeoFound
                ldx #NAME_MAX-1
-               lda GeoName,x
                sta PlaceName,x
                dex
                bpl -
                lda GeoNameLen
                sta PlaceNameLen
                ldx #NUM_MAX-1
-               lda GeoLat,x
                sta PlaceLat,x
                lda GeoLon,x
                sta PlaceLon,x
                dex
                bpl -
                lda GeoLatLen
                sta PlaceLatLen
                lda GeoLonLen
                sta PlaceLonLen
                lda GeoCC
                sta PlaceCC
                lda GeoCC+1
                sta PlaceCC+1
                rts

!zone ParseGeo
; Parses the JSON answer of the geocoding API. C=1: found
ParseGeo        ldx #<Pat_Lat
                ldy #>Pat_Lat
                jsr FindFromStart
                bcs +
                rts                             ; no results (C=0)
+               ldx #<GeoLat
                ldy #>GeoLat
                jsr CopyNumber
                stx GeoLatLen
                ldx #<Pat_Lon
                ldy #>Pat_Lon
                jsr FindFromStart
                bcc .rts
                ldx #<GeoLon
                ldy #>GeoLon
                jsr CopyNumber
                stx GeoLonLen
                lda #'?'
                sta GeoCC
                sta GeoCC+1
                ldx #<Pat_CC
                ldy #>Pat_CC
                jsr FindFromStart
                bcc +
                jsr NextCh
                sta GeoCC
                jsr NextCh
                sta GeoCC+1
+               lda #0
                sta GeoNameLen
                ldx #<Pat_Name
                ldy #>Pat_Name
                jsr FindFromStart
                bcc .ok
.name           jsr NextCh                      ; copy up to the closing quote
                beq .ok
                cmp #'"'
                beq .ok
                cmp #$c3                        ; UTF-8 umlaut?
                bne .plain
                jsr NextCh
                ldx #6
-               cmp UmlCode,x
                beq .umlaut
                dex
                bpl -
                bmi .name                       ; other chars are left out
.umlaut         stx UmlIdx
                lda UmlText1,x
                jsr NameChar
                ldx UmlIdx
                lda UmlText2,x
                jsr NameChar
                jmp .name
.plain          cmp #$80                        ; other non-ASCII bytes
                bcs .name                       ; are left out
                jsr NameChar
                jmp .name
.ok             sec
.rts            rts

; Appends A to GeoName and lower case A to GeoCmp
NameChar        ldx GeoNameLen
                cpx #NAME_MAX
                bcs +
                sta GeoName,x
                jsr LowerAsc
                sta GeoCmp,x
                inc GeoNameLen
+               rts

; Copies a number (digits, "-", ".") to the buffer at X/Y, length in X
CopyNumber      stx .dst+1
                sty .dst+2
                ldx #0
-               jsr PeekCh
                cmp #'-'
                beq +
                cmp #'.'
                beq +
                cmp #'0'
                bcc .done
                cmp #'9'+1
                bcs .done
+               cpx #NUM_MAX
                bcs .done
.dst            sta $ffff,x
                inx
                jsr IncFB
                jmp -
.done           rts

!zone Forecast
; Builds the HTTP request for the forecast of the found place
BuildForecastReq
                ldx #<ReqBuf
                ldy #>ReqBuf
                jsr OutInit
                ldx #<Req_Fc1
                ldy #>Req_Fc1
                jsr OutStr
                ldx #0
-               cpx PlaceLatLen
                beq +
                lda PlaceLat,x
                jsr OutCharX
                inx
                bne -
+               ldx #<Req_Fc2
                ldy #>Req_Fc2
                jsr OutStr
                ldx #0
-               cpx PlaceLonLen
                beq +
                lda PlaceLon,x
                jsr OutCharX
                inx
                bne -
+               ldx #<Req_Fc3
                ldy #>Req_Fc3
                jmp OutStr

; Parses the CSV answer: lines "2026-10-27T19:30,0.20" (mm per 15 minutes)
; Times (HH:MM) in Times, values (1/100 mm) in ValLo/ValHi. C=1: ok
ParseForecast   lda #0
                sta NumVal
                ldx #<Pat_CsvHead
                ldy #>Pat_CsvHead
                jsr FindFromStart
                bcc .rts
.line           ldx #<Pat_T
                ldy #>Pat_T
                jsr FindStr
                bcc .end
                lda NumVal                      ; time HH:MM
                asl
                asl
                adc NumVal                      ; *5
                sta Idx
                lda #5
                sta MulCnt
-               jsr NextCh                      ; (uses Y)
                ldx Idx
                sta Times,x
                inc Idx
                dec MulCnt
                bne -
                ldx #<Pat_Comma
                ldy #>Pat_Comma
                jsr FindStr
                bcc .end
                jsr ParseValue
                ldx NumVal
                lda Acc
                sta ValLo,x
                lda Acc+1
                sta ValHi,x
                inc NumVal
                lda NumVal
                cmp #NUM_VALUES
                bne .line
.end            lda NumVal
                cmp #NUM_VALUES
.rts            rts

; Parses "12.34" to 1234 in Acc (at most 99.99)
ParseValue      lda #0
                sta Acc
                sta Acc+1
                sta IntPart
                sta FracPart
-               jsr DigitCh                     ; integer part
                bcc +
                tax
                lda IntPart
                cmp #10
                bcs -                           ; (more than 2 digits)
                asl                             ; IntPart*10 + digit
                asl
                adc IntPart
                asl
                sta IntPart
                txa
                adc IntPart
                sta IntPart
                jmp -
+               jsr PeekCh
                cmp #'.'
                bne .sum
                jsr IncFB
                jsr DigitCh                     ; tenths
                bcc .sum
                tax
                lda Mul10,x
                sta FracPart
                jsr DigitCh                     ; hundredths
                bcc .sum
                clc
                adc FracPart
                sta FracPart
.sum            ldx IntPart                     ; Acc = IntPart*100 + FracPart
                beq +
-               lda Acc
                clc
                adc #100
                sta Acc
                bcc ++
                inc Acc+1
++              dex
                bne -
+               lda Acc
                clc
                adc FracPart
                sta Acc
                bcc +
                inc Acc+1
+               rts

; C=1: digit at ($fb) (value in A, consumed)
DigitCh         jsr PeekCh
                sec
                sbc #'0'
                cmp #10
                bcs +
                pha
                jsr IncFB
                pla
                sec
                rts
+               clc
                rts

!zone CalcGraph
; Interpolates the 15 minute values to 24 columns of 5 minutes and
; converts them to heights (0..64, logarithmic scale)
CalcGraph       ldx #0
.col            stx Col
                lda #0
                sta Acc
                sta Acc+1
                ldy Div3,x                      ; value index
                lda #3
                sec
                sbc Mod3,x
                jsr AddValTimes                 ; value[i] * (3 - f)
                iny
                lda Mod3,x
                jsr AddValTimes                 ; value[i+1] * f
                lda Acc
                sta DivLo
                lda Acc+1
                sta DivHi
                lda #3
                jsr Div16
                ldx #0                          ; height = number of
-               lda DivHi                       ; thresholds <= value
                cmp ThrHi,x
                bcc .done
                bne +
                lda DivLo
                cmp ThrLo,x
                bcc .done
+               inx
                cpx #GRAPH_H*8
                bne -
.done           txa
                ldx Col
                sta Height,x
                ldy #COL_LIGHT
                cmp #LEVEL_MODERATE
                bcc +
                ldy #COL_MODERATE
                cmp #LEVEL_HEAVY
                bcc +
                ldy #COL_HEAVY
+               tya
                sta ColColor,x
                inx
                cpx #GRAPH_W
                bne .col
                rts

; Acc += value[Y] * A (X, Y are preserved)
AddValTimes     sta MulCnt
-               dec MulCnt
                bmi +
                lda Acc
                clc
                adc ValLo,y
                sta Acc
                lda Acc+1
                adc ValHi,y
                sta Acc+1
                jmp -
+               rts

; DivLo/DivHi = DivLo/DivHi / A, remainder in A
Div16           sta Divisor
                lda #0
                ldx #16
-               asl DivLo
                rol DivHi
                rol
                cmp Divisor
                bcc +
                sbc Divisor
                inc DivLo
+               dex
                bne -
                rts

!zone Summary
; "Regen ab 20:15, max 1.2 mm/h" etc.
BuildSummary    ldx #<SummaryText
                ldy #>SummaryText
                jsr OutInit
                ldx #0                          ; rain now?
                jsr IsRain
                beq .notNow
                ldx #1                          ; until when?
-               jsr IsRain
                beq +
                inx
                cpx #NUM_VALUES
                bne -
                ldx #<Txt_RainLong
                ldy #>Txt_RainLong
                jsr OutStr
                jmp .max
+               stx Idx
                ldx #<Txt_RainUntil
                ldy #>Txt_RainUntil
                jsr OutStr
                ldx Idx
                jsr OutTime
                jmp .max
.notNow         ldx #1                          ; rain later?
-               jsr IsRain
                bne +
                inx
                cpx #NUM_VALUES
                bne -
                ldx #<Txt_NoRain
                ldy #>Txt_NoRain
                jsr OutStr
                ldx #NUM_VALUES-1
                jsr OutTime
                jmp .pad
+               stx Idx
                ldx #<Txt_RainFrom
                ldy #>Txt_RainFrom
                jsr OutStr
                ldx Idx
                jsr OutTime
.max            ldx #<Txt_Max                   ; ", max 1.2 mm/h"
                ldy #>Txt_Max
                jsr OutStr
                lda #0
                sta Acc
                sta Acc+1
                ldx #NUM_VALUES-1               ; Acc = max value
-               lda ValLo,x
                cmp Acc
                lda ValHi,x
                sbc Acc+1
                bcc +
                lda ValLo,x
                sta Acc
                lda ValHi,x
                sta Acc+1
+               dex
                bpl -
                lda Acc                         ; mm/h in 1/10:
                sta DivLo                       ; (value * 4 + 5) / 10
                lda Acc+1
                asl DivLo
                rol
                asl DivLo
                rol
                sta DivHi
                lda DivLo
                clc
                adc #5
                sta DivLo
                bcc +
                inc DivHi
+               lda #10
                jsr Div16
                lda #10                         ; integer part / tenths
                jsr Div16
                pha
                jsr OutDec16
                lda #"."
                jsr OutChar
                pla
                ora #"0"
                jsr OutChar
                ldx #<Txt_Unit
                ldy #>Txt_Unit
                jsr OutStr
.pad            lda #TEXT_LEN
                jmp OutPad

; Z=0 if value X > 0 (X is preserved)
IsRain          lda ValLo,x
                ora ValHi,x
                rts

; Writes time X (HH:MM)
OutTime         txa
                asl
                asl
                stx Idx
                adc Idx                         ; *5
                tax
                ldy #5
-               lda Times,x
                jsr OutCharX
                inx
                dey
                bne -
                rts

; Writes DivLo/DivHi as decimal number
OutDec16        lda #0
                sta Digits
-               lda #10
                jsr Div16
                pha
                inc Digits
                lda DivLo
                ora DivHi
                bne -
-               pla
                ora #"0"
                jsr OutChar
                dec Digits
                bne -
                rts

; Time line below the graph: "19:30 20:00 20:30 21:00"
BuildTimeLine   ldx #<TimeText
                ldy #>TimeText
                jsr OutInit
                ldx #0
-               stx Idx2
                jsr OutTime
                lda #" "
                jsr OutChar
                ldx Idx2
                inx
                inx
                cpx #8
                bne -
                lda #GRAPH_W
                jmp OutPad

!zone Output
; Simple text output to the buffer at X/Y (OutPos = length)
OutInit         stx .sta+1
                sty .sta+2
                lda #0
                sta OutPos
                rts

; Appends A (X is preserved)
OutCharX        stx .x
                jsr OutChar
                ldx .x
                rts
.x              !byte 0

; Appends A
OutChar         ldx OutPos
.sta            sta $ffff,x
                inc OutPos
                rts

; Appends the null terminated string at X/Y
OutStr          stx ZP_FD
                sty ZP_FE
                ldy #0
-               lda (ZP_FD),y
                beq +
                jsr OutChar
                iny
                bne -
+               rts

; Fills up with spaces to length A
OutPad          sta .len
-               lda OutPos
                cmp .len
                bcs +
                lda #" "
                jsr OutChar
                jmp -
+               rts
.len            !byte 0

!zone Chars
; PETSCII (input) to lower case ASCII
Pet2AscLow      cmp #$41
                bcc +
                cmp #$5b
                bcs ++
                ora #$20                        ; $41-$5a: a-z
+               rts
++              cmp #$c1
                bcc +
                cmp #$db
                bcs +
                sbc #$5f                        ; $c1-$da: a-z (C=0: -$60)
+               rts

; ASCII to lower case ASCII
LowerAsc        cmp #'A'
                bcc +
                cmp #'Z'+1
                bcs +
                ora #$20
+               rts

; ASCII to PETSCII
Asc2Pet         cmp #'A'
                bcc +
                cmp #'Z'+1
                bcs ++
                ora #$80                        ; A-Z: $c1-$da
+               rts
++              cmp #'a'
                bcc +
                cmp #'z'+1
                bcs +
                and #$df                        ; a-z: $41-$5a
+               rts

!zone Search
; Searches the null terminated pattern at X/Y in the received data
; from the start. C=1: found, ZP_FB/FC points behind it
FindFromStart   lda #<RxBuf
                sta ZP_FB
                lda #>RxBuf
                sta ZP_FC
                ; fall through
; The same from ZP_FB/FC on
FindStr         stx ZP_FD
                sty ZP_FE
.try            ldy #0
-               lda (ZP_FD),y
                beq .found
                cmp (ZP_FB),y
                bne .next
                iny
                bne -
.next           ldy #0
                lda (ZP_FB),y                   ; end of data?
                beq .notFound
                jsr IncFB
                jmp .try
.found          tya
                clc
                adc ZP_FB
                sta ZP_FB
                bcc +
                inc ZP_FC
+               sec
                rts
.notFound       clc
                rts

; Next char of the received data in A (Z=1: end of data)
NextCh          jsr PeekCh
                beq +
                pha
                jsr IncFB
                pla
+               rts

PeekCh          ldy #0
                lda (ZP_FB),y
                rts

IncFB           inc ZP_FB
                bne +
                inc ZP_FC
+               rts

!zone Http
; HTTP GET: connects to the host at X/Y (port 80), sends the request in
; ReqBuf (length OutPos) and receives the answer (until the server
; closes the connection) to RxBuf (null terminated).
; C=1: no connection
HttpGet         stx ZP_FD
                sty ZP_FE
                lda OutPos
                sta ReqLen
                jsr UciStart
                lda #UCI_TARGET_NET             ; connect
                sta UCI_CMD_DATA
                lda #NET_TCP_CONNECT
                sta UCI_CMD_DATA
                lda #80                         ; port 80
                sta UCI_CMD_DATA
                lda #0
                sta UCI_CMD_DATA
                ldy #0                          ; host name
-               lda (ZP_FD),y
                sta UCI_CMD_DATA
                beq +
                iny
                bne -
+               jsr UciPush
                lda #0
                sta StoreOn
                jsr UciResult
                jsr ConnectOk
                bcc +
                jmp .fail
+               lda Data0
                sta Socket
                ; Send the request
                jsr UciStart
                lda #UCI_TARGET_NET
                sta UCI_CMD_DATA
                lda #NET_SOCKET_WRITE
                sta UCI_CMD_DATA
                lda Socket
                sta UCI_CMD_DATA
                ldx #0
-               lda ReqBuf,x
                sta UCI_CMD_DATA
                inx
                cpx ReqLen
                bne -
                jsr UciPush
                jsr UciResult
                ; Receive the answer
                lda #<RxBuf
                sta ZP_FB
                lda #>RxBuf
                sta ZP_FC
                lda #0
                sta Tries
                sta Tries+1
.read           jsr UciStart
                lda #UCI_TARGET_NET
                sta UCI_CMD_DATA
                lda #NET_SOCKET_READ
                sta UCI_CMD_DATA
                lda Socket
                sta UCI_CMD_DATA
                lda #<READ_CHUNK
                sta UCI_CMD_DATA
                lda #>READ_CHUNK
                sta UCI_CMD_DATA
                jsr UciPush
                lda #1
                sta StoreOn
                jsr UciResult
                lda #0
                sta StoreOn
                lda DataCnt+1                   ; at least the 2 length bytes?
                bne +
                lda DataCnt
                cmp #2
                bcc .wait
+               lda Data0                       ; $ffff: no data yet
                and Data1
                cmp #$ff
                beq .wait
                lda Data0                       ; 0: connection closed
                ora Data1
                bne .read                       ; data received: go on
                lda ZP_FB                       ; closed (only after the
                cmp #<RxBuf                     ; first data, otherwise
                bne .close                      ; wait some more)
                lda ZP_FC
                cmp #>RxBuf
                bne .close
.wait           ldx #8                          ; ~10 ms
                ldy #0
-               dey
                bne -
                dex
                bne -
                inc Tries
                bne +
                inc Tries+1
+               lda Tries
                cmp #<READ_TRIES
                bne .read
                lda Tries+1
                cmp #>READ_TRIES
                bne .read
.close          ldy #0                          ; end of data
                tya
                sta (ZP_FB),y
                jsr UciStart
                lda #UCI_TARGET_NET
                sta UCI_CMD_DATA
                lda #NET_SOCKET_CLOSE
                sta UCI_CMD_DATA
                lda Socket
                sta UCI_CMD_DATA
                jsr UciPush
                jsr UciResult
                clc
                rts
.fail           lda #0                          ; no data
                sta RxBuf
                sec
                rts

!zone Uci
; C=0 if the connect command returned a socket number and status "00"
; (or no status)
ConnectOk       lda DataCnt                     ; socket number received?
                ora DataCnt+1
                beq .no
                lda StatCnt
                beq .yes
                lda Stat0
                cmp #'0'
                bne .no
                lda Stat1
                cmp #'0'
                bne .no
.yes            clc
                rts
.no             sec
                rts

; Ultimate Command Interface: aborts a pending command
UciStart        lda UCI_STATUS
                and #UCI_STATE
                beq +
                lda #UCI_ABORT
                sta UCI_CONTROL
-               lda UCI_STATUS
                and #UCI_ABORT
                bne -
+               rts

; Pushes the command and waits until it is processed
UciPush         lda #UCI_PUSH_CMD
                sta UCI_CONTROL
-               lda UCI_STATUS
                and #UCI_STATE
                cmp #UCI_STATE_BUSY
                beq -
                rts

; Reads the response: first two data bytes to Data0/1, the rest to
; ZP_FB/FC (if StoreOn, up to the end of RxBuf), the first two status
; chars to Stat0/1. Then accepts the data.
UciResult       lda #0
                sta DataCnt
                sta DataCnt+1
                sta StatCnt
.data           lda UCI_STATUS
                bpl .status                     ; bit 7: data available
                lda UCI_RESP_DATA
                ldx DataCnt+1
                bne .store
                ldx DataCnt
                bne +
                sta Data0
                beq .count                      ; jmp
+               dex
                bne .store
                sta Data1
                jmp .count
.store          ldx StoreOn
                beq .count
                ldx ZP_FC
                cpx #>RxBufEnd
                bcs .count                      ; buffer full
                ldy #0
                sta (ZP_FB),y
                inc ZP_FB
                bne .count
                inc ZP_FC
.count          inc DataCnt
                bne .data
                inc DataCnt+1
                jmp .data
.status         lda UCI_STATUS
                and #UCI_STAT_AV
                beq .accept
                lda UCI_STATUS_DATA
                ldx StatCnt
                cpx #2
                bcs +
                sta Stat0,x
                inc StatCnt
+               jmp .status
.accept         lda #UCI_DATA_ACC
                sta UCI_CONTROL
-               lda UCI_STATUS
                and #UCI_DATA_ACC
                bne -
                rts

!zone Control_Action_Paint
; X is ControlType
CtrlAction      rts                             ; Must be provided if new controls are registered

; X is ControlType
PaintCtrls      cpx #CT_RR_GRAPH
                beq PaintGraph
                rts

; FDFE points to position of control in paint buffer
; 0203 points to position of control in color buffer
; Each cell shows the part of its column's height within the row:
; empty, 1..7 pixels from the bottom or full
PaintGraph      lda #GRAPH_H-1
                sta PaintRow                    ; row from the bottom
.row            lda PaintRow
                asl
                asl
                asl
                sta RowBase                     ; height below this row
                ldy #GRAPH_W-1
.cell           lda Height,y
                sec
                sbc RowBase
                beq .empty
                bcc .empty
                cmp #8
                bcc +
                lda #8
+               ora #APP_CHAR_FILL              ; (APP_CHAR_FILL+1..+8)
                sta (ZP_FD),y
                lda ColColor,y
                sta ($02),y
                jmp .next
.empty          lda #APP_CHAR_FILL              ; empty, or grid line at the
                ldx PaintRow                    ; levels
                cpx #3
                beq +
                cpx #5
                bne ++
+               lda #APP_CHAR_GRID
++              sta (ZP_FD),y
                lda #COL_GRID
                sta ($02),y
.next           dey
                bpl .cell
                jsr GUI_AddBufWidthToFD         ; one char down in paint buffer
                jsr GUI_AddBufWidthTo02         ; one char down in color buffer
                dec PaintRow
                bpl .row
                rts

!zone Data
;----------------------------------------------------------------------
; Data
;----------------------------------------------------------------------
; Place that is fetched at the start (empty: none), e.g. !pet "Erkelenz",0
DefaultPlace    !pet 0

; Variables
PendingFetch    !byte 0
Mode            !byte MODE_NAME
HaveCoords      !byte 0
RefreshCnt      !word 0
InputLen        !byte 0
Subst           !byte 0
DidSubst        !byte 0
UrlIdx          !byte 0
UmlIdx          !byte 0
GeoFound        !byte 0
OutPos          !byte 0
ReqLen          !byte 0
Socket          !byte 0
StoreOn         !byte 0
DataCnt         !word 0
Data0           !byte 0
Data1           !byte 0
StatCnt         !byte 0
Stat0           !byte 0
Stat1           !byte 0
Tries           !word 0
NumVal          !byte 0
IntPart         !byte 0
FracPart        !byte 0
Acc             !word 0
DivLo           !byte 0
DivHi           !byte 0
Divisor         !byte 0
MulCnt          !byte 0
Col             !byte 0
Idx             !byte 0
Idx2            !byte 0
Digits          !byte 0
; Variables of PaintCtrls
PaintRow        !byte 0
RowBase         !byte 0

EditBuf         !fill PLACE_LEN," "
                !byte 0
TypedLow        !fill PLACE_LEN+1,0
GeoName         !fill NAME_MAX,0
GeoCmp          !fill NAME_MAX,0
GeoNameLen      !byte 0
GeoLat          !fill NUM_MAX,0
GeoLatLen       !byte 0
GeoLon          !fill NUM_MAX,0
GeoLonLen       !byte 0
GeoCC           !byte 0,0
PlaceName       !fill NAME_MAX,0
PlaceNameLen    !byte 0
PlaceLat        !fill NUM_MAX,0
PlaceLatLen     !byte 0
PlaceLon        !fill NUM_MAX,0
PlaceLonLen     !byte 0
PlaceCC         !byte 0,0
Times           !fill NUM_VALUES*5,0
ValLo           !fill NUM_VALUES,0
ValHi           !fill NUM_VALUES,0
Height          !fill GRAPH_W,0
ColColor        !fill GRAPH_W,0

; Tables
Div3            !byte 0,0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6,7,7,7
Mod3            !byte 0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2
Mul10           !byte 0,10,20,30,40,50,60,70,80,90
HexDigits       !text "0123456789ABCDEF"
; "ae", "oe", "ue" in the input -> UTF-8 umlaut ($c3 + UmlUtf)
UmlBase         !text "aou"
UmlUtf          !byte $a4,$b6,$bc
; UTF-8 umlauts ($c3 + UmlCode) in names -> two ASCII chars
UmlCode         !byte $a4,$b6,$bc,$84,$96,$9c,$9f
UmlText1        !text "aouAOUs"
UmlText2        !text "eeeeees"
; Not allowed in the place input (would break the URL)
Forbidden       !byte $22,$23,$25,$26,$2b,$2f,$3d,$3f,0 ; " # % & + / = ?
; Heights: number of thresholds <= value (1/100 mm per 15 min,
; mm/h = value/25). Log scale: 1 mm/h at height 32, 5 mm/h at 48,
; 20 mm/h at 64.
ThrLo           !byte 1,1,1,1,1,2,2,2,2,2,3,3,3,4,4,5
                !byte 5,6,6,7,7,8,9,10,11,12,14,15,17,18,20,23
                !byte 25,28,31,34,37,41,46,51,56,62,68,76,84,92,102,113
                !byte 125,137,150,165,181,198,218,239,6,31,59,89,123,160,200,244
ThrHi           !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
                !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
                !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
                !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1

; HTTP (ASCII)
Host_Geo        !text "geocoding-api.open-meteo.com",0
Host_Forecast   !text "api.open-meteo.com",0
Req_Geo1        !text "GET /v1/search?name=",0
Req_Geo2        !text "&count=1&language=de HTTP/1.0",13,10
                !text "Host: geocoding-api.open-meteo.com",13,10,13,10,0
Req_Fc1         !text "GET /v1/forecast?latitude=",0
Req_Fc2         !text "&longitude=",0
Req_Fc3         !text "&minutely_15=precipitation&forecast_minutely_15=9"
                !text "&timezone=auto&format=csv HTTP/1.0",13,10
                !text "Host: api.open-meteo.com",13,10,13,10,0
; Search patterns (ASCII)
Pat_Name        !text $22,"name",$22,":",$22,0
Pat_Lat         !text $22,"latitude",$22,":",0
Pat_Lon         !text $22,"longitude",$22,":",0
Pat_CC          !text $22,"country_code",$22,":",$22,0
Pat_CsvHead     !text "time,precipitation",0
Pat_T           !text "T",0
Pat_Comma       !text ",",0

Str_Title_App   !pet "Regenradar",0

; Definition of app window
; type, bits, xpos, ypos, width, height, address of string in title bar, address of wnd proc
Wnd_RainRadar   !byte WT_RAINRADAR, %00100001, 3, 1, 35, GRAPH_Y + GRAPH_H + 4
                !byte <Str_Title_App, >Str_Title_App
                !byte <RR_WndProc, >RR_WndProc
; Followed by control definitions (necessary for call CreateWindowEx)
; type, xpos, ypos, width, height, control string (null terminated)
                ;0
                !byte CT_MENUBAR, <RRMenubar, >RRMenubar, 0, 0
                !pet 0
                ;1
                !byte CT_LABEL, 1, 2, 4, 1
                !pet "Ort:",0
                ;2 (CTRL_EDIT)
                !byte CT_EDIT_SL, 5, 1, PLACE_LEN + 3, 3
                !pet 0
                ;3 (CTRL_BUTTON)
                !byte CT_BUTTON, 25, 1, 9, 3
                !pet "Refresh",0
                ;4
                !byte CT_LABEL, 1, 5, TEXT_LEN, 1
StatusText      !pet "Ort eingeben, RETURN"
                !fill TEXT_LEN - 20," "
                !byte 0
                ;5
                !byte CT_LABEL, 1, 6, TEXT_LEN, 1
SummaryText     !fill TEXT_LEN," "
                !byte 0
                ;6
                !byte CT_LABEL, 1, GRAPH_Y, 6, 1
                !pet "stark",0
                ;7
                !byte CT_LABEL, 1, GRAPH_Y + 2, 6, 1
                !pet "mittel",0
                ;8
                !byte CT_LABEL, 1, GRAPH_Y + 6, 6, 1
                !pet "leicht",0
                ;9
                !byte CT_RR_GRAPH, GRAPH_X, GRAPH_Y, GRAPH_W, GRAPH_H
                !pet 0
                ;10
                !byte CT_LABEL, GRAPH_X, GRAPH_Y + GRAPH_H, GRAPH_W, 1
TimeText        !fill GRAPH_W," "
                !byte 0
                ;11 (CTRL_MODE_NAME)
                !byte CT_RADIOBUTTONGROUP, 1, 4, 6, 1
                !pet 0
                ;12 (CTRL_MODE_COORDS)
                !byte CT_RADIOBUTTONGROUP, 9, 4, 13, 1
                !pet 0
                ; closing zero byte
                !byte 0

; Status texts (at most TEXT_LEN chars)
Msg_EnterPlace  !pet "Bitte Ort eingeben",0
Msg_HintName    !pet "Ort eingeben, RETURN",0
Msg_HintCoords  !pet "Breite,Laenge eingeben, RETURN",0
Msg_BadCoords   !pet "Ungueltige Koordinaten",0
Msg_NoUltimate  !pet "Kein Ultimate Command Interface",0
Msg_Search      !pet "Suche Ort...",0
Msg_NotFound    !pet "Ort nicht gefunden",0
Msg_Load        !pet "Lade Vorhersage...",0
Msg_NetError    !pet "Keine Verbindung",0
Msg_NoData      !pet "Keine Vorhersage erhalten",0
; Summary
Txt_NoRain      !pet "Kein Regen bis ",0
Txt_RainFrom    !pet "Regen ab ",0
Txt_RainUntil   !pet "Regen bis ",0
Txt_RainLong    !pet "Regen ueber 2 Std.",0
Txt_Max         !pet ", max ",0
Txt_Unit        !pet " mm/h",0

; Message boxes
Str_Mess_Help   !pet "Ort oder Koordinaten\(z.B. 51.08,6.32)\eingeben und RETURN\druecken.\Die Kurve zeigt den\Niederschlag der\naechsten 2 Stunden.\Daten: Open-Meteo\Netz: Ultimate CI",0
Str_Mess_About  !pet "Regenradar\Niederschlag der\naechsten 2 Stunden\fuer GUI64",0

; Definition of menu bar
RRMenubar       !word Menu_RR_Radar, Menu_RR_Help
Str_RRMenubar   !pet "Radar",0,"?",0
; Radio buttons of the input mode
Str_ModeName    !pet "Name",0
Str_ModeCoords  !pet "Koordinaten",0
; Definition of menus
; Format: ID, max_str_len, item_count, StringList
Menu_RR_Radar   !pet ID_MENU_RADAR,13,2,"Aktualisieren",0,"Beenden",0
Menu_RR_Help    !pet ID_MENU_HELP,5,2,"Hilfe",0,"Info",0

; Chars
; Definition of new chars (8 bytes each). Set pixels get the cell color,
; cleared pixels show the dark background (like the GUI64 charset).
APP_CHAR_FILL   = APP_CHAR_0    ; +0: empty, +1..+8: filled 1..8 pixels
                                ; from the bottom (must be APP_CHAR_0)
APP_CHAR_GRID   = APP_CHAR_9    ; dotted line at the top
CharList        !byte 0,0,0,0,0,0,0,0
                !byte 0,0,0,0,0,0,0,$ff
                !byte 0,0,0,0,0,0,$ff,$ff
                !byte 0,0,0,0,0,$ff,$ff,$ff
                !byte 0,0,0,0,$ff,$ff,$ff,$ff
                !byte 0,0,0,$ff,$ff,$ff,$ff,$ff
                !byte 0,0,$ff,$ff,$ff,$ff,$ff,$ff
                !byte 0,$ff,$ff,$ff,$ff,$ff,$ff,$ff
                !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
                !byte %10001000,0,0,0,0,0,0,0
NUM_APP_CHARS   = 10

CodeEnd
; Buffers behind the program (not part of the file)
RX_SIZE         = $0800
RxBuf           = (CodeEnd + $ff) & $ff00
RxBufEnd        = RxBuf + RX_SIZE       ; (+1 byte for the end marker)
ReqBuf          = RxBufEnd + 1          ; 256 bytes
BuffersEnd      = ReqBuf + 256
!if (BuffersEnd) > ($d000) {
                !error "Buffers overlap $d000"
}

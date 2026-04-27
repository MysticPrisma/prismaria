;
; main.s
; Alan Gomez Pasillas, 16/08/2026
; https://mysticprisma.github.io/prismaria/
;

;
; iNES header
;

.segment "HEADER"

INES_MAPPER = 0 ; 0 = NROM
INES_MIRROR = 1 ; 0 = horizontal mirroring, 1 = vertical mirroring
INES_SRAM   = 0 ; 1 = battery backed SRAM at $6000-7FFF

.byte 'N', 'E', 'S', $1A ; ID
.byte $02 ; 16k PRG chunk count
.byte $01 ; 8k CHR chunk count
.byte INES_MIRROR | (INES_SRAM << 1) | ((INES_MAPPER & $f) << 4)
.byte (INES_MAPPER & %11110000)
.byte $0, $0, $0, $0, $0, $0, $0, $0 ; padding

;
; CHR ROM
;

.segment "TILES"
.incbin "backgrounds.chr"
.incbin "sprite.chr"

;
; vectors placed at top 6 bytes of memory area
;

.segment "VECTORS"
.word nmi
.word reset
.word irq

;
; reset routine
;

.segment "CODE"
reset:
	sei       ; mask interrupts
	lda #0
	sta $2000 ; disable NMI
	sta $2001 ; disable rendering
	sta $4015 ; disable APU sound
	sta $4010 ; disable DMC IRQ
	lda #$40
	sta $4017 ; disable APU IRQ
	cld       ; disable decimal mode
	ldx #$FF
	txs       ; initialize stack
	; wait for first vblank
	bit $2002
	:
		bit $2002
		bpl :-
	; clear all RAM to 0
	lda #0
	ldx #0
	:
		sta $0000, X
		sta $0100, X
		sta $0200, X
		sta $0300, X
		sta $0400, X
		sta $0500, X
		sta $0600, X
		sta $0700, X
		inx
		bne :-
	; place all sprites offscreen at Y=255
	lda #255
	ldx #0
	:
		sta oam, X
		inx
		inx
		inx
		inx
		bne :-
	; wait for second vblank
	:
		bit $2002
		bpl :-
	; NES is initialized, ready to begin!
	; enable the NMI for graphical updates, and jump to our main program
	lda #%10001000
	sta $2000

    ; Initialize FamiStudio engine
    ldx #<music_title
    ldy #>music_title
    lda #1                 ; 1 = NTSC, 0 = PAL
    jsr famistudio_init

    ; Play the first song (Song 0)
    lda #0
    jsr famistudio_music_play
	jmp main

;
; nmi routine
;

.segment "ZEROPAGE"
nmi_lock:       .res 1 ; prevents NMI re-entry
nmi_count:      .res 1 ; is incremented every NMI
nmi_ready:      .res 1 ; set to 1 to push a PPU frame update, 2 to turn rendering off next NMI
nmt_update_len: .res 1 ; number of bytes in nmt_update buffer
scroll_x:       .res 1 ; x scroll position
scroll_y:       .res 1 ; y scroll position
scroll_nmt:     .res 1 ; nametable select (0-3 = $2000,$2400,$2800,$2C00)
temp:           .res 1 ; temporary variable
ptr:            .res 2 ; pointer of 16-bits
state:          .res 1 ; 0 = title, 1 = level1, etc.

.segment "BSS"
nmt_update: .res 256 ; nametable update entry buffer for PPU update
palette:    .res 32  ; palette buffer for PPU update

.segment "OAM"
oam: .res 256        ; sprite OAM data to be uploaded by DMA

.segment "CODE"
nmi:
	; save registers
	pha
	txa
	pha
	tya
	pha
	; prevent NMI re-entry
	lda nmi_lock
	beq :+
		jmp @nmi_end
	:
	lda #1
	sta nmi_lock
	; increment frame counter
	inc nmi_count
	;
	lda nmi_ready
	bne :+ ; nmi_ready == 0 not ready to update PPU
		jmp @ppu_update_end
	:
	cmp #2 ; nmi_ready == 2 turns rendering off
	bne :+
		lda #%00000000
		sta $2001
		ldx #0
		stx nmi_ready
		jmp @ppu_update_end
	:
	; sprite OAM DMA
	ldx #0
	stx $2003
	lda #>oam
	sta $4014
	; palettes
    lda $2002 ;reset latch
    lda #$3F
    sta $2006
    lda #$00
    sta $2006
    ldx #0
    @pal_loop:
        lda palette, x
        sta $2007
        inx
        cpx #32
        bcc @pal_loop
	; nametable update
	ldx #0
	cpx nmt_update_len
	bcs @scroll
	@nmt_update_loop:
		lda nmt_update, X
		sta $2006
		inx
		lda nmt_update, X
		sta $2006
		inx
		lda nmt_update, X
		sta $2007
		inx
		cpx nmt_update_len
		bcc @nmt_update_loop
	lda #0
	sta nmt_update_len
@scroll:
	lda scroll_nmt
	and #%00000011 ; keep only lowest 2 bits to prevent error
	ora #%10001000
	sta $2000
	lda scroll_x
	sta $2005
	lda scroll_y
	sta $2005
	; enable rendering
	lda #%00011110
	sta $2001
	; flag PPU update complete
	ldx #0
	stx nmi_ready
@ppu_update_end:
    jsr famistudio_update
	; unlock re-entry flag
	lda #0
	sta nmi_lock
@nmi_end:
	; restore registers and return
	pla
	tay
	pla
	tax
	pla
	rti

;
; irq
;

.segment "CODE"
irq:
	rti

;
; drawing utilities
;

.segment "CODE"

; ppu_update: waits until next NMI, turns rendering on (if not already), uploads OAM, palette, and nametable update to PPU
ppu_update:
	lda #1
	sta nmi_ready
	:
		lda nmi_ready
		bne :-
	rts

; ppu_skip: waits until next NMI, does not update PPU
ppu_skip:
	lda nmi_count
	:
		cmp nmi_count
		beq :-
	rts

; ppu_off: waits until next NMI, turns rendering off (now safe to write PPU directly via $2007)
ppu_off:
	lda #2
	sta nmi_ready
	:
		lda nmi_ready
		bne :-
	rts

; ppu_address_tile: use with rendering off, sets memory address to tile at X/Y, ready for a $2007 write
;   Y =  0- 31 nametable $2000
;   Y = 32- 63 nametable $2400
;   Y = 64- 95 nametable $2800
;   Y = 96-127 nametable $2C00
ppu_address_tile:
	lda $2002 ; reset latch
	tya
	lsr
	lsr
	lsr
	ora #$20 ; high bits of Y + $20
	sta $2006
	tya
	asl
	asl
	asl
	asl
	asl
	sta temp
	txa
	ora temp
	sta $2006 ; low bits of Y + X
	rts

; ppu_update_tile: can be used with rendering on, sets the tile at X/Y to tile A next time you call ppu_update
ppu_update_tile:
	pha ; temporarily store A on stack
	txa
	pha ; temporarily store X on stack
	ldx nmt_update_len
	tya
	lsr
	lsr
	lsr
	ora #$20 ; high bits of Y + $20
	sta nmt_update, X
	inx
	tya
	asl
	asl
	asl
	asl
	asl
	sta temp
	pla ; recover X value (but put in A)
	ora temp
	sta nmt_update, X
	inx
	pla ; recover A value (tile)
	sta nmt_update, X
	inx
	stx nmt_update_len
	rts

; ppu_update_byte: like ppu_update_tile, but X/Y makes the high/low bytes of the PPU address to write
;    this may be useful for updating attribute tiles
ppu_update_byte:
	pha ; temporarily store A on stack
	tya
	pha ; temporarily store Y on stack
	ldy nmt_update_len
	txa
	sta nmt_update, Y
	iny
	pla ; recover Y value (but put in Y)
	sta nmt_update, Y
	iny
	pla ; recover A value (byte)
	sta nmt_update, Y
	iny
	sty nmt_update_len
	rts

;
; gamepad
;

PAD_A      = $01
PAD_B      = $02
PAD_SELECT = $04
PAD_START  = $08
PAD_U      = $10
PAD_D      = $20
PAD_L      = $40
PAD_R      = $80

.segment "ZEROPAGE"
gamepad: .res 1

.segment "CODE"
; gamepad_poll: this reads the gamepad state into the variable labelled "gamepad"
;   This only reads the first gamepad, and also if DPCM samples are played they can
;   conflict with gamepad reading, which may give incorrect results.
gamepad_poll:
	; strobe the gamepad to latch current button state
	lda #1
	sta $4016
	lda #0
	sta $4016
	; read 8 bytes from the interface at $4016
	ldx #8
	:
		pha
		lda $4016
		; combine low two bits and store in carry bit
		and #%00000011
		cmp #%00000001
		pla
		; rotate carry into gamepad variable
		ror
		dex
		bne :-
	sta gamepad
	rts

;
; main
;

.segment "RODATA"
title_part_one: .byte 41,00,48,49,48,49,52,54,55,58,59,48,49,48,49,52,48,49,00,41 ;20 chars
title_part_two: .byte 41,00,50,60,50,61,53,56,57,53,53,50,51,50,61,53,50,51,00,41 ;20 chars
;press_start: .byte 26,28,15,29,29,00,00,29,30,11,28,30 ;12 chars
press_start: .byte 42,43,44,00,00,45,46,47 ;6 chars
company: .byte 37,2,10,2,6,0,23,35,29,30,19,13,0,26,28,19,29,23,11,38 ;20 chars

title_animation:
.byte $0F
.byte $21
.byte $30
.byte $30
.byte $30
.byte $30
.byte $21
.byte $0F

title_palette:
.byte $0F,$30,$21,$11 ; bg0 title-screen - blue, bluelight, white
.byte $21,$29,$1A,$0B ; bg1 level-one
.byte $0F,$01,$11,$21 ; bg2 blue
.byte $0F,$00,$10,$30 ; bg3 greyscale
.byte $0F,$18,$28,$38 ; sp0 yellow
.byte $0F,$14,$24,$34 ; sp1 purple
.byte $0F,$1B,$2B,$3B ; sp2 teal
.byte $0F,$12,$22,$32 ; sp3 marine

level_one_palette:
.byte $21,$0B,$1A,$39 ; bg0 level-one
.byte $21,$30,$20,$11 ; bg1 
.byte $21,$30,$20,$11 ; bg2 
.byte $21,$30,$20,$11 ; bg3 
.byte $21,$30,$20,$11 ; sp0 
.byte $21,$30,$20,$11 ; sp1 
.byte $21,$30,$20,$11 ; sp2 
.byte $21,$30,$20,$11 ; sp3 

.segment "ZEROPAGE"
temp_x:   .res 1
temp_y:   .res 1

.segment "CODE"
main:
    lda #0
    sta state
	; setup 
	ldx #0
	:
		lda title_palette, X
		sta palette, X
		inx
		cpx #32
		bcc :-

	jsr setup_background_title
	; show the screen
	jsr ppu_update

	; main loop
main_loop:
	; read gamepad
	jsr gamepad_poll

    lda state
    cmp #0
    beq state_title
	; respond to gamepad state
	jmp main_loop

state_title:
	lda gamepad
	and #PAD_START
	beq :+
        jsr start_game
        jmp main_loop
	:
    jsr animate_title
    jsr ppu_update
    jmp main_loop

start_game:
    lda #1
    sta state
    jsr famistudio_music_stop
    jsr ppu_off

    ; setting palette
    ldx #0
    :   lda level_one_palette, x  ; Grab colors from the 2nd palette set
        sta palette, x            ; Put them in the 1st palette slot
        inx
        cpx #32
        bcc :-
    
    jsr setup_level_one
    jsr ppu_update
    rts

.proc draw_row
    sta ptr
    sty ptr+1
    ldy #0
loop:
    lda (ptr), y
    sta $2007
    iny
    dex
    bne loop
    rts
.endproc

.proc animate_title
    lda nmi_count
    lsr
    lsr
    lsr
    and #7
    tax
    lda title_animation, x
    sta palette+1
    rts
.endproc

.proc clear_nametable
    lda $2002 ; reset latch
	lda #$20
	sta $2006
	lda #$00
	sta $2006
	; empty nametable
	lda #0
	ldy #30 ; 30 rows
	:
		ldx #32 ; 32 columns
		:
			sta $2007
			dex
			bne :-
		dey
		bne :--
	; set all attributes to 0
	ldx #64 ; 64 bytes
	:
		sta $2007
		dex
		bne :-
    rts
.endproc

setup_background_title:
	; first nametable, start by clearing to empty
    jsr clear_nametable

    ; First Line
    ldy #6
    ldx #6
    jsr ppu_address_tile
    lda #39 ;first corner
    sta $2007
    lda #40
    ldx #18
    :
        sta $2007 ;drawing row
        dex
        bne :-
    lda #39 ;second corner
    sta $2007
    
    ; Two Dots
    ldy #7
    ldx #6
    jsr ppu_address_tile
    lda #41
    sta $2007
    ldx #25
    jsr ppu_address_tile
    lda #41
    sta $2007
    
    ; Title
    ldy #8
    ldx #6
    jsr ppu_address_tile
    lda #<title_part_one
    ldy #>title_part_one
    ldx #20
    jsr draw_row

    ldy #9
    ldx #6
    jsr ppu_address_tile
    lda #<title_part_two
    ldy #>title_part_two
    ldx #20
    jsr draw_row
    
    ; Two Dots
    ldy #10
    ldx #6
    jsr ppu_address_tile
    lda #41
    sta $2007
    ldx #25
    jsr ppu_address_tile
    lda #41
    sta $2007
    
    ; Second Line
    ldy #11
    ldx #6
    jsr ppu_address_tile
    lda #39
    sta $2007
    lda #40
    ldx #18
    :
        sta $2007
        dex
        bne :-
    lda #39
    sta $2007
    
    ; Press Start
    ldy #16
    ldx #12
    jsr ppu_address_tile
    lda #<press_start
    ldy #>press_start
    ldx #8
    jsr draw_row
    
    ; Company
    ldy #22
    ldx #6
    jsr ppu_address_tile
    lda #<company
    ldy #>company
    ldx #20
    jsr draw_row

	rts

setup_level_one:
    jsr clear_nametable
    
    ; Sun / Moon
    ldy #06
    ldx #05
    jsr ppu_address_tile
    lda #68
    sta $2007
    lda #69
    sta $2007
    ldy #07
    ldx #05
    jsr ppu_address_tile
    lda #70
    sta $2007
    lda #71
    sta $2007
    
    ; Stars
    ldy #01
    ldx #02
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #03
    ldx #25
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #05
    ldx #14
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #08
    ldx #19
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #10
    ldx #06
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #12
    ldx #28
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #15
    ldx #03
    jsr ppu_address_tile
    lda #62
    sta $2007
    ldy #14
    ldx #12
    jsr ppu_address_tile
    lda #62
    sta $2007
    
    ; Ground
    ldy #20
    ldx #26
    jsr ppu_address_tile
    lda #66
    sta $2007
    lda #67
    sta $2007
    lda #64
    sta $2007
    lda #65
    sta $2007
    lda #64
    sta $2007
    lda #65
    sta $2007
    ldy #21
    ldx #24
    jsr ppu_address_tile
    lda #66
    sta $2007
    lda #67
    sta $2007
    ldx #06
    lda #65
    :   
        eor #01
        cmp #64
        sta $2007
        dex
        bne :-
    ldy #22
    ldx #20
    jsr ppu_address_tile
    lda #66
    sta $2007
    lda #67
    sta $2007
    ldx #10
    lda #65
    :   
        eor #01
        cmp #64
        sta $2007
        dex
        bne :-
    ldy #23
    ldx #14
    jsr ppu_address_tile
    lda #66
    sta $2007
    lda #67
    sta $2007
    ldx #176
    lda #65
    :   
        eor #01
        cmp #64
        sta $2007
        dex
        bne :-


    rts

    ; --- Sound Engine ---
.include "famistudio_ca65.s"
.include "msc-title.s"

;
; end of file
;

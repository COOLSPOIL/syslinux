; -*- fundamental -*- (asm-mode sucks)
; $Id$
; ****************************************************************************
;
;  extlinux.asm
;
;  A program to boot Linux kernels off an ext2/ext3 filesystem.
;
;   Copyright (C) 1994-2004  H. Peter Anvin
;
;  This program is free software; you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, Inc., 53 Temple Place Ste 330,
;  Boston MA 02111-1307, USA; either version 2 of the License, or
;  (at your option) any later version; incorporated herein by reference.
; 
; ****************************************************************************

%define IS_EXTLINUX 1
%include "macros.inc"
%include "config.inc"
%include "kernel.inc"
%include "bios.inc"
%include "tracers.inc"

%include "ext2_fs.inc"

;
; Some semi-configurable constants... change on your own risk.
;
my_id		equ extlinux_id
FILENAME_MAX_LG2 equ 8			; log2(Max filename size Including final null)
FILENAME_MAX	equ (1 << FILENAME_MAX)	; Max mangled filename size
NULLFILE	equ ' '			; First char space == null filename
retry_count	equ 6			; How patient are we with the disk?
%assign HIGHMEM_SLOP 0			; Avoid this much memory near the top
LDLINUX_MAGIC	equ 0x3eb202fe		; A random number to identify ourselves with

MAX_OPEN_LG2	equ 6			; log2(Max number of open files)
MAX_OPEN	equ (1 << MAX_OPEN_LG2)

SECTOR_SHIFT	equ 9
SECTOR_SIZE	equ (1 << SECTOR_SHIFT)

;
; This is what we need to do when idle
;
%macro	RESET_IDLE 0
	; Nothing
%endmacro
%macro	DO_IDLE 0
	; Nothing
%endmacro

;
; The following structure is used for "virtual kernels"; i.e. LILO-style
; option labels.  The options we permit here are `kernel' and `append
; Since there is no room in the bottom 64K for all of these, we
; stick them at vk_seg:0000 and copy them down before we need them.
;
; Note: this structure can be added to, but it must 
;
%define vk_power	6		; log2(max number of vkernels)
%define	max_vk		(1 << vk_power)	; Maximum number of vkernels
%define vk_shift	(16-vk_power)	; Number of bits to shift
%define vk_size		(1 << vk_shift)	; Size of a vkernel buffer

		struc vkernel
vk_vname:	resb FILENAME_MAX	; Virtual name **MUST BE FIRST!**
vk_rname:	resb FILENAME_MAX	; Real name
vk_appendlen:	resw 1
		alignb 4
vk_append:	resb max_cmd_len+1	; Command line
		alignb 4
vk_end:		equ $			; Should be <= vk_size
		endstruc

%ifndef DEPEND
%if (vk_end > vk_size) || (vk_size*max_vk > 65536)
%error "Too many vkernels defined, reduce vk_power"
%endif
%endif

;
; Segment assignments in the bottom 640K
; Stick to the low 512K in case we're using something like M-systems flash
; which load a driver into low RAM (evil!!)
;
; 0000h - main code/data segment (and BIOS segment)
;
real_mode_seg	equ 4000h
cache_seg	equ 3000h		; 64K area for metadata cache
vk_seg          equ 2000h		; Virtual kernels
xfer_buf_seg	equ 1000h		; Bounce buffer for I/O to high mem
comboot_seg	equ real_mode_seg	; COMBOOT image loading zone

;
; File structure.  This holds the information for each currently open file.
;
		struc open_file_t
file_sector	resd 1			; Next linear sector to read
file_left	resd 1			; Number of sectors left
file_in_sec	resd 1			; Sector where inode lives
file_in_off	resw 1
		resw 1
		endstruc

%ifndef DEPEND
%if (open_file_t_size & (open_file_t_size-1))
%error "open_file_t is not a power of 2"
%endif
%endif

; ---------------------------------------------------------------------------
;   BEGIN CODE
; ---------------------------------------------------------------------------

;
; Memory below this point is reserved for the BIOS and the MBR
;
BSS_START	equ 1000h
		section .bss start=BSS_START
trackbufsize	equ 8192
trackbuf	resb trackbufsize	; Track buffer goes here
getcbuf		resb trackbufsize
		; ends at 5000h

		alignb 8

		; Expanded superblock
SuperInfo	equ $
		resq 16			; The first 16 bytes expanded 8 times
FAT		resd 1			; Location of (first) FAT
RootDirArea	resd 1			; Location of root directory area
RootDir		resd 1			; Location of root directory proper
DataArea	resd 1			; Location of data area
RootDirSize	resd 1			; Root dir size in sectors
TotalSectors	resd 1			; Total number of sectors
EndSector	resd 1			; Location of filesystem end
ClustSize	resd 1			; Bytes/cluster
ClustMask	resd 1			; Sectors/cluster - 1
CachePtrs	resw 65536/SECTOR_SIZE	; Cached sector pointers
NextCacheSlot	resw 1			; Next cache slot to occupy
CopySuper	resb 1			; Distinguish .bs versus .bss
DriveNumber	resb 1			; BIOS drive number
ClustShift	resb 1			; Shift count for sectors/cluster
ClustByteShift	resb 1			; Shift count for bytes/cluster

		alignb open_file_t_size
Files		resb MAX_OPEN*open_file_t_size

;
; Constants for the xfer_buf_seg
;
; The xfer_buf_seg is also used to store message file buffers.  We
; need two trackbuffers (text and graphics), plus a work buffer
; for the graphics decompressor.
;
xbs_textbuf	equ 0			; Also hard-coded, do not change
xbs_vgabuf	equ trackbufsize
xbs_vgatmpbuf	equ 2*trackbufsize


		section .text
                org 7C00h
;
; Some of the things that have to be saved very early are saved
; "close" to the initial stack pointer offset, in order to
; reduce the code size...
;
StackBuf	equ $-44-32		; Start the stack here (grow down - 4K)
PartInfo	equ StackBuf		; Saved partition table entry
FloppyTable	equ PartInfo+16		; Floppy info table (must follow PartInfo)
OrigFDCTabPtr	equ StackBuf-4		; The high dword on the stack

;
; Primary entry point.  Tempting as though it may be, we can't put the
; initial "cli" here; the jmp opcode in the first byte is part of the
; "magic number" (using the term very loosely) for the DOS superblock.
;
bootsec		equ $
		jmp short start		; 2 bytes
		nop			; 1 byte
;
; "Superblock" follows -- it's in the boot sector, so it's already
; loaded and ready for us
;
bsOemName	db 'EXTLINUX'		; The SYS command sets this, so...
;
; These are the fields we actually care about.  We end up expanding them
; all to dword size early in the code, so generate labels for both
; the expanded and unexpanded versions.
;
%macro		superb 1
bx %+ %1	equ SuperInfo+($-superblock)*8+4
bs %+ %1	equ $
		zb 1
%endmacro
%macro		superw 1
bx %+ %1	equ SuperInfo+($-superblock)*8
bs %+ %1	equ $
		zw 1
%endmacro
%macro		superd 1
bx %+ %1	equ $			; no expansion for dwords
bs %+ %1	equ $
		zd 1
%endmacro
superblock	equ $
		superw BytesPerSec
		superb SecPerClust
		superw ResSectors
		superb FATs
		superw RootDirEnts
		superw Sectors
		superb Media
		superw FATsecs
		superw SecPerTrack
		superw Heads
superinfo_size	equ ($-superblock)-1	; How much to expand
		superd Hidden
		superd HugeSectors
		;
		; This is as far as FAT12/16 and FAT32 are consistent
		;
		zb 54			; FAT12/16 need 26 more bytes,
					; FAT32 need 54 more bytes
superblock_len	equ $-superblock

SecPerClust	equ bxSecPerClust
;
; Note we don't check the constraints above now; we did that at install
; time (we hope!)
;
start:
		cli			; No interrupts yet, please
		cld			; Copy upwards
;
; Set up the stack
;
		xor ax,ax
		mov ss,ax
		mov sp,StackBuf		; Just below BSS
		mov es,ax
;
; DS:SI may contain a partition table entry.  Preserve it for us.
;
		mov cx,8		; Save partition info
		mov di,sp
		rep movsw

		mov ds,ax		; Now we can initialize DS...

;
; Now sautee the BIOS floppy info block to that it will support decent-
; size transfers; the floppy block is 11 bytes and is stored in the
; INT 1Eh vector (brilliant waste of resources, eh?)
;
; Of course, if BIOSes had been properly programmed, we wouldn't have
; had to waste precious space with this code.
;
		mov bx,fdctab
		lfs si,[bx]		; FS:SI -> original fdctab
		push fs			; Save on stack in case we need to bail
		push si

		; Save the old fdctab even if hard disk so the stack layout
		; is the same.  The instructions above do not change the flags
		mov [DriveNumber],dl	; Save drive number in DL
		and dl,dl		; If floppy disk (00-7F), assume no
					; partition table
		js harddisk

floppy:
		mov cl,6		; 12 bytes (CX == 0)
		; es:di -> FloppyTable already
		; This should be safe to do now, interrupts are off...
		mov [bx],di		; FloppyTable
		mov [bx+2],ax		; Segment 0
		fs rep movsw		; Faster to move words
		mov cl,[bsSecPerTrack]  ; Patch the sector count
		mov [di-8],cl
		; AX == 0 here
		int 13h			; Some BIOSes need this

		jmp short not_harddisk
;
; The drive number and possibly partition information was passed to us
; by the BIOS or previous boot loader (MBR).  Current "best practice" is to
; trust that rather than what the superblock contains.
;
; Would it be better to zero out bsHidden if we don't have a partition table?
;
; Note: di points to beyond the end of PartInfo
;
harddisk:
		test byte [di-16],7Fh	; Sanity check: "active flag" should
		jnz no_partition	; be 00 or 80
		mov eax,[di-8]		; Partition offset (dword)
		mov [bsHidden],eax
no_partition:
;
; Get disk drive parameters (don't trust the superblock.)  Don't do this for
; floppy drives -- INT 13:08 on floppy drives will (may?) return info about
; what the *drive* supports, not about the *media*.  Fortunately floppy disks
; tend to have a fixed, well-defined geometry which is stored in the superblock.
;
		; DL == drive # still
		mov ah,08h
		int 13h
		jc no_driveparm
		and ah,ah
		jnz no_driveparm
		shr dx,8
		inc dx			; Contains # of heads - 1
		mov [bsHeads],dx
		and cx,3fh
		mov [bsSecPerTrack],cx
no_driveparm:
not_harddisk:
;
; Ready to enable interrupts, captain
;
		sti


;
; Do we have EBIOS (EDD)?
;
eddcheck:
		mov bx,55AAh
		mov ah,41h		; EDD existence query
		mov dl,[DriveNumber]
		int 13h
		jc .noedd
		cmp bx,0AA55h
		jne .noedd
		test cl,1		; Extended disk access functionality set
		jz .noedd
		;
		; We have EDD support...
		;
		mov byte [getlinsec+1],getlinsec_ebios-(getlinsec+2)
.noedd:

;
; Load the first sector of LDLINUX.SYS; this used to be all proper
; with parsing the superblock and root directory; it doesn't fit
; together with EBIOS support, unfortunately.
;
		mov eax,[FirstSector]	; Sector start
		mov bx,ldlinux_sys	; Where to load it
		call getonesec
		
		; Some modicum of integrity checking
		cmp dword [ldlinux_magic],LDLINUX_MAGIC
		jne kaboom
		cmp dword [ldlinux_magic+4],HEXDATE
		jne kaboom

		; Go for it...
		jmp ldlinux_ent

;
; kaboom: write a message and bail out.
;
kaboom:
		xor si,si
		mov ss,si		
		mov sp,StackBuf-4 	; Reset stack
		mov ds,si		; Reset data segment
		pop dword [fdctab]	; Restore FDC table
.patch:		mov si,bailmsg
		call writestr		; Returns with AL = 0
		cbw			; AH <- 0
		int 16h			; Wait for keypress
		int 19h			; And try once more to boot...
.norge:		jmp short .norge	; If int 19h returned; this is the end

;
;
; writestr: write a null-terminated string to the console
;	    This assumes we're on page 0.  This is only used for early
;           messages, so it should be OK.
;
writestr:
.loop:		lodsb
		and al,al
                jz .return
		mov ah,0Eh		; Write to screen as TTY
		mov bx,0007h		; Attribute
		int 10h
		jmp short .loop
.return:	ret

;
; xint13: wrapper for int 13h which will retry 6 times and then die,
;	  AND save all registers except BP
;
xint13:
.again:
                mov bp,retry_count
.loop:          pushad
                int 13h
                popad
                jnc writestr.return
                dec bp
                jnz .loop
.disk_error:
		jmp strict near kaboom	; Patched


;
; getonesec: get one disk sector
;
getonesec:
		mov bp,1		; One sector
		; Fall through

;
; getlinsec: load a sequence of BP floppy sector given by the linear sector
;	     number in EAX into the buffer at ES:BX.  We try to optimize
;	     by loading up to a whole track at a time, but the user
;	     is responsible for not crossing a 64K boundary.
;	     (Yes, BP is weird for a count, but it was available...)
;
;	     On return, BX points to the first byte after the transferred
;	     block.
;
;            This routine assumes CS == DS, and trashes most registers.
;
; Stylistic note: use "xchg" instead of "mov" when the source is a register
; that is dead from that point; this saves space.  However, please keep
; the order to dst,src to keep things sane.
;
getlinsec:
		jmp strict short getlinsec_cbios	; This is patched

;
; getlinsec_ebios:
;
; getlinsec implementation for EBIOS (EDD)
;
getlinsec_ebios:
                mov si,dapa                     ; Load up the DAPA
                mov [si+4],bx
                mov [si+6],es
                mov [si+8],eax
.loop:
                push bp                         ; Sectors left
		call maxtrans			; Enforce maximum transfer size
.bp_ok:
                mov [si+2],bp
                mov dl,[DriveNumber]
                mov ah,42h                      ; Extended Read
                call xint13
                pop bp
                movzx eax,word [si+2]           ; Sectors we read
                add [si+8],eax                  ; Advance sector pointer
                sub bp,ax                       ; Sectors left
                shl ax,9                        ; 512-byte sectors
                add [si+4],ax                   ; Advance buffer pointer
                and bp,bp
                jnz .loop
                mov eax,[si+8]                  ; Next sector
                mov bx,[si+4]                   ; Buffer pointer
                ret

;
; getlinsec_cbios:
;
; getlinsec implementation for legacy CBIOS
;
getlinsec_cbios:
.loop:
		push eax
		push bp
		push bx

		movzx esi,word [bsSecPerTrack]
		movzx edi,word [bsHeads]
		;
		; Dividing by sectors to get (track,sector): we may have
		; up to 2^18 tracks, so we need to use 32-bit arithmetric.
		;
		xor edx,edx		; Zero-extend LBA to 64 bits
		div esi
		xor cx,cx
		xchg cx,dx		; CX <- sector index (0-based)
					; EDX <- 0
		; eax = track #
		div edi			; Convert track to head/cyl
		;
		; Now we have AX = cyl, DX = head, CX = sector (0-based),
		; BP = sectors to transfer, SI = bsSecPerTrack,
		; ES:BX = data target
		;

		call maxtrans			; Enforce maximum transfer size

		; Must not cross track boundaries, so BP <= SI-CX
		sub si,cx
		cmp bp,si
		jna .bp_ok
		mov bp,si
.bp_ok:	

		shl ah,6		; Because IBM was STOOPID
					; and thought 8 bits were enough
					; then thought 10 bits were enough...
		inc cx			; Sector numbers are 1-based, sigh
		or cl,ah
		mov ch,al
		mov dh,dl
		mov dl,[DriveNumber]
		xchg ax,bp		; Sector to transfer count
		mov ah,02h		; Read sectors
		call xint13
		movzx ecx,al
		shl ax,9		; Convert sectors in AL to bytes in AX
		pop bx
		add bx,ax
		pop bp
		pop eax
		add eax,ecx
		sub bp,cx
		jnz .loop
		ret

;
; Truncate BP to MaxTransfer
;
maxtrans:
		cmp bp,[MaxTransfer]
		jna .ok
		mov bp,[MaxTransfer]
.ok:		ret

;
; Error message on failure
;
bailmsg:	db 'Boot failed', 0Dh, 0Ah, 0

;
; EBIOS disk address packet
;
		align 4, db 0
dapa:
                dw 16                           ; Packet size
.count:         dw 0                            ; Block count
.off:           dw 0                            ; Offset of buffer
.seg:           dw 0                            ; Segment of buffer
.lba:           dd 0                            ; LBA (LSW)
                dd 0                            ; LBA (MSW)


%if 1
bs_checkpt_off	equ ($-$$)
%ifndef DEPEND
%if bs_checkpt_off > 1F8h
%error "Boot sector overflow"
%endif
%endif

		zb 1F8h-($-$$)
%endif
FirstSector	dd 0xDEADBEEF			; Location of sector 1
MaxTransfer	dw 0x007F			; Max transfer size
bootsignature	dw 0AA55h

;
; ===========================================================================
;  End of boot sector
; ===========================================================================
;  Start of LDLINUX.SYS
; ===========================================================================

ldlinux_sys:

syslinux_banner	db 0Dh, 0Ah
		db 'EXTLINUX '
		db version_str, ' ', date, ' ', 0
		db 0Dh, 0Ah, 1Ah	; EOF if we "type" this in DOS

		align 8, db 0
ldlinux_magic	dd LDLINUX_MAGIC
		dd HEXDATE

;
; This area is patched by the installer.  It is found by looking for
; LDLINUX_MAGIC, plus 8 bytes.
;
patch_area:
LDLDwords	dw 0		; Total dwords starting at ldlinux_sys
LDLSectors	dw 0		; Number of sectors - (bootsec+this sec)
CheckSum	dd 0		; Checksum starting at ldlinux_sys
				; value = LDLINUX_MAGIC - [sum of dwords]

; Space for up to 64 sectors, the theoretical maximum
SectorPtrs	times 64 dd 0

ldlinux_ent:
; 
; Note that some BIOSes are buggy and run the boot sector at 07C0:0000
; instead of 0000:7C00 and the like.  We don't want to add anything
; more to the boot sector, so it is written to not assume a fixed
; value in CS, but we don't want to deal with that anymore from now
; on.
;
		jmp 0:.next
.next:

;
; Tell the user we got this far
;
		mov si,syslinux_banner
		call writestr

;
; Patch disk error handling
;
		mov word [xint13.disk_error+1],do_disk_error-(xint13.disk_error+3)

;
; Now we read the rest of LDLINUX.SYS.	Don't bother loading the first
; sector again, though.
;
load_rest:
		mov si,SectorPtrs
		mov bx,7C00h+2*SECTOR_SIZE	; Where we start loading
		mov cx,[LDLSectors]

.get_chunk:
		jcxz .done
		xor bp,bp
		lodsd				; First sector of this chunk

		mov edx,eax

.make_chunk:
		inc bp
		dec cx
		jz .chunk_ready
		inc edx				; Next linear sector
		cmp [esi],edx			; Does it match
		jnz .chunk_ready		; If not, this is it
		add esi,4			; If so, add sector to chunk
		jmp short .make_chunk

.chunk_ready:
		call getlinsecsr
		shl bp,SECTOR_SHIFT
		add bx,bp
		jmp .get_chunk

.done:

;
; All loaded up, verify that we got what we needed.
; Note: the checksum field is embedded in the checksum region, so
; by the time we get to the end it should all cancel out.
;
verify_checksum:
		mov si,ldlinux_sys
		mov cx,[LDLDwords]
		mov edx,-LDLINUX_MAGIC
.checksum:
		lodsd
		add edx,eax
		loop .checksum

		and edx,edx			; Should be zero
		jz all_read			; We're cool, go for it!

;
; Uh-oh, something went bad...
;
		mov si,checksumerr_msg
		call writestr
		jmp kaboom

;
; -----------------------------------------------------------------------------
; Subroutines that have to be in the first sector
; -----------------------------------------------------------------------------

;
; getlinsecsr: save registers, call getlinsec, restore registers
;
getlinsecsr:	pushad
		call getlinsec
		popad
		ret

;
; This routine captures disk errors, and tries to decide if it is
; time to reduce the transfer size.
;
do_disk_error:
		cmp ah,42h
		je .ebios
		shr al,1		; Try reducing the transfer size
		mov [MaxTransfer],al	
		jz kaboom		; If we can't, we're dead...
		jmp xint13		; Try again
.ebios:
		push ax
		mov ax,[si+2]
		shr ax,1
		mov [MaxTransfer],ax
		mov [si+2],ax
		pop ax
		jmp xint13

;
; Checksum error message
;
checksumerr_msg	db 'Load error - ', 0	; Boot failed appended

;
; Debug routine
;
%ifdef debug
safedumpregs:
		cmp word [Debug_Magic],0D00Dh
		jnz nc_return
		jmp dumpregs
%endif

rl_checkpt	equ $				; Must be <= 8000h

rl_checkpt_off	equ ($-$$)
%if 0 ; ndef DEPEND
%if rl_checkpt_off > 400h
%error "Sector 1 overflow"
%endif
%endif

; ----------------------------------------------------------------------------
;  End of code and data that have to be in the first sector
; ----------------------------------------------------------------------------

all_read:
;
; Let the user (and programmer!) know we got this far.  This used to be
; in Sector 1, but makes a lot more sense here.
;
		mov si,copyright_str
		call writestr

;
; Insane hack to expand the DOS superblock to dwords
;
expand_super:
		xor eax,eax
		mov si,superblock
		mov di,SuperInfo
		mov cx,superinfo_size
.loop:
		lodsw
		dec si
		stosd				; Store expanded word
		xor ah,ah
		stosd				; Store expanded byte
		loop .loop

;
; Compute some information about this filesystem.
;

;
; Common initialization code
;
%include "cpuinit.inc"

;
; Clear Files structures
;
		mov di,Files
		mov cx,(MAX_OPEN*open_file_t_size)/4
		xor eax,eax
		rep stosd

;
; Initialize the metadata cache
;
		call initcache

;
; Initialization that does not need to go into the any of the pre-load
; areas
;
		; Now set up screen parameters
		call adjust_screen

		; Wipe the F-key area
		mov al,NULLFILE
		mov di,FKeyName
		mov cx,10*(1 << FILENAME_MAX_LG2)
		rep stosb

;
; Now, everything is "up and running"... patch kaboom for more
; verbosity and using the full screen system
;
		; E9 = JMP NEAR
		mov dword [kaboom.patch],0e9h+((kaboom2-(kaboom.patch+3)) << 8)

;
; Now we're all set to start with our *real* business.	First load the
; configuration file (if any) and parse it.
;
; In previous versions I avoided using 32-bit registers because of a
; rumour some BIOSes clobbered the upper half of 32-bit registers at
; random.  I figure, though, that if there are any of those still left
; they probably won't be trying to install Linux on them...
;
; The code is still ripe with 16-bitisms, though.  Not worth the hassle
; to take'm out.  In fact, we may want to put them back if we're going
; to boot ELKS at some point.
;
		mov si,linuxauto_cmd		; Default command: "linux auto"
		mov di,default_cmd
                mov cx,linuxauto_len
		rep movsb

		mov di,KbdMap			; Default keymap 1:1
		xor al,al
		inc ch				; CX <- 256
mkkeymap:	stosb
		inc al
		loop mkkeymap

;
; Load configuration file
;
		mov di,syslinux_cfg
		call open
		jz no_config_file

;
; Now we have the config file open.  Parse the config file and
; run the user interface.
;
%include "ui.inc"

;
; Linux kernel loading code is common.
;
%include "runkernel.inc"

;
; COMBOOT-loading code
;
%include "comboot.inc"
%include "com32.inc"
%include "cmdline.inc"

;
; Boot sector loading code
;
%include "bootsect.inc"

;
; abort_check: let the user abort with <ESC> or <Ctrl-C>
;
abort_check:
		call pollchar
		jz ac_ret1
		pusha
		call getchar
		cmp al,27			; <ESC>
		je ac_kill
		cmp al,3			; <Ctrl-C>
		jne ac_ret2
ac_kill:	mov si,aborted_msg

;
; abort_load: Called by various routines which wants to print a fatal
;             error message and return to the command prompt.  Since this
;             may happen at just about any stage of the boot process, assume
;             our state is messed up, and just reset the segment registers
;             and the stack forcibly.
;
;             SI    = offset (in _text) of error message to print
;
abort_load:
                mov ax,cs                       ; Restore CS = DS = ES
                mov ds,ax
                mov es,ax
                cli
                mov sp,StackBuf-2*3    		; Reset stack
                mov ss,ax                       ; Just in case...
                sti
                call cwritestr                  ; Expects SI -> error msg
al_ok:          jmp enter_command               ; Return to command prompt
;
; End of abort_check
;
ac_ret2:	popa
ac_ret1:	ret

;
; allocate_file: Allocate a file structure
;
;		If successful:
;		  ZF set
;		  BX = file pointer
;		In unsuccessful:
;		  ZF clear
;
allocate_file:
		TRACER 'a'
		push cx
		mov bx,Files
		mov cx,MAX_OPEN
.check:		cmp dword [bx], byte 0
		je .found
		add bx,open_file_t_size		; ZF = 0
		loop .check
		; ZF = 0 if we fell out of the loop
.found:		pop cx
		ret

;
; searchdir:
;	     Search the root directory for a pre-mangled filename in DS:DI.
;
;	     NOTE: This file considers finding a zero-length file an
;	     error.  This is so we don't have to deal with that special
;	     case elsewhere in the program (most loops have the test
;	     at the end).
;
;	     If successful:
;		ZF clear
;		SI	= file pointer
;		DX:AX	= file length in bytes
;	     If unsuccessful
;		ZF set
;

searchdir:
		call allocate_file
		jnz .alloc_failure

		ret
;
; writechr:	Write a single character in AL to the console without
;		mangling any registers; handle video pages correctly.
;
writechr:
		call write_serial	; write to serial port if needed
		pushfd
		pushad
		mov ah,0Eh
		mov bl,07h		; attribute
		mov bh,[cs:BIOS_page]	; current page
		int 10h
		popad
		popfd
		ret

;
;
; kaboom2: once everything is loaded, replace the part of kaboom
;	   starting with "kaboom.patch" with this part

kaboom2:
		mov si,err_bootfailed
		call cwritestr
		call getchar
		call vgaclearmode
		int 19h			; And try once more to boot...
.norge:		jmp short .norge	; If int 19h returned; this is the end

;
; mangle_name: Mangle a DOS filename pointed to by DS:SI into a buffer pointed
;	       to by ES:DI; ends on encountering any whitespace
;

mangle_name:
		ret

;
; unmangle_name: Does the opposite of mangle_name; converts a DOS-mangled
;                filename to the conventional representation.  This is needed
;                for the BOOT_IMAGE= parameter for the kernel.
;                NOTE: A 13-byte buffer is mandatory, even if the string is
;                known to be shorter.
;
;                DS:SI -> input mangled file name
;                ES:DI -> output buffer
;
;                On return, DI points to the first byte after the output name,
;                which is set to a null byte.
;
unmangle_name:
		ret


;
; linsector:	Convert a linear sector index in a file to a linear sector number
;	EAX	-> linear sector number
;	DS:SI	-> open_file_t
;
;		Returns next sector number in EAX; CF on EOF (not an error!)
;
linsector:
		push gs
		push ebx
		push esi
		push edi
		push ecx
		push edx
		push ebp

		push eax
		mov cl,[ClustShift]
		shr eax,cl		; Convert to block number
		push eax
		mov eax,[si+file_in_sec]
		mov bx,si
		call getcachesector	; Get inode
		add si,[bx+file_in_off]	; Get *our* inode
		pop eax
		lea ebx,[i_block+4*eax]
		cmp eax,EXT2_NDIR_BLOCKS
		jb .direct
		mov ebx,[gs:si+i_block+4*EXT2_IND_BLOCK]
		sub eax,EXT2_NDIR_BLOCKS
		mov ebp,[PtrsPerBlk1]
		jb .ind1
		mov ebx,[gs:si+i_block+4*EXT2_DIND_BLOCK]
		sub eax,ebp
		mov ebp,[PtrsPerBlock2]
		cmp eax,ebp
		jb .ind2
		mov ebx,[gs:si+i_block+4*EXT2_TIND_BLOCK]
		sub eax,ebp

.ind3:
		; Triple indirect; eax contains the block no
		; with respect to the start of the tind area;
		; ebx contains the pointer to the tind block.
		xor edx,edx
		div dword [PtrsPerBlock3]
		; EAX = which dind block, EDX = block no in dind block

		shl ebx,cl		; Sector # for tind block
		push ax
		shr eax,SECTOR_SHIFT-2	; Sector within tind block
		add eax,ebx
		call getcachesector
		pop bx
		shl bx,2		; Convert to byte offset
		and bx,SECTOR_SIZE-1

		mov ebx,[gs:bx+si]	; Get the pointer
		mov eax,edx		; The int2 code wants the remainder...
.ind2:
		; Double indirect; eax contains the block no
		; with respect to the start of the dind area;
		; ebx contains the pointer to the dind block.
		xor edx,edx
		div dword [PtrsPerBlock2]
		; EAX = which dind block, EDX = block no in dind block

		shl ebx,cl		; Sector # for tind block
		push ax
		shr eax,SECTOR_SHIFT-2	; Sector within tind block
		add eax,ebx
		call getcachesector
		pop bx
		shl bx,2		; Convert to byte offset
		and bx,SECTOR_SIZE-1

		mov ebx,[gs:bx+si]	; Get the pointer
		mov eax,edx		; The ind1 code wants the remainder...
.ind1:
		; Single indirect; eax contains the block no
		; with respect to the start of the ind area;
		; ebx contains the pointer to the ind block.
		xor edx,edx
		div dword [PtrsPerBlock1]
		; EAX = which dind block, EDX = block no in dind block

		shl ebx,cl		; Sector # for tind block
		push ax
		shr eax,SECTOR_SHIFT-2	; Sector within tind block
		add eax,ebx
		call getcachesector
		pop bx
		shl bx,2		; Convert to byte offset
		and bx,SECTOR_SIZE-1

.direct:
		mov ebx,[gs:bx+si]	; Get the pointer

		pop eax			; Get the sector index again
		shl ebx,cl		; Convert block number to sector
		and eax,[ClustMask]	; Add offset within block
		add eax,ebx

		pop ebp
		pop edx
		pop ecx
		pop edi
		pop esi
		pop ebx
		pop gs
		ret

;
; getfssec: Get multiple sectors from a file
;
;	Same as above, except SI is a pointer to a open_file_t
;
;	ES:BX	-> Buffer
;	DS:SI	-> Pointer to open_file_t
;	CX	-> Sector count (0FFFFh = until end of file)
;                  Must not exceed the ES segment
;	Returns CF=1 on EOF (not necessarily error)
;	All arguments are advanced to reflect data read.
;
getfssec:
		push ebp
		push eax
		push ebx
		push edx
.getfragment:
		mov eax,[si]			; Current start index
		mov ebx,eax
		call linsector
		push eax			; Fragment start sector
		mov edx,eax
		xor ebp,ebp			; Fragment sector count
.getseccnt:
		inc bp
		dec cx
		jz .do_read
		xor eax,eax
		mov ax,es
		shl ax,4
		add ax,bx			; Now DI = how far into 64K block we are
		not ax				; Bytes left in 64K block
		inc eax
		shr eax,SECTOR_SHIFT		; Sectors left in 64K block
		cmp bp,ax
		jnb .do_read			; Unless there is at least 1 more sector room...
		inc ebx				; Sector index
		inc edx				; Linearly next sector
		mov eax,ebx
		call nextsector
		jc .do_read
		cmp edx,eax
		je .getseccnt
.do_read:
		pop eax				; Linear start sector
		call getlinsecsr
		lea eax,[eax+ebp-1]		; This is the last sector actually read
		shl bp,9
		add bx,bp			; Adjust buffer pointer
		call nextsector
		jc .eof
		mov edx,eax
		and cx,cx
		jnz .getfragment
.done:
		pop edx
		pop ebx
		pop eax
		pop ebp
		ret
.eof:
		xor edx,edx
		stc
		jmp .done



; -----------------------------------------------------------------------------
;  Common modules
; -----------------------------------------------------------------------------

%include "getc.inc"		; getc et al
%include "conio.inc"		; Console I/O
%include "writestr.inc"		; String output
%include "parseconfig.inc"	; High-level config file handling
%include "parsecmd.inc"		; Low-level config file handling
%include "bcopy32.inc"		; 32-bit bcopy
%include "loadhigh.inc"		; Load a file into high memory
%include "font.inc"		; VGA font stuff
%include "graphics.inc"		; VGA graphics
%include "highmem.inc"		; High memory sizing
%include "strcpy.inc"           ; strcpy()
%include "cache.inc"

; -----------------------------------------------------------------------------
;  Begin data section
; -----------------------------------------------------------------------------

		section .data
copyright_str   db ' Copyright (C) 1994-', year, ' H. Peter Anvin'
		db CR, LF, 0
boot_prompt	db 'boot: ', 0
wipe_char	db BS, ' ', BS, 0
err_notfound	db 'Could not find kernel image: ',0
err_notkernel	db CR, LF, 'Invalid or corrupt kernel image.', CR, LF, 0
err_noram	db 'It appears your computer has less than '
		asciidec dosram_k
		db 'K of low ("DOS")'
		db CR, LF
		db 'RAM.  Linux needs at least this amount to boot.  If you get'
		db CR, LF
		db 'this message in error, hold down the Ctrl key while'
		db CR, LF
		db 'booting, and I will take your word for it.', CR, LF, 0
err_badcfg      db 'Unknown keyword in syslinux.cfg.', CR, LF, 0
err_noparm      db 'Missing parameter in syslinux.cfg.', CR, LF, 0
err_noinitrd    db CR, LF, 'Could not find ramdisk image: ', 0
err_nohighmem   db 'Not enough memory to load specified kernel.', CR, LF, 0
err_highload    db CR, LF, 'Kernel transfer failure.', CR, LF, 0
err_oldkernel   db 'Cannot load a ramdisk with an old kernel image.'
                db CR, LF, 0
err_notdos	db ': attempted DOS system call', CR, LF, 0
err_comlarge	db 'COMBOOT image too large.', CR, LF, 0
err_a20		db CR, LF, 'A20 gate not responding!', CR, LF, 0
err_bootfailed	db CR, LF, 'Boot failed: please change disks and press '
		db 'a key to continue.', CR, LF, 0
ready_msg	db 'Ready.', CR, LF, 0
crlfloading_msg	db CR, LF
loading_msg     db 'Loading ', 0
dotdot_msg      db '.'
dot_msg         db '.', 0
aborted_msg	db ' aborted.'			; Fall through to crlf_msg!
crlf_msg	db CR, LF
null_msg	db 0
crff_msg	db CR, FF, 0
ConfigName	db 'syslinux.cfg',0		; Unmangled form

;
; Command line options we'd like to take a look at
;
; mem= and vga= are handled as normal 32-bit integer values
initrd_cmd	db 'initrd='
initrd_cmd_len	equ 7

;
; Config file keyword table
;
%include "keywords.inc"

;
; Extensions to search for (in *forward* order).
;
		align 4, db 0
exten_table:	db '.cbt'		; COMBOOT (specific)
		db '.img'		; Disk image
		db '.bs', 0		; Boot sector
		db '.com'		; COMBOOT (same as DOS)
		db '.c32'		; COM32
exten_table_end:
		dd 0, 0			; Need 8 null bytes here

;
; Misc initialized (data) variables
;
%ifdef debug				; This code for debugging only
debug_magic	dw 0D00Dh		; Debug code sentinel
%endif
AppendLen       dw 0                    ; Bytes in append= command
OntimeoutLen	dw 0			; Bytes in ontimeout command
OnerrorLen	dw 0			; Bytes in onerror command
KbdTimeOut      dw 0                    ; Keyboard timeout (if any)
CmdLinePtr	dw cmd_line_here	; Command line advancing pointer
initrd_flag	equ $
initrd_ptr	dw 0			; Initial ramdisk pointer/flag
VKernelCtr	dw 0			; Number of registered vkernels
ForcePrompt	dw 0			; Force prompt
AllowImplicit   dw 1                    ; Allow implicit kernels
AllowOptions	dw 1			; User-specified options allowed
SerialPort	dw 0			; Serial port base (or 0 for no serial port)
VGAFontSize	dw 16			; Defaults to 16 byte font
UserFont	db 0			; Using a user-specified font
ScrollAttribute	db 07h			; White on black (for text mode)

		alignb 4, db 0
BufSafe		dw trackbufsize/SECTOR_SIZE	; Clusters we can load into trackbuf
BufSafeSec	dw trackbufsize/SECTOR_SIZE	; = how many sectors?
BufSafeBytes	dw trackbufsize		; = how many bytes?
EndOfGetCBuf	dw getcbuf+trackbufsize	; = getcbuf+BufSafeBytes
%ifndef DEPEND
%if ( trackbufsize % SECTOR_SIZE ) != 0
%error trackbufsize must be a multiple of SECTOR_SIZE
%endif
%endif
;
; Stuff for the command line; we do some trickery here with equ to avoid
; tons of zeros appended to our file and wasting space
;
linuxauto_cmd	db 'linux auto',0
linuxauto_len   equ $-linuxauto_cmd
boot_image      db 'BOOT_IMAGE='
boot_image_len  equ $-boot_image

		align 4, db 0		; Pad out any unfinished dword
ldlinux_end	equ $
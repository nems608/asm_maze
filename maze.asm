%include "/usr/share/csc314/asm_io.inc"

; how to represent everything
%define SPACE '  '
%define HALF_SPACE ' '
%define HOR_WALL '##'
%define VER_WALL '#'
%define PLAYER ';;'
%define CRUMB '..'
%define PATH '!!'
%define HOLE 0xF0,0x9F,0x95,0xB3,' '
%define LADDER 0xe2,0x98,0xb0,' '
%define FLAG 0xe2,0x9a,0x91,' '

; the player starting position.
; top left is considered (0,0)
%define STARTX 0
%define STARTY 0
%define START_LAYER 0

; these keys do things
%define EXITCHAR 'x'
%define NCHAR 'w'
%define WCHAR 'a'
%define SCHAR 's'
%define ECHAR 'd'
%define UCHAR 'q'
%define DCHAR 'e'
%define SPEED_UP '='
%define SPEED_DOWN '-'

; maze buffer offsets
%define E_OFFSET 0
%define S_OFFSET 1
%define D_OFFSET 2

; MAX_SPEED should be a multiple of SPEED_INC
%define MAX_SPEED 200
%define SPEED_INC 5

; Files to read from
%define START_SCREEN "start_scrn.txt"
%define END_SCREEN "end_scrn.txt"
%define	RAND_FILE "/dev/urandom"

segment .data
	; Files we need to read from
	rand_file_str	db	RAND_FILE,0
	start_scrn_file	db	START_SCREEN,0
	end_scrn_file	db	END_SCREEN,0

	; used to change the terminal mode
	mode_r			db "r",0
	raw_mode_on_cmd		db "stty raw -echo",0
	raw_mode_off_cmd	db "stty -raw echo",0

	; called by system() to clear/refresh the screen
	clear_screen_cmd	db "clear",0

	; things the program will print
	manual_help_str	db 13,10,"Controls: ", \
					NCHAR,"=NORTH / ", \
					WCHAR,"=WEST / ", \
					SCHAR,"=SOUTH / ", \
					ECHAR,"=EAST / ", \
					UCHAR,"=UP / ", \
					DCHAR,"=DOWN / ", \
					EXITCHAR,"=EXIT", \
					13,10,10,0
	auto_help_str	db 13,10,"Controls: ", \
					"'",SPEED_UP,"'"," = SPEED UP / ", \
					"'",SPEED_DOWN,"'"," = SLOW DOWN / ", \
					"'",EXITCHAR,"'"," = EXIT", \
					13,10,10,0

	; Format strings for printing / scanning
	tput_fmt_str	db	"tput cup %d %d",0
	int_scan_str	db	"%d",0
	char_scan_str	db	"%c",0
	layer_fmt_str	db	"Layer %d/%d",13,10,0
	speed_fmt_str	db	"Speed %d/%d",13,10,0

	; Rendering definitions
	hor_wall	db HOR_WALL,0
	ver_wall	db VER_WALL,0
	player		db PLAYER,0
	hole		db HOLE,0
	ladder		db LADDER,0
	flag		db FLAG,0
	space		db SPACE,0
	half_space	db HALF_SPACE,0
	crumb		db CRUMB,0
	path_marker	db PATH,0
	

segment .bss
	; Presence of walls in (E)ast, (S)outh, and (D)own directions
	; 0 indicates a wall, 1 the absence of a wall
	; Cell position in buffer: ((H*W*L)+(R*W)+C)*3
	;|---|---|---|---
	;| E | S | D |...
	;|---|---|---|---
	maze		resd	1

	; Nodes in the graph which have been visited
	; |---|---|---|---
	; | x | y | l | ...
	; |---|---|---|---
	visited		resd	1
	visited_len	resd	1
	path		resd	1
	path_len	resd	1

	; these variables store the dimensions of the maze
	width	resd	1
	height	resd	1
	layers	resd	1

	; these variables store the current player position
	xpos	resd	1
	ypos	resd	1
	layer	resd	1

segment .text

	global	asm_main
	global	raw_mode_on
	global	raw_mode_off
	global	init_board
	global	render

	extern	system
	extern	putchar
	extern	getchar
	extern	fcntl
	extern	printf
	extern	sprintf
	extern	fopen
	extern	fread
	extern	fgetc
	extern	scanf
	extern	fclose
	extern	malloc
	extern	calloc
	extern	free
	extern	usleep


asm_main:
	enter	0,0
	pusha
	;***************CODE STARTS HERE***************************
	push	ebp
	mov	ebp, esp
	sub	esp, 8

	asm_main_beginning:
	; show the start screen, and get maze config
	call	start_screen
	mov	DWORD [ebp-4], eax ; solve mode

	; put the terminal in raw mode so the game works nicely
	call	raw_mode_on

	; Set up some data structures for visited/path tracking
	call	num_edges
	mov	ebx, 4
	mul	ebx
	mov	DWORD [ebp-8], eax
	
	push	DWORD [ebp-8]
	call	malloc
	add	esp, 4
	mov	DWORD [visited], eax

	push	DWORD [ebp-8]
	call	malloc
	add	esp, 4
	mov	DWORD [path], eax

	; read the game board file into the global variable
	call	gen_maze

	; set the player at the proper start position
	mov	DWORD [xpos], STARTX
	mov	DWORD [ypos], STARTY
	mov	DWORD [layer], START_LAYER

	; Determine solve mode
	cmp	DWORD [ebp-4], 'm'
	je	run_manual
	cmp	DWORD [ebp-4], 'd'
	je	run_dfs
	cmp	DWORD [ebp-4], 'b'
	je	run_bfs

	run_manual:
	call	manual_mode
	jmp	game_end

	run_dfs:
	push	0
	call	auto_mode
	add	esp, 4
	jmp	game_end

	run_bfs:
	push	1
	call	auto_mode
	add	esp, 4

	game_end:
	; restore old terminal functionality
	call	raw_mode_off

	; Show the end screen. Ask the user if they want to play again.
	call	at_flag
	cmp	eax, 1
	jne	asm_main_end

	call	end_screen
	cmp	eax, 'y'
	je	asm_main_beginning

	asm_main_end:
	; User answered 'no'. Clear the screen, and exit
	push	clear_screen_cmd
	call	system
	add	esp, 4

	mov	esp, ebp
	pop	ebp
	;***************CODE ENDS HERE*****************************
	popa
	mov		eax, 0
	leave
	ret

; ==================== Start and End Screen Functions ====================

; === FUNCTION ===
; Print the start screen and gather configuration parameters from the user
; Returns: mode ['m', 'd', 'b'] (eax)
start_screen:
	push	ebp
	mov	ebp, esp

	start_screen_beginning:

	; clear the screen
	push	clear_screen_cmd
	call	system
	add	esp, 4

	; Print the start screen
	push	start_scrn_file
	call	print_file
	add	esp, 4

	call	flush_input_buffer
	; Read width
	push	21
	push	24
	push	int_scan_str
	call	read_input
	add	esp, 12

	cmp	eax, 0
	je	start_screen_beginning
	cmp	ebx, 0
	jl	start_screen_beginning
	mov	DWORD [width], ebx

	call	flush_input_buffer
	; Read height
	push	22
	push	25
	push	int_scan_str
	call	read_input
	add	esp, 12

	cmp	eax, 0
	je	start_screen_beginning
	cmp	ebx, 0
	jl	start_screen_beginning
	mov	DWORD [height], ebx

	call	flush_input_buffer
	; Read layers
	push	22
	push	26
	push	int_scan_str
	call	read_input
	add	esp, 12

	cmp	eax, 0
	je	start_screen_beginning
	cmp	ebx, 0
	jl	start_screen_beginning
	mov	DWORD [layers], ebx

	call	flush_input_buffer
	; Read solve mode
	push	26
	push	27
	push	char_scan_str
	call	read_input
	add	esp, 12

	cmp	eax, 0
	je	start_screen_beginning

	movzx	eax, bl
	cmp	eax, 'm'
	je	start_screen_end
	cmp	eax, 'd'
	je	start_screen_end
	cmp	eax, 'b'
	jne	start_screen_beginning

	start_screen_end:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Show the end screen, and ask the user if they want to play again
; Returns: play_again ['y','n'] (eax)
end_screen:
	push	ebp
	mov	ebp, esp

	end_screen_beginning:
	; clear the screen
	push	clear_screen_cmd
	call	system
	add	esp, 4

	; Print the start screen
	push	end_scrn_file
	call	print_file
	add	esp, 4

	call	flush_input_buffer
	; Read width
	push	33
	push	23
	push	char_scan_str
	call	read_input
	add	esp, 12

	cmp	eax, 0
	je	end_screen_beginning

	movzx	eax, bl
	cmp	eax, 'y'
	je	end_screen_end
	cmp	eax, 'n'
	jne	end_screen_beginning

	end_screen_end:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Places the cursor at the given coordinates on the screen, and reads the given type of input
; Args: col, row, scan_str
; Returns: success (eax), input (ebx)
read_input:
	push	ebp
	mov	ebp, esp
	sub	esp, 4

	push	DWORD [ebp+16]
	push	DWORD [ebp+12]
	call	tput
	add	esp, 8

	lea	eax, [ebp-4]
	push	eax
	push	DWORD [ebp+8]
	call	scanf
	add	esp, 8

	mov	ebx, DWORD [ebp-4]

	mov	esp, ebp
	pop	ebp
	ret
	

; === FUNCTION ===
; Clears the input buffer
flush_input_buffer:
	push	ebp
	mov	ebp, esp

	flush_input_buffer_start:
		call	nonblocking_getchar
		movsx	eax, al
		cmp	eax, -1
		je	flush_input_buffer_end

		jmp	flush_input_buffer_start
	flush_input_buffer_end:

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Calls tput with the given arguments
; Args: row, col
tput:
	push	ebp
	mov	ebp, esp
	sub	esp, 4

	; Allocate string buffer
	push	50
	call	malloc
	add	esp, 4
	mov	DWORD [ebp-4], eax

	; Format tput string
	push	DWORD [ebp+12]
	push	DWORD [ebp+8]
	push	tput_fmt_str
	push	DWORD [ebp-4]
	call	sprintf
	add	esp, 16

	; Call tput
	push	DWORD [ebp-4]
	call	system
	add	esp, 4

	; Free string buffer
	push	DWORD [ebp-4]
	call	free
	add	esp, 4

	mov	esp, ebp
	pop	ebp
	ret

; Print the contents of the given file to the screen
; Args: file
print_file:
	push	ebp
	mov	ebp, esp
	sub	esp, 5

	push	mode_r
	push	DWORD [ebp+8]
	call	fopen
	add	esp, 8
	mov	DWORD [ebp-4], eax	; FILE*

	print_file_loop_start:
		; Read one byte
		lea	eax, [ebp-5]
		push	DWORD [ebp-4]
		push	1
		push	1
		push	eax
		call	fread
		add	esp, 16

		cmp	eax, 1	; If fread didn't read a byte, EOF -> end
		jne	print_file_loop_end

		movzx	eax, BYTE [ebp-5]
		push	eax
		call	putchar
		add	esp, 4

		jmp	print_file_loop_start
	print_file_loop_end:

	push	DWORD [ebp-4]
	call	fclose
	add	esp, 4

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
raw_mode_on:

	push	ebp
	mov	ebp, esp

	push	raw_mode_on_cmd
	call	system
	add	esp, 4

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
raw_mode_off:

	push	ebp
	mov	ebp, esp

	push	raw_mode_off_cmd
	call	system
	add	esp, 4

	mov	esp, ebp
	pop	ebp
	ret

; ==================== Maze Generation Functions ====================

; === FUNCTION ===
; Generate a random maze, and stores the pointer to it in [maze]
gen_maze:
	push	ebp
	mov	ebp, esp

	call	rand_graph

	push	eax
	call	kruskal
	add	esp, 4

	mov	DWORD [maze], eax

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Generates a spanning tree using Kruskal's algorithm
; Args: graph_ptr
; Returns: maze_ptr
kruskal:
	push	ebp
	mov	ebp, esp
	sub	esp, 28

	; Tree tracker
	call	num_vertices
	mov	DWORD [ebp-4], eax	; num vertices

	push	eax
	push	4
	call	calloc
	add	esp, 8
	mov	DWORD [ebp-8], eax 	; tree_tracker_ptr
	mov	DWORD [ebp-12], 0	; next tree idx

	; Output maze
	call	num_edges
	mov	DWORD [ebp-16], eax	; num possible edges

	push	eax
	push	1
	call	calloc
	add	esp, 8
	mov	DWORD [ebp-20], eax	; maze_ptr

	; Build spanning tree
	mov	DWORD [ebp-24], 0
	kruskal_loop_start:
		mov	eax, DWORD [ebp-4]
		dec	eax
		cmp	DWORD [ebp-24], eax	; stop after |V|-1 edges
		jge	kruskal_loop_end

		; Get a ptr to the edge with the largest weight
		kruskal_get_max:
		push	DWORD [ebp+8]
		push	DWORD [ebp-16]
		call	list_max
		add	esp, 8

		; Set value to zero (so we know it's used)
		mov	DWORD [eax], 0
		; Find offset
		sub	eax, DWORD [ebp+8]
		; offset / 4 / 3 * 4 = vertex offset. (offset / 4) % 3 = E or S or D
		mov	ebx, 4
		cdq
		div	ebx

		; Save offset/4 for edge addition later
		mov	DWORD [ebp-28], eax

		mov	ebx, 3
		cdq	
		div	ebx
		mov	ecx, edx
		mov	ebx, 4
		mul	ebx
		mov	edx, ecx

		; ebx = vertex_1, ecx = vertex_2
		mov	ebx, eax
		add	ebx, DWORD [ebp-8]
		mov	ecx, ebx

		cmp	edx, 0
		je	kruskal_east_edge
		cmp	edx, 1
		je	kruskal_south_edge
		jmp	kruskal_down_edge

		kruskal_east_edge:
		add	ecx, 4
		jmp	kruskal_modify_forest

		kruskal_south_edge:
		mov	eax, DWORD [width]
		mov	edx, 4
		mul	edx
		add	ecx, eax
		jmp	kruskal_modify_forest

		kruskal_down_edge:
		mov	eax, DWORD [width]
		mov	edx, DWORD [height]
		mul	edx
		mov	edx, 4
		mul	edx
		add	ecx, eax

		kruskal_modify_forest:
		; Both 0 -> neither in a forest, make new tree
		mov	eax, DWORD [ecx]
		or	eax, DWORD [ebx]	; 0 if both 0
		cmp	eax, 0
		je	kruskal_new_tree
		; Both same -> edge would create a cycle, skip
		mov	eax, DWORD [ebx]
		cmp	eax, DWORD [ecx]
		je	kruskal_get_max
		; One zero -> put new one in the other's forest
		cmp	DWORD [ebx], 0
		je	kruskal_add_to_tree
		cmp	DWORD [ecx], 0
		je	kruskal_add_to_tree
		; Different -> combine trees
		jmp	kruskal_combine_trees

		kruskal_new_tree:
		inc	DWORD [ebp-12]
		mov	eax, DWORD [ebp-12]
		mov	DWORD [ebx], eax
		mov	DWORD [ecx], eax
		jmp	kruskal_add_edge

		kruskal_add_to_tree:
		cmp	DWORD [ebx], 0
		jne	kruskal_add_to_tree_other
		mov	eax, DWORD [ecx]
		mov	DWORD [ebx], eax
		jmp	kruskal_add_edge

		kruskal_add_to_tree_other:
		mov	eax, DWORD [ebx]
		mov	DWORD [ecx], eax
		jmp	kruskal_add_edge

		kruskal_combine_trees:
		push	DWORD [ebp-8]
		push	DWORD [ebp-4]
		push	DWORD [ebx]
		push	DWORD [ecx]
		call	kruskal_combine
		add	esp, 16

		kruskal_add_edge:
		mov	eax, DWORD [ebp-28]
		add	eax, DWORD [ebp-20] ; add maze_ptr
		mov	BYTE [eax], 1

		inc	DWORD [ebp-24]
		jmp	kruskal_loop_start
	kruskal_loop_end:

	mov	eax, DWORD [ebp-20]

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Combines two trees in a kruskal tree tracker
; Args: tree_tracker_ptr, tree_tracker_len, num1, num2
kruskal_combine:
	push	ebp
	mov	ebp, esp

	; Find smaller of num1, num2
	mov	eax, DWORD [ebp+8]
	mov	ebx, DWORD [ebp+12]
	mov	DWORD [ebp-4], eax	; Smaller num
	mov	DWORD [ebp-8], ebx	; Larger num

	mov	eax, DWORD [ebp+8]
	cmp	eax, DWORD [ebp+12]
	jl	kruskal_combine_find_smaller_end
	mov	DWORD [ebp-4], ebx	; Smaller num
	mov	DWORD [ebp-8], eax	; Larger num

	kruskal_combine_find_smaller_end:
	; Overwrite larger of the two nums w/ the smaller one
	mov	DWORD [ebp-12], 0
	kruskal_combine_loop_start:
		mov	eax, DWORD [ebp-12]
		cmp	eax, DWORD [ebp+16] ; while < tree_tracker_len
		jge	kruskal_combine_loop_end

		; If tree_tracker[i] == larger num, set to smaller num
		mov	ecx, DWORD [ebp+20]
		mov	eax, DWORD [ebp-12]
		mov	ebx, 4
		mul	ebx
		add	ecx, eax	; ptr to tree_tracker[i]

		mov	eax, DWORD [ebp-8]
		cmp	eax, DWORD [ecx] ; if tree_tracker[i] == larger num
		jne	kruskal_combine_loop_continue
		; Equal so overwrite
		mov	eax, DWORD [ebp-4]
		mov	DWORD [ecx], eax

		kruskal_combine_loop_continue:
		inc	DWORD [ebp-12]
		jmp	kruskal_combine_loop_start
	kruskal_combine_loop_end:

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Generates a 3-D grid graph with random edge weights
; Returns: graph_ptr (eax)
rand_graph:
	push	ebp
	mov	ebp, esp
	sub	esp, 28

	; Malloc space for graph
	call	num_edges
	mov	ebx, 4	
	mul	ebx

	push	eax
	call	malloc
	add	esp, 4
	mov	DWORD [ebp-4], eax ; graph_ptr

	; Open source of randomness
	push	mode_r
	push	rand_file_str
	call	fopen
	add	esp, 8
	mov	DWORD [ebp-8], eax ; fp

	mov	DWORD [ebp-12], 0
	rand_graph_layer_loop_start:
		mov	eax, DWORD [ebp-12]
		cmp	eax, DWORD [layers]
		jge	rand_graph_layer_loop_end

		mov	DWORD [ebp-16], 0
		rand_graph_height_loop_start:
			mov	eax, DWORD [ebp-16]
			cmp	eax, DWORD [height]
			jge	rand_graph_height_loop_end

			mov	DWORD [ebp-20], 0
			rand_graph_width_loop_start:
				mov	eax, DWORD [ebp-20]
				cmp	eax, DWORD [width]
				jge	rand_graph_width_loop_end
		
				; L*WIDTH*HEIGHT + R*WIDTH + C
				mov	eax, DWORD [ebp-12]
				mov	ebx, DWORD [height]
				mul	ebx
				mov	ebx, DWORD [width]
				mul	ebx
				mov	ecx, eax

				mov	eax, DWORD [ebp-16]
				mov	ebx, DWORD [width]
				mul	ebx

				add	eax, ecx
				add	eax, DWORD [ebp-20]
				mov	ebx, 12
				mul	ebx
				mov	DWORD [ebp-28], eax

				mov	DWORD [ebp-24], 0
				rand_graph_edges_loop_start:
					cmp	DWORD [ebp-24], 3
					jge	rand_graph_edges_loop_end

					cmp	DWORD [ebp-24], 1
					je	rand_graph_test_south_edge
					cmp	DWORD [ebp-24], 2
					je	rand_graph_test_down_edge

					mov	eax, DWORD [width]
					dec	eax
					cmp	DWORD [ebp-20], eax
					jne	rand_graph_do_random
					jmp	rand_graph_do_zero

					rand_graph_test_south_edge:
					mov	eax, DWORD [height]
					dec	eax
					cmp	DWORD [ebp-16], eax
					jne	rand_graph_do_random
					jmp	rand_graph_do_zero

					rand_graph_test_down_edge:
					mov	eax, DWORD [layers]
					dec	eax
					cmp	DWORD [ebp-12], eax
					jne	rand_graph_do_random

					rand_graph_do_zero:
					mov	ebx, 0
					jmp	rand_graph_add_to_buffer

					rand_graph_do_random:
					; Get randint
					push	DWORD [ebp-8]
					call	randint
					add	esp, 4

					cmp	DWORD [ebp-24], 2 ; if down, reduce to 1/2
					jne	rand_graph_do_random_cont
					mov	ebx, 2
					mov	edx, 0
					div	ebx

					rand_graph_do_random_cont:
					cmp	eax, 0 ; if zero, retry
					je	rand_graph_do_random

					mov	ebx, eax

					rand_graph_add_to_buffer:
					; Add to buffer
					mov	eax, DWORD [ebp-24]
					mov	ecx, 4
					mul	ecx

					add	eax, DWORD [ebp-4]
					add	eax, DWORD [ebp-28]
					mov	DWORD [eax], ebx

					inc	DWORD [ebp-24]
					jmp	rand_graph_edges_loop_start
				rand_graph_edges_loop_end:
		
				inc	DWORD [ebp-20] 
				jmp	rand_graph_width_loop_start
			rand_graph_width_loop_end:

			inc	DWORD [ebp-16] 
			jmp	rand_graph_height_loop_start
		rand_graph_height_loop_end:

		inc	DWORD [ebp-12] 
		jmp	rand_graph_layer_loop_start
	rand_graph_layer_loop_end:


	; Close source of randomness
	push	DWORD [ebp-8]
	call	fclose
	add	esp, 4

	mov	eax, DWORD [ebp-4] ; Return value

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Reads 4 bytes of data from the given file as an integer
; Returns: random_int (eax)
randint:
	push	ebp
	mov	ebp, esp
	sub	esp, 8 ; counter, buffer

	; Read one byte at a time from the file, and
	; add it to the 4 byte (DWORD) buffer
	mov	DWORD [ebp-4], 0
	randint_loop_start:
		cmp	DWORD [ebp-4], 4
		jge	randint_loop_end

		push	DWORD [ebp+8]
		call	fgetc
		add	esp, 4

		mov	ebx, DWORD [ebp-4]
		mov	BYTE [ebp-8+ebx], al
	
		inc	DWORD [ebp-4]
		jmp	randint_loop_start
	randint_loop_end:

	mov	eax, DWORD [ebp-8]

	mov	esp, ebp
	pop	ebp
	ret


; ==================== Maze Solving Functions ====================

; === FUNCTION ===
; Run the game in manual mode
manual_mode:
	push	ebp
	mov	ebp, esp
	sub	esp, 12 ; tmp next_x, next_y, next_layer

	; Initial movement
	push	DWORD [xpos]
	push	DWORD [ypos]
	push	DWORD [layer]
	call	add_visited
	add	esp, 12

	manual_loop_start:
		; draw the game board
		push	0
		call	render
		add	esp, 4
		
		; Prep to move
		mov	eax, DWORD [xpos]
		mov	ebx, DWORD [ypos]
		mov	ecx, DWORD [layer]
		mov	DWORD [ebp-4], eax
		mov	DWORD [ebp-8], ebx
		mov	DWORD [ebp-12], ecx

		; get an action from the user
		call	getchar

		; choose what to do
		cmp	eax, EXITCHAR
		je	manual_loop_end
		cmp	eax, NCHAR
		je 	move_north
		cmp	eax, WCHAR
		je	move_west
		cmp	eax, SCHAR
		je	move_south
		cmp	eax, ECHAR
		je	move_east
		cmp	eax, UCHAR
		je	move_up
		cmp	eax, DCHAR
		je	move_down
		jmp	input_end		; or just do nothing

		; move the player according to the input character
		move_north:
			dec	DWORD [ebp-8]
			jmp	input_end
		move_south:
			inc	DWORD [ebp-8]
			jmp	input_end
		move_west:
			dec	DWORD [ebp-4]
			jmp	input_end
		move_east:
			inc	DWORD [ebp-4]
			jmp	input_end
		move_up:
			dec	DWORD [ebp-12]
			jmp	input_end
		move_down:
			inc	DWORD [ebp-12]

		input_end:
		push	DWORD [xpos]
		push	DWORD [ypos]
		push	DWORD [layer]
		push	DWORD [ebp-4]
		push	DWORD [ebp-8]
		push	DWORD [ebp-12]
		call	valid_move
		add	esp, 12

		cmp	al, 1
		jne	no_move
		
		; Move is valid, complete move
		push	DWORD [ebp-4]
		push	DWORD [ebp-8]
		push	DWORD [ebp-12]
		call	move_to
		add	esp, 12

		; Check if at the flag
		call	at_flag
		cmp	eax, 1
		je	manual_loop_end

		no_move:
		jmp	manual_loop_start
	manual_loop_end:

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Run the game in automated Depth First or Breadth First Search mode
; Args: search_type (0 = Depth First, 1 = Breadth First)
auto_mode:
	push	ebp
	mov	ebp, esp
	sub	esp, 20

	; malloc space for the stack data structure
	; size = num_edges*4
	call	num_edges
	mov	ebx, 4
	mul	ebx

	push	eax
	call	malloc
	add	esp, 4

	mov	DWORD [ebp-4], eax ; ptr to list
	mov	DWORD [ebp-8], 0   ; size of list

	; push start location
	lea	eax, [ebp-8] ; (size of list) addr
	push	DWORD [xpos]
	push	DWORD [ypos]
	push	DWORD [layer]
	push	DWORD [ebp-4]
	push	eax
	call	add_list
	add	esp, 20

	; animation speed in 1/100ths of a second
	mov	DWORD [ebp-16], 100

	mov	DWORD [ebp-12], 0
	auto_loop_start:
		; grab next vertex and move to
		lea	eax, [ebp-8]
		push	DWORD [ebp-4]
		push	eax	

		cmp	DWORD [ebp+8], 1 ; Determine search type
		je	auto_do_dequeue

		call	pop_list
		add	esp, 8
		jmp	auto_do_move

		auto_do_dequeue:
		call	dequeue_list
		add	esp, 8

		auto_do_move:
		push	eax
		push	ebx
		push	ecx
		call	move_to
		add	esp, 12

		; draw the maze
		push	DWORD [ebp-16]
		push	1
		call	render
		add	esp, 8

		; Check if at flag
		call	at_flag
		cmp	eax, 1
		je	auto_loop_end
	
		auto_loop_continue:
		; Check all 6 directions, if valid & unvisited, push
		lea	eax, [ebp-8]
		push	DWORD [ebp-4]
		push	eax
		call	add_valid_unvisited
		add	esp, 8

		; Animation, sleep for a bit
		mov	DWORD [ebp-20], 0
		sleep_loop_start:
			mov	ecx, DWORD [ebp-20]
			cmp	ecx, DWORD [ebp-16]
			jge	sleep_loop_end

			call	nonblocking_getchar
			movzx	eax, al
			cmp	eax, EXITCHAR
			je	auto_loop_end
			cmp	eax, SPEED_UP
			je	sleep_speed_up
			cmp	eax, SPEED_DOWN
			je	sleep_speed_down
			jmp	sleep_continue

			sleep_speed_up:
			cmp	DWORD [ebp-16], SPEED_INC
			je	sleep_continue
			sub	DWORD [ebp-16], SPEED_INC
			jmp	sleep_continue

			sleep_speed_down:
			cmp	DWORD [ebp-16], MAX_SPEED
			je	sleep_continue
			add	DWORD [ebp-16], SPEED_INC

			sleep_continue:
			push	10000 ; Sleep for 1/10th of a second
			call	usleep
			add	esp, 4

			inc	DWORD [ebp-20]
			jmp	sleep_loop_start
		sleep_loop_end:

		inc	DWORD [ebp-12]
		jmp	auto_loop_start
	auto_loop_end:

	; free the data structure
	push	DWORD [ebp-4]
	call	free
	add	esp, 4

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Determines whether the player is currently at the flag.
; Returns a 1 if the player is at the flag, 0 otherwise.
; Returns: at_flag (eax)
at_flag:
	push	ebp
	mov	ebp, esp

	; At flag if (x,y,layer) == (width-1, height-1, layers-1)
	mov	eax, DWORD [width]
	dec	eax
	cmp	eax, DWORD [xpos]
	jne	at_flag_no
	mov	eax, DWORD [height]
	dec	eax
	cmp	eax, DWORD [ypos]
	jne	at_flag_no
	mov	eax, DWORD [layers]
	dec	eax
	cmp	eax, DWORD [layer]
	jne	at_flag_no
	
	mov	eax, 1
	jmp	at_flag_end

	at_flag_no:
	mov	eax, 0

	at_flag_end:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Move to the specified coords, adding to visited as we do
; Args: x, y, layer
move_to:
	push	ebp
	mov	ebp, esp

	mov	eax, DWORD [ebp+16]
	mov	ebx, DWORD [ebp+12]
	mov	ecx, DWORD [ebp+8]

	mov	DWORD [xpos], eax
	mov	DWORD [ypos], ebx
	mov	DWORD [layer], ecx

	push	DWORD [xpos]
	push	DWORD [ypos]
	push	DWORD [layer]
	call	add_visited
	add	esp, 12

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Check all 6 cardinal directions from the current location. For each,
; if it is a valid move and not visited, add it to the given list.
; Args: list_ptr, list_size_ptr
add_valid_unvisited:
	push	ebp
	mov	ebp, esp
	sub	esp, 20

	mov	DWORD [ebp-4], 0 ; x, y, or layer
	add_valid_unvisited_outer_loop_start:
		cmp	DWORD [ebp-4], 2
		jg	add_valid_unvisited_outer_loop_end

		mov	DWORD [ebp-8], -1
		add_valid_unvisited_inner_loop_start:
			cmp	DWORD [ebp-8], 1
			jg	add_valid_unvisited_inner_loop_end

			mov	eax, DWORD [xpos]
			mov	ebx, DWORD [ypos]
			mov	ecx, DWORD [layer]

			cmp	DWORD [ebp-4], 0 ; x dir
			je	modify_x
			cmp	DWORD [ebp-4], 1 ; y dir
			je	modify_y
			jmp	modify_layer	 ; layer dir

			modify_x:
			add	eax, DWORD [ebp-8]
			jmp	modify_done
			modify_y:
			add	ebx, DWORD [ebp-8]
			jmp	modify_done
			modify_layer:
			add	ecx, DWORD [ebp-8]
			modify_done:

			mov	DWORD [ebp-12], eax
			mov	DWORD [ebp-16], ebx
			mov	DWORD [ebp-20], ecx

			push	DWORD [xpos]
			push	DWORD [ypos]
			push	DWORD [layer]
			push	DWORD [ebp-12]
			push	DWORD [ebp-16]
			push	DWORD [ebp-20]
			call	valid_move
			add	esp, 24

			cmp	al, 1
			jne	add_valid_unvisited_continue
			
			push	DWORD [ebp-12]
			push	DWORD [ebp-16]
			push	DWORD [ebp-20]
			push	DWORD [visited]
			push	DWORD [visited_len]
			call	in_list
			add	esp, 20

			cmp	eax, 0
			jne	add_valid_unvisited_continue
			
			; Valid & unvisited, add to list
			push	DWORD [ebp-12]
			push	DWORD [ebp-16]
			push	DWORD [ebp-20]
			push	DWORD [ebp+12] ; list_ptr
			push	DWORD [ebp+8]  ; list_size_ptr
			call	add_list
			add	esp, 20

			add_valid_unvisited_continue:
			add	DWORD [ebp-8], 2
			jmp	add_valid_unvisited_inner_loop_start
		add_valid_unvisited_inner_loop_end:
	
		inc	DWORD [ebp-4]
		jmp	add_valid_unvisited_outer_loop_start
	add_valid_unvisited_outer_loop_end:

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Calculates the path from the start position
; to the current position, and places that list
; of values into `path`
calc_path:
	push	ebp
	mov	ebp, esp
	sub	esp, 4	; index

	push	DWORD [xpos]
	push	DWORD [ypos]
	push	DWORD [layer]
	push	DWORD [visited]
	push	DWORD [visited_len]
	call	offsetof_list
	add	esp, 20
	
	mov	DWORD [ebp-4], eax

	mov	DWORD [path_len], 0
	push	DWORD [xpos]
	push	DWORD [ypos]
	push	DWORD [layer]
	push	DWORD [path]
	push	path_len
	call	add_list
	add	esp, 20

	sub	DWORD [ebp-4], 12
	calc_path_loop_start:
		cmp	DWORD [ebp-4], 0
		jl	calc_path_loop_end

		mov	eax, DWORD [path_len]
		dec	eax
		mov	ebx, 12
		mul	ebx

		add	eax, DWORD [path]

		mov	ecx, DWORD [visited]
		add	ecx, DWORD [ebp-4]

		push	DWORD [ecx]
		push	DWORD [ecx + 4]
		push	DWORD [ecx + 8]
		push	DWORD [eax]
		push	DWORD [eax + 4]
		push	DWORD [eax + 8]
		call	valid_move
		add	esp, 24

		cmp	al, 1
		jne	calc_path_continue
		
		mov	ecx, DWORD [visited]
		add	ecx, DWORD [ebp-4]
		push	DWORD [ecx]
		push	DWORD [ecx + 4]
		push	DWORD [ecx + 8]
		push	DWORD [path]
		push	path_len
		call	add_list
		add	esp, 20
		
		calc_path_continue:
		sub	DWORD [ebp-4], 12
		jmp	calc_path_loop_start
	calc_path_loop_end:

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Adds the given coords to the path.
; Args: x, y, layer
add_path:
	push	ebp
	mov	ebp, esp

	mov	eax, DWORD [path_len]
	mov	ebx, 12
	mul	ebx

	mov	ebx, DWORD [ebp+16]
	mov	ecx, DWORD [ebp+12]
	mov	edx, DWORD [ebp+8]

	add	eax, DWORD [path]
	mov	DWORD [eax], ebx
	mov	DWORD [eax + 4], ecx
	mov	DWORD [eax + 8], edx

	inc	DWORD [path_len]

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Adds the given coords to the list of visited
; nodes, if it is not already in the list.
; Args: x, y, layer
add_visited:
	push	ebp
	mov	ebp, esp

	push	DWORD [ebp+16]
	push	DWORD [ebp+12]
	push	DWORD [ebp+8]
	push	DWORD [visited]
	push	DWORD [visited_len]
	call	in_list
	add	esp, 20

	cmp	eax, 1
	je	dont_add
	
	push	DWORD [ebp+16]
	push	DWORD [ebp+12]
	push	DWORD [ebp+8]
	push	DWORD [visited]
	push	visited_len
	call	add_list
	add	esp, 20

	dont_add:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Returns 1 if the given coords are a valid move
; from the given coords. 0 otherwise.
; Args: cur_x, cur_y, cur_layer, new_x, new_y, new_layer
; Returns: valid (al)
valid_move:
	push	ebp
	mov	ebp, esp

	sub	esp, 4 ; Keeps track of hor/ver/layer check

	mov	eax, DWORD [ebp+28]
	mov	ebx, DWORD [ebp+24]
	mov	ecx, DWORD [ebp+20]

	; Boundary checks
	mov	edx, DWORD [ebp+16]
	cmp	edx, 0
	jl	invalid
	cmp	edx, DWORD [width]
	jge	invalid
	mov	edx, DWORD [ebp+12]
	cmp	edx, 0
	jl	invalid
	cmp	edx, DWORD [height]
	jge	invalid
	mov	edx, DWORD [ebp+8]
	cmp	edx, 0
	jl	invalid
	cmp	edx, DWORD [layers]
	jge	invalid

	; Adjacency checks
	mov	edx, DWORD [ebp+28] ; cur_x
	sub	edx, DWORD [ebp+16] ; new_x
	cmp	edx, 0
	je	check_y_adj
	cmp	edx, -1
	jl	invalid
	cmp	edx, 1
	jg	invalid
	cmp	ebx, DWORD [ebp+12]
	jne	invalid
	cmp	ecx, DWORD [ebp+8]
	jne	invalid
	jmp	check_walls

	check_y_adj:
	mov	edx, DWORD [ebp+24] ; cur_y
	sub	edx, DWORD [ebp+12] ; new_y
	cmp	edx, 0
	je	check_layer_adj
	cmp	edx, -1
	jl	invalid
	cmp	edx, 1
	jg	invalid
	cmp	ecx, DWORD [ebp+8]
	jne	invalid
	jmp	check_walls

	check_layer_adj:
	mov	edx, DWORD [ebp+20] ; cur_layer
	sub	edx, DWORD [ebp+8]  ; new_layer
	cmp	edx, -1
	jl	invalid
	cmp	edx, 1
	jg	invalid
	; Adjacency check passed
	
	check_walls:
	; Wall checks
	mov	DWORD [ebp-4], E_OFFSET
	cmp	eax, DWORD [ebp+16]
	je	check_ver
	jl	validate
	
	mov	eax, DWORD [ebp+16]
	jmp	validate

	check_ver:
	mov	DWORD [ebp-4], S_OFFSET
	cmp	ebx, DWORD [ebp+12]
	je	check_layer
	jl	validate

	mov	ebx, DWORD [ebp+12]
	jmp	validate

	check_layer:
	mov	DWORD [ebp-4], D_OFFSET
	cmp	ecx, DWORD [ebp+8]
	jl	validate

	mov	ecx, DWORD [ebp+8]

	validate:
	push	eax
	push	ebx
	push	ecx
	call	coord_to_offset
	add	esp, 12

	add	eax, DWORD [maze]
	add	eax, DWORD [ebp-4]
	mov	al, BYTE [eax]
	jmp	valid_move_end

	invalid:
	mov	eax, 0

	valid_move_end:
	mov	esp, ebp
	pop	ebp
	ret

; ==================== Rendering Functions ====================

; === FUNCTION ===
; Solve Mode 0 indicates manual mode, 1 indicates auto mode. In auto mode, auto_solve_speed should also be passed as an argument.
; Args: [auto_solve_speed], solve_mode
render:
	push	ebp
	mov	ebp, esp

	; two ints, for two loop counters
	; ebp-4, ebp-8
	sub	esp, 8

	; calculate the current path
	call	calc_path

	; clear the screen
	push	clear_screen_cmd
	call	system
	add	esp, 4

	; print the help information
	cmp	DWORD [ebp+8], 1
	je	render_print_auto
	
	mov	eax, manual_help_str
	jmp	render_print_help

	render_print_auto:
	mov	eax, auto_help_str

	render_print_help:
	push	eax
	call	printf
	add	esp, 4

	; print the current layer info
	mov	eax, DWORD [layer]
	inc	eax

	push	DWORD [layers]
	push	eax
	push	layer_fmt_str
	call	printf
	add	esp, 12

	; outside loop by height
	; i.e. for(c=0; c<=(2*height+1); c++)
	mov	DWORD [ebp-4], 0
	y_loop_start:
	mov	eax, DWORD [height]
	mov	ebx, 2
	mul	ebx
	cmp	DWORD [ebp-4], eax
	jg	y_loop_end

		; inside loop by width
		; i.e. for(c=0; c<=(2*width+1); c++)
		mov	DWORD [ebp-8], 0
		x_loop_start:
		mov	eax, DWORD [width]
		mov	ebx, 2
		mul	ebx
		cmp	DWORD [ebp-8], eax
		jg 	x_loop_end
			; if on wall column (x % 2 == 0)
			mov	eax, DWORD [ebp-8]
			mov	ebx, 2
			cdq
			div	ebx
			cmp	edx, 0
			jne	check_below
			; if so, render vertical wall
			push	DWORD [ebp-8]
			push	DWORD [ebp-4]
			call	render_ver_wall
			add	esp, 8
			jmp	print_end

			check_below:
			; if on wall row (y divisible by 2)
			mov	eax, DWORD [ebp-4]
			mov	ebx, 2
			cdq
			div	ebx
			cmp	edx, 0
			jne	check_player
			; if so, render horiztonal wall
			push	DWORD [ebp-8]
			push	DWORD [ebp-4]
			call	render_hor_wall
			add	esp, 8
			jmp	print_end

			; check if (xpos,ypos)=(x,y)
			check_player:
			push	DWORD [ebp-8]
			push	DWORD [ebp-4]
			call	graph_to_grid
			add	esp, 8

			cmp	eax, DWORD [xpos]
			jne	check_flag
			cmp	ebx, DWORD [ypos]
			jne	check_flag
			; if both were equal, print the player
			push	player
			call	printf
			add	esp, 4
			jmp	print_end

			check_flag:
			mov	eax, DWORD [layers]
			dec	eax
			cmp	DWORD [layer], eax ; on last layer
			jne	check_ladder

			mov	eax, DWORD [width]
			mov	ebx, 2
			mul	ebx
			dec	eax
			cmp	DWORD [ebp-8], eax ; x is right edge
			jne	check_ladder

			mov	eax, DWORD [height]
			mov	ebx, 2
			mul	ebx
			dec	eax
			cmp	DWORD [ebp-4], eax ; y is bottom edge
			jne	check_ladder

			push	flag
			call	printf
			add	esp, 4
			jmp	print_end

			check_ladder:
			; From current down
			push	DWORD [ebp-8]
			push	DWORD [ebp-4]
			call	graph_to_grid
			add	esp, 8

			push	eax
			push	ebx
			push	DWORD [layer]
			call	coord_to_offset
			add	esp, 12

			add	eax, DWORD [maze]
			mov	al, BYTE [eax + D_OFFSET]
			cmp	al, 1
			je	print_hole

			push	DWORD [ebp-8]
			push	DWORD [ebp-4]
			call	graph_to_grid
			add	esp, 8

			mov	ecx, DWORD [layer]
			cmp	ecx, 0
			je	check_path
			dec	ecx

			push	eax
			push	ebx
			push	ecx
			call	coord_to_offset
			add	esp, 12

			add	eax, DWORD [maze]
			mov	al, BYTE [eax + D_OFFSET]
			cmp	al, 1
			je	print_ladder

			check_path:
				push	DWORD [ebp-8]
				push	DWORD [ebp-4]
				call	graph_to_grid
				add	esp, 8

				push	eax
				push	ebx
				push	DWORD [layer]
				push	DWORD [path]
				push	DWORD [path_len]
				call	in_list
				add	esp, 20

				cmp	eax, 1
				jne	check_visited

				push	path_marker
				call	printf
				add	esp, 4
				jmp	print_end

			check_visited:
				push	DWORD [ebp-8]
				push	DWORD [ebp-4]
				call	graph_to_grid
				add	esp, 8

				push	eax
				push	ebx
				push	DWORD [layer]
				push	DWORD [visited]
				push	DWORD [visited_len]
				call	in_list
				add	esp, 20

				cmp	eax, 1
				jne	print_space

				push	crumb
				call	printf
				add	esp, 4
				jmp	print_end

			print_hole:
				push	hole
				call	printf
				add	esp, 4
				jmp	print_end
			
			print_ladder:
				push	ladder
				call	printf
				add	esp, 4
				jmp	print_end

			print_space:
				push	space
				call	printf
				add	esp, 4

			print_end:

		inc	DWORD [ebp-8]
		jmp	x_loop_start
		x_loop_end:

		; write a carriage return (necessary when in raw mode)
		push	0x0d
		call 	putchar
		add	esp, 4

		; write a newline
		push	0x0a
		call	putchar
		add	esp, 4

	inc		DWORD [ebp-4]
	jmp		y_loop_start
	y_loop_end:

	; If in auto mode, print current solve speed
	cmp	DWORD [ebp+8], 1 ; Auto solve mode
	jne	render_end

	mov	eax, MAX_SPEED
	sub	eax, DWORD [ebp+12]
	
	push	MAX_SPEED
	push	eax
	push	speed_fmt_str
	call	printf
	add	esp, 12

	render_end:
	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
; Renders the vertical wall of a space
; args: x, y
render_ver_wall:
	push	ebp
	mov	ebp, esp

	cmp	DWORD [ebp+12], 0
	je	print_ver_wall

	; if y % 2 == 0, print a vertical wall
	mov	eax, DWORD [ebp+8] ; y
	mov	ebx, 2
	cdq
	div	ebx
	cmp	edx, 0
	je	print_ver_wall

	push	DWORD [ebp+12]
	push	DWORD [ebp+8]
	call	graph_to_grid
	add	esp, 8

	push	eax
	push	ebx
	push	DWORD [layer]
	call	coord_to_offset
	add	esp, 12

	add	eax, DWORD [maze]
	mov	al, BYTE [eax + E_OFFSET]
	cmp	al, 0
	je	print_ver_wall

	push	half_space
	call	printf
	add	esp, 4
	jmp	render_ver_end

	print_ver_wall:
	push	ver_wall
	call	printf
	add	esp, 4

	render_ver_end:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Renders the horizontal wall of a space
; args: x, y
render_hor_wall:
	push	ebp
	mov	ebp, esp

	cmp	DWORD [ebp+8], 0 ; y == 0
	je	print_hor_wall

	push	DWORD [ebp+12]
	push	DWORD [ebp+8]
	call	graph_to_grid
	add	esp, 8

	push	eax
	push	ebx
	push	DWORD [layer]
	call	coord_to_offset
	add	esp, 12

	add	eax, DWORD [maze]
	mov	al, BYTE [eax + S_OFFSET]
	cmp	al, 0
	je	print_hor_wall

	push	space
	call	printf
	add	esp, 4
	jmp	render_hor_end

	print_hor_wall:
	push	hor_wall
	call	printf
	add	esp, 4
	
	render_hor_end:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Converts graphical (x,y) coordinates
; to grid (x,y) coordinates
; args: x, y
; Returns: x (eax), y (ebx)
graph_to_grid:
	push	ebp
	mov	ebp, esp

	; y = (y-1)/2
	mov	eax, DWORD [ebp+8]  ; y
	dec	eax
	mov	ebx, 2
	cdq
	div	ebx
	mov	ebx, eax

	; x = (x-1)/2
	mov	eax, DWORD [ebp+12] ; x
	dec	eax
	mov	ecx, 2
	cdq
	div	ecx

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Converts (x,y) coordinates to
; the offset into the maze buffer.
; args: x, y, layer
; Returns: offset (eax)
coord_to_offset:
	push	ebp
	mov	ebp, esp

	; calc position in maze buffer
	; ((H*W*L)+(R*W)+C)*3

	; R*W+C
	mov	eax, DWORD [ebp+12]
	mov	ebx, DWORD [width]
	mul	ebx
	add	eax, DWORD [ebp+16]
	mov	ebx, eax

	; H*W*L
	mov	eax, DWORD [height]
	mov	ecx, DWORD [width]
	mul	ecx
	mov	ecx, DWORD[ebp+8]
	mul	ecx

	; X*3
	add	eax, ebx
	mov	ebx, 3
	mul	ebx

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Returns the number of vertices in the graph/maze
; Returns: num_vertices (eax)
num_vertices:
	push	ebp
	mov	ebp, esp

	mov	eax, DWORD [width]
	mov	ebx, DWORD [height]
	mul	ebx
	mov	ebx, DWORD [layers]
	mul	ebx

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Returns the number of possible edges in the graph/maze
; Returns: num_edges (eax)
num_edges:
	push	ebp
	mov	ebp, esp

	call	num_vertices
	mov	ebx, 3
	mul	ebx

	mov	esp, ebp
	pop	ebp
	ret

; ==================== List Functions ====================

; === FUNCTION ===
; Remove the last item in the list and return it
; Args: list_ptr, list_len_ptr
; Returns: x (eax), y (ebx), layer (ecx)
pop_list:
	push	ebp
	mov	ebp, esp

	; Offset to last item
	mov	eax, DWORD [ebp+8]
	dec	DWORD [eax]
	mov	eax, DWORD [eax]
	mov	ebx, 12
	mul	ebx
	add	eax, DWORD [ebp+12]

	mov	edx, eax

	mov	eax, DWORD [edx]
	mov	ebx, DWORD [edx + 4]
	mov	ecx, DWORD [edx + 8]

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Remove the first item in the list and return it
; Args: list_ptr, list_len_ptr
; Returns: x (eax), y (ebx), layer (ecx)
dequeue_list:
	push	ebp
	mov	ebp, esp
	sub	esp, 16

	; Grab first item
	mov	eax, DWORD [ebp+12]
	mov	ebx, DWORD [eax]
	mov	DWORD [ebp-4], ebx
	mov	ebx, DWORD [eax + 4]
	mov	DWORD [ebp-8], ebx
	mov	ebx, DWORD [eax + 8]
	mov	DWORD [ebp-12], ebx

	; Shift list down one
	mov	eax, DWORD [ebp+8]
	mov	eax, DWORD [eax]
	sub	eax, 2
	mov	DWORD [ebp-16], eax

	; Decrement list length
	mov	ebx, DWORD [ebp+8]
	dec	DWORD [ebx]

	; Copy for comparison
	mov	eax, DWORD [ebx]
	mov	DWORD [ebp-16], eax

	mov	ecx, 0
	dequeue_list_loop_start:
		cmp	ecx, DWORD [ebp-16]
		jge	dequeue_list_loop_end

		; Move ecx+1 to ecx
		mov	eax, ecx
		mov	ebx, 12
		mul	ebx

		mov	ebx, DWORD[ebp+12]
		mov	edx, DWORD [ebx + eax + 12] ; move x
		mov	DWORD [ebx + eax], edx
		mov	edx, DWORD [ebx + eax + 16] ; move y
		mov	DWORD [ebx + eax + 4], edx
		mov	edx, DWORD [ebx + eax + 20] ; move layer
		mov	DWORD [ebx + eax + 8], edx
		
		inc	ecx
		jmp	dequeue_list_loop_start
	dequeue_list_loop_end:


	; Move stored values to return registers
	mov	eax, DWORD [ebp-4]
	mov	ebx, DWORD [ebp-8]
	mov	ecx, DWORD [ebp-12]

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Add the given tuple of DWORD values to the given list
; Args: (a,b,c,...), list_ptr, list_len_ptr
add_list:
	push	ebp
	mov	ebp, esp

	; offset = list_len * sizeof(DWORD) * tuple_size
	mov	eax, DWORD [ebp+8]
	mov	eax, DWORD [eax]
	mov	ebx, 12
	mul	ebx
	add	eax, DWORD [ebp+12]

	mov	ebx, DWORD [ebp+24]
	mov	ecx, DWORD [ebp+20]
	mov	edx, DWORD [ebp+16]
	mov	DWORD [eax], ebx
	mov	DWORD [eax + 4], ecx
	mov	DWORD [eax + 8], edx

	mov	eax, DWORD [ebp+8]
	inc	DWORD [eax]

	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Returns 1 if the given values are in the list,
; 0 otherwise.
; Args: (a,b,c,...), list_ptr, list_len
in_list:
	push	ebp
	mov	ebp, esp

	mov	ecx, 0
	in_list_loop_start:
		cmp	ecx, DWORD [ebp+8]
		jge	in_list_loop_end

		; Calc buffer offset
		mov	eax, ecx
		mov	ebx, 12
		mul	ebx

		mov	edx, DWORD [ebp+12]

		mov	ebx, DWORD [ebp+24]
		cmp	DWORD [edx + eax], ebx
		jne	in_list_continue
		mov	ebx, DWORD [ebp+20]
		cmp	DWORD [edx + eax + 4], ebx
		jne	in_list_continue
		mov	ebx, DWORD [ebp+16]
		cmp	DWORD [edx + eax + 8], ebx
		jne	in_list_continue

		mov	eax, 1
		jmp	end_in_list

		in_list_continue:
		inc	ecx
		jmp	in_list_loop_start
	in_list_loop_end:

	mov	eax, 0

	end_in_list:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Returns the offset into the list of the given coords
; Args: x, y, layer, list_ptr, list_len
; Returns: offset (eax)
offsetof_list:
	push	ebp
	mov	ebp, esp

	mov	ecx, 0
	offsetof_list_loop_start:
		cmp	ecx, DWORD [ebp+8] ; cmp to list_len
		jge	offsetof_list_loop_end

		; Calc offset into buffer
		mov	eax, ecx
		mov	ebx, 12
		mul	ebx

		mov	ebx, DWORD [ebp+12] ; list_ptr

		mov	edx, DWORD [ebp+24]
		cmp	DWORD [ebx + eax], edx
		jne	offsetof_list_continue
		mov	edx, DWORD [ebp+20]
		cmp	DWORD [ebx + eax + 4], edx
		jne	offsetof_list_continue
		mov	edx, DWORD [ebp+16]
		cmp	DWORD [ebx + eax + 8], edx
		jne	offsetof_list_continue

		jmp	offsetof_list_end

		offsetof_list_continue:
		inc	ecx
		jmp	offsetof_list_loop_start
	offsetof_list_loop_end:
	
	offsetof_list_end:
	mov	esp, ebp
	pop	ebp
	ret

; === FUNCTION ===
; Returns a pointer to the maximum value in the given list (unsigned)
; Args: list_ptr, list_len
; Returns: max_ptr (eax)
list_max:
	push	ebp
	mov	ebp, esp
	sub	esp, 4

	mov	eax, DWORD [ebp+8]
	mov	ebx, 4
	mul	ebx
	mov	edx, eax		; list_len in bytes

	mov	eax, DWORD [ebp+12]	; current max_ptr
	
	mov	DWORD [ebp-4], 4	; counter
	list_max_loop_start:
		cmp	DWORD [ebp-4], edx
		jge	list_max_loop_end

		mov	ebx, DWORD [ebp+12]
		add	ebx, DWORD [ebp-4]	; ptr to next
		mov	ecx, DWORD [ebx]	; value of next

		cmp	ecx, DWORD [eax]	; if next is greater
		jbe	list_max_continue
		mov	eax, ebx		; max_ptr = next_ptr

		list_max_continue:
		add	DWORD [ebp-4], 4
		jmp	list_max_loop_start
	list_max_loop_end:

	mov	esp, ebp
	pop	ebp
	ret

; ==================== Utility Functions ====================
; === FUNCTION ===
nonblocking_getchar:

; returns -1 on no-data
; returns char on succes

; magic values
%define F_GETFL 3
%define F_SETFL 4
%define O_NONBLOCK 2048
%define STDIN 0

	push	ebp
	mov	ebp, esp

	; single int used to hold flags
	; single character (aligned to 4 bytes) return
	sub	esp, 8

	; get current stdin flags
	; flags = fcntl(stdin, F_GETFL, 0)
	push	0
	push	F_GETFL
	push	STDIN
	call	fcntl
	add	esp, 12
	mov	DWORD [ebp-4], eax

	; set non-blocking mode on stdin
	; fcntl(stdin, F_SETFL, flags | O_NONBLOCK)
	or		DWORD [ebp-4], O_NONBLOCK
	push	DWORD [ebp-4]
	push	F_SETFL
	push	STDIN
	call	fcntl
	add	esp, 12

	call	getchar
	mov	DWORD [ebp-8], eax

	; restore blocking mode
	; fcntl(stdin, F_SETFL, flags ^ O_NONBLOCK
	xor	DWORD [ebp-4], O_NONBLOCK
	push	DWORD [ebp-4]
	push	F_SETFL
	push	STDIN
	call	fcntl
	add	esp, 12

	mov	eax, DWORD [ebp-8]

	mov	esp, ebp
	pop	ebp
	ret

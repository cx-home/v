// inherited.v — the program vgc_inherited_regs_test.v builds (cx-home/v#90). Its first
// statement reads the callee-saved registers main__main was entered with (regs.h): unoptimised
// code writes none of them, so they hold what the process start left there (dyld's r13 on
// darwin x86-64: a page it had freed), and every collection's setjmp (vgc_run_gc_spilled)
// spills them into the root scan for the life of the process. A register naming the heap
// roots whatever is carved there (the dropped transient of vgc_perm_test, 9,375 KB); one
// naming a free page roots whatever a later carve puts there. Neither may hold.
// Prints one line per register and: inherited n=N hazards=H
module main

#include "@DIR/regs.h"

fn C.vgc_ir_snap() int
fn C.vgc_ir_reg(i int) u64
fn C.vgc_ir_page_free(v u64) int

fn main() {
	n := C.vgc_ir_snap()
	mut hazards := 0
	for i in 0 .. n {
		v := C.vgc_ir_reg(i)
		ai, _ := vgc_arena_probe(voidptr(v))
		free := C.vgc_ir_page_free(v) == 1
		if ai >= 0 || free {
			hazards++
		}
		println('reg ${i} 0x${v:x} heap=${ai >= 0} free=${free}')
	}
	println('inherited n=${n} hazards=${hazards}')
}

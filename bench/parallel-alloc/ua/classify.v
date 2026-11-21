// classify.v — the program vgc_unaligned_audit_test.v builds with
// -d vgc_unaligned_audit to read the audit's word classes (cx-home/v#74 piece 4):
// prints `<word> <class>` for each word on the command line, class one of
// round / pair / pointer.
module main

import os

fn main() {
	for a in os.args[1..] {
		w := u64(a.u64())
		println('${a} ${vgc_unaligned_audit_class(w)}')
	}
}

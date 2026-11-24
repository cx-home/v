// render.v — WORKERS threads (default 28) render small pages from a shared
// catalog, the shape of cx-examples' template-render and sql-roundtrips under
// `[par k]` (cx-private#2040): a few MB live, each worker's garbage short-lived,
// every worker allocating a few hundred KB between two collections once the
// goal is small. PAGES pages in all (default 400,000), split evenly. Prints
// `done wall_us=<the workers' wall time> pages=<n> bytes=<checksum>`.
module main

import os
import time

@[heap]
struct Item {
	name  string
	price int
	tags  []string
}

@[heap]
struct Page {
	title string
	body  string
	parts []string
}

fn catalog(n int) []&Item {
	mut c := []&Item{cap: n}
	for i in 0 .. n {
		c << &Item{
			name:  'item-${i}-' + 'x'.repeat(i % 17)
			price: i * 7 % 1000
			tags:  ['t${i % 5}', 't${i % 11}', 't${i % 13}']
		}
	}
	return c
}

fn render(cat []&Item, i int) &Page {
	mut parts := []string{cap: 12}
	for j in 0 .. 12 {
		it := cat[(i * 13 + j * 101) % cat.len]
		parts << '<li class="${it.tags[j % 3]}">${it.name} — ${it.price / 100}.${it.price % 100}</li>'
	}
	return &Page{
		title: 'page ${i}'
		body:  '<ul>' + parts.join('\n') + '</ul>'
		parts: parts
	}
}

fn worker(cat []&Item, from int, to int, ch chan u64) {
	mut ring := []&Page{cap: 32}
	mut sum := u64(0)
	for i in from .. to {
		p := render(cat, i)
		if ring.len < 32 {
			ring << p
		} else {
			ring[i % 32] = p
		}
		sum += u64(p.body.len)
	}
	ch <- sum
}

fn main() {
	workers := os.getenv_opt('WORKERS') or { '28' }.int()
	pages := os.getenv_opt('PAGES') or { '400000' }.int()
	cat := catalog(40000)
	ch := chan u64{cap: workers}
	sw := time.new_stopwatch()
	per := pages / workers
	mut ths := []thread{}
	for w in 0 .. workers {
		ths << spawn worker(cat, w * per, (w + 1) * per, ch)
	}
	ths.wait()
	wall := sw.elapsed().microseconds()
	mut sum := u64(0)
	for _ in 0 .. workers {
		sum += <-ch
	}
	println('done wall_us=${wall} pages=${per * workers} bytes=${sum} items=${cat.len}')
}

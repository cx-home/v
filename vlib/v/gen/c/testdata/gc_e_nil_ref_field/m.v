module p5

pub struct ElementMeta {
pub mut:
	id ?string
}

pub struct Element {
pub mut:
	name string
	meta &ElementMeta = unsafe { nil }
}

pub struct Document {
pub mut:
	elements []Element
}

pub struct ParseResult {
pub mut:
	multi ?[]Document
}

pub fn parse(src string) ParseResult {
	mut docs := []Document{}
	for part in src.split('---') {
		docs << Document{
			elements: [Element{
				name: part
			}]
		}
	}
	return ParseResult{
		multi: docs
	}
}

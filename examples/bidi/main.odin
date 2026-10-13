// Bidi: right-to-left and mixed-direction text, and line breaking in
// scripts without spaces. The browser finds each paragraph's direction from
// its first letter, or from the Dir attribute.
package main

import nb "../../sdk/nb"

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "12")
	nb.set_attr(root, .Width, "560")
	nb.el(.Heading, root, "Directions")

	nb.el(.Paragraph, root, "English with a Hebrew phrase, שלום עולם, in the middle of the sentence, and Arabic, مرحبا بالعالم, after it.")
	nb.el(.Paragraph, root, "שלום עולם! זוהי פסקה בעברית עם מילה באנגלית (browser) ומספר 2026 בתוכה, והיא נשברת לשורות מימין לשמאל.")
	nb.el(.Paragraph, root, "هذه فقرة باللغة العربية تحتوي على رقم 123 وكلمة English في وسطها، وتلتف من اليمين إلى اليسار.")

	p := nb.el(.Paragraph, root, "Inline styles keep their direction: ")
	nb.el(.Strong, p, "עברית מודגשת")
	nb.el(.Text, p, " then ")
	link := nb.el(.Link, p, "קישור")
	nb.set_attr(link, .Href, "hello.elf")
	nb.el(.Text, p, ".")

	forced := nb.el(.Paragraph, root, "Dir=rtl: this English paragraph is set right to left, so it aligns right.")
	nb.set_attr(forced, .Dir, "rtl")

	list := nb.el(.List, root)
	nb.set_attr(list, .Dir, "rtl")
	nb.el(.List_Item, list, "פריט ראשון")
	nb.el(.List_Item, list, "פריט שני")

	nb.el(.Heading, root, "Breaking")
	nb.el(.Paragraph, root, "日本語の文章は単語の間に空白がありませんが、文字の間で改行できます。句読点「、」や「。」は行頭に来ません。")
	nb.el(.Paragraph, root, "A very long word breaks anywhere when it cannot fit: Pneumonoultramicroscopicsilicovolcanoconiosisandthensomemoretomakeitreallylong.")

	area := nb.el(.Text_Area, root, "כתבו כאן: Hebrew and English together.")
	nb.set_attr(area, .Label, "Notes")
	nb.set_attr(area, .Width, "400")
	input := nb.el(.Input, root, "שדה עם text באמצע")
	nb.set_attr(input, .Label, "Field")

	nb.set_root(root)
	for {
		ev, ok := nb.wait_event()
		if ok && ev.kind == .Quit {
			return
		}
	}
}

@(export, link_name = "_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}

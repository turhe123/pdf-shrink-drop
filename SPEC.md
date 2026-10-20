# PdfShrinkDrop — specification

**Tagline:** Drop big PDFs onto the window or Dock icon and get smaller copies with a size preset and before and after sizes.

**Category:** Files & Conversion

**Inspired by (paid):** PDF Squeezer ($14.99 one-time)

**Frameworks:** SwiftUI, AppKit, PDFKit, Quartz, UniformTypeIdentifiers, ImageIO

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: PDF Squeezer shrinks PDF files by recompressing images and removing extras, with presets and drag and drop, and it sells for about fifteen dollars on the Mac App Store. It has years of positive reviews and appears in many Mac PDF tool roundups, and the constant need to email or upload smaller PDFs makes the demand easy to see.

Our clean-room feature set: drop one or many PDFs and choose a preset: Small for screen reading, Medium for general sharing and High for print quality. Each preset sets the maximum image dimension and JPEG quality. A custom option exposes two sliders. The result list shows original size, new size, percentage saved and a status. Output goes next to the original with a suffix, or into a chosen folder. A Replace original checkbox is off by default. Also include a Merge option that joins the dropped files into one PDF in order, and a basic page reorder through a drag list is out of scope. Roughly four hundred fifty lines.

UI spec: a single window app. The top shows a preset segmented control and, for custom, two sliders. The middle shows a list of files with thumbnails of page one, sizes, a progress bar per file and a reveal in Finder button. The bottom has Output Folder choice, Replace Original toggle, and a Compress button bound to Command Return. File menu offers Open PDFs with Command O. Empty state: a large drop target saying drop PDF files to shrink them. Settings are minimal and reuse the same window controls through AppStorage.

Technical approach: load each document with PDFDocument. For recompression, render each page into a new PDF context using CGContext with a PDF media box, drawing page content through PDFPage.draw. That would rasterize text, so instead apply the built-in Quartz filter route: create a QuartzFilter from the system Reduce File Size filter or from a generated dictionary and write the document with the quartzFilter write option. As a second path for custom settings, walk the pages and rasterize only pages that are image-heavy, detected by comparing file size per page, while keeping text pages as vector pages by copying them. Use ImageIO to downsample and encode JPEG at the chosen quality. Run work on a detached Task per file and publish progress. Merge uses PDFDocument insert page across documents. Only user-selected files are touched, and writes use atomic replacement.

Edge cases: password protected PDFs show a locked status and offer an unlock prompt. If the result is larger than the original, keep the original and mark the row as already optimal. Never overwrite the original unless the replace toggle is on and then move the old file to the Trash first. Handle corrupted files with an error row instead of failing the batch. Preserve metadata such as title and author when possible. Skip files that are not PDFs. Cancel stops the current job and removes partial output files. Large files are processed page by page to keep memory low.

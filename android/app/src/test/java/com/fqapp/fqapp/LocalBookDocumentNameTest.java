package com.fqapp.fqapp;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class LocalBookDocumentNameTest {
    @Test
    public void longProviderNamesRetainTheSelectedFormat() {
        String txt = LocalBookPickerPluginKt.localNovelDocumentName(
                "a".repeat(240) + ".TXT", "text/plain");
        String epub = LocalBookPickerPluginKt.localNovelDocumentName(
                "书".repeat(240) + ".epub", "application/epub+zip");
        assertEquals("a".repeat(236) + ".txt", txt);
        assertEquals("书".repeat(235) + ".epub", epub);
        assertEquals(240, txt.length());
        assertEquals(240, epub.length());
    }

    @Test
    public void missingOrExtensionlessNamesUseAnExplicitSupportedMimeType() {
        assertEquals("book.txt", LocalBookPickerPluginKt.localNovelDocumentName(null, "text/plain"));
        assertEquals("book.epub", LocalBookPickerPluginKt.localNovelDocumentName(" ", "application/epub+zip"));
        assertEquals("我的小说.txt", LocalBookPickerPluginKt.localNovelDocumentName("我的小说", "text/plain"));
    }

    @Test
    public void unsupportedAndUnknownFormatsAreNotRelabeledAsNovels() {
        assertEquals("book.pdf", LocalBookPickerPluginKt.localNovelDocumentName("book.pdf", "text/plain"));
        assertEquals("book", LocalBookPickerPluginKt.localNovelDocumentName(null, "application/octet-stream"));
        assertEquals("原名.epub", LocalBookPickerPluginKt.localNovelDocumentName("原名.EPUB", "application/octet-stream"));
    }
}

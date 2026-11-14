#requires -Version 7.2
[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'build/novel-validation/features-16-2026-11-14/fixtures' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$fixtureText = "这是一段必须保留的前言。`n第一章 清晨`n清晨的书桌上放着一枚青铜钥匙 bronze_key。`n" + ((1..40 | ForEach-Object { "第$_段：林舟翻开小说，窗外传来风声。" }) -join "`n") + "`n第二章 远行`n青铜钥匙 bronze_key 打开了院门。林舟踏上新的旅程。`n" + ((1..40 | ForEach-Object { "第$_段：远方的山岭安静地等待旅人。" }) -join "`n") + "`n第三章 归来`n林舟带着青铜钥匙 bronze_key 回到书桌旁。故事暂告一段落。"
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'feature-story.txt'), $fixtureText, [Text.UTF8Encoding]::new($false))
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'feature-gb18030.txt'), "第一章 编码验证`n这是采用GB18030保存的中文小说。生僻字：𠀀。", [Text.Encoding]::GetEncoding('GB18030'))
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'feature-broken.epub'), [byte[]](1,2,3,4))
$epubFile = Join-Path $OutputDirectory 'feature-story.epub'
if (Test-Path -LiteralPath $epubFile) { throw 'Fixture exists; choose a new output directory rather than overwrite it.' }
$epubStream = [IO.File]::Open($epubFile, [IO.FileMode]::CreateNew)
$epubArchive = [IO.Compression.ZipArchive]::new($epubStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    $documents = [ordered]@{
        'mimetype' = 'application/epub+zip'
        'META-INF/container.xml' = '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>'
        'OEBPS/content.opf' = '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>本地EPUB验收小说</dc:title><dc:creator>验收样本</dc:creator></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>'
        'OEBPS/one.xhtml' = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章 山门</title></head><body><h1>第一章 山门</h1><p>山门口有一棵银杏树。这是第一章的完整正文。</p><p>旅人拾起一片叶子。</p></body></html>'
        'OEBPS/two.xhtml' = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章 归途</title></head><body><h1>第二章 归途</h1><p>旅人又回到银杏树下。这是第二章的完整正文。</p></body></html>'
    }
    foreach ($document in $documents.GetEnumerator()) {
        $entry = $epubArchive.CreateEntry($document.Key, [IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try { $entryBytes = [Text.Encoding]::UTF8.GetBytes($document.Value); $entryStream.Write($entryBytes, 0, $entryBytes.Length) } finally { $entryStream.Dispose() }
    }
} finally { $epubArchive.Dispose(); $epubStream.Dispose() }
Get-ChildItem -LiteralPath $OutputDirectory -File | Select-Object Name,Length

# Move the session list UI out of build() into a @Builder, and add the
# two-column (wide screen) body next to it.
$ErrorActionPreference = 'Stop'

$file = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\src\main\ets\pages\SessionListPage.ets'
$bytes = [System.IO.File]::ReadAllBytes($file)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)

function L { param([string[]]$Lines) return ($Lines -join "`n") }

# ---- locate the list block ----------------------------------------------------
$startMarker = L @('        // ---------- 列表 ----------', '        if (this.loading) {')
$startIdx = $text.IndexOf($startMarker)
if ($startIdx -lt 0) { throw 'list block start not found' }
$chainStart = $startIdx + $startMarker.Length - '        if (this.loading) {'.Length

$endMarker = L @('          .scrollBar(BarState.Off)', '        }')
$endIdx = $text.IndexOf($endMarker, $chainStart)
if ($endIdx -lt 0) { throw 'list block end not found' }
$chainEnd = $endIdx + $endMarker.Length

$chain = $text.Substring($chainStart, $chainEnd - $chainStart)
[Console]::WriteLine(("  list block: {0} chars" -f $chain.Length))

# re-indent the block by two spaces so it sits inside the @Builder
$indented = (($chain -split "`n") | ForEach-Object { if ($_.Trim().Length -gt 0) { '  ' + $_ } else { $_ } }) -join "`n"

$builder = L @(
  '  /**',
  '   * 会话列表(窄屏时铺满整屏, 宽屏时占左栏)。',
  '   */',
  '  @Builder',
  '  sessionListBody() {'
) + "`n" + $indented + "`n" + L @(
  '  }',
  '',
  '  /**',
  '   * 双栏: 左边会话列表, 右边会话详情(宽屏 >= 600vp 时用, 不跳路由)。',
  '   */',
  '  @Builder',
  '  twoColumnBody() {',
  '    Row() {',
  '      // 左: 会话列表',
  '      Column() {',
  '        this.sessionListBody()',
  '',
  '        // 双栏时"新会话"放在列表栏底部, 免得浮在右栏的输入区上面',
  "        Button('新会话')",
  '          .type(ButtonType.Normal)',
  '          .height(40)',
  "          .width('100%')",
  '          .borderRadius(Radius.PILL)',
  '          .backgroundColor(Palette.ACCENT_SOLID)',
  "          .fontColor('#FFFFFF')",
  '          .fontSize(FontSize.SMALL)',
  '          .margin({ left: Space.LG, right: Space.LG, bottom: Space.MD })',
  '          .onClick(() => { this.openNewSession(); })',
  '      }',
  '      .layoutWeight(0.38)',
  "      .height('100%')",
  '      .backgroundColor(Palette.SIDEBAR)',
  '',
  "      Rect({ width: 1, height: '100%' })",
  '        .fill(Palette.BORDER_SOFT)',
  '',
  '      // 右: 会话详情',
  '      Column() {',
  '        this.sessionDetailPane()',
  '      }',
  '      .layoutWeight(0.62)',
  "      .height('100%')",
  '      .backgroundColor(Palette.BG)',
  '    }',
  "    .width('100%')",
  '    .layoutWeight(1)',
  '  }',
  '',
  '  /**',
  '   * 右栏内容: 选中的会话, 或者一句提示。',
  '   */',
  '  @Builder',
  '  sessionDetailPane() {',
  '    if (this.selectedId.length > 0) {',
  '      SessionDetailView({',
  '        sessionId: this.selectedId,',
  '        title: this.selectedTitle,',
  '        cwd: this.selectedCwd,',
  '        showBack: false',
  '      })',
  '    } else {',
  '      Column({ space: Space.MD }) {',
  "        Text('选择一个会话')",
  '          .fontSize(FontSize.TITLE)',
  '          .fontColor(Palette.TEXT_2)',
  "        Text('在左边的列表里挑一个会话, 这里会显示完整对话')",
  '          .fontSize(FontSize.SMALL)',
  '          .fontColor(Palette.TEXT_3)',
  '      }',
  "      .width('100%')",
  "      .height('100%')",
  '      .justifyContent(FlexAlign.Center)',
  '    }',
  '  }',
  ''
)

# ---- replace the list block with the dispatch --------------------------------
$dispatch = L @(
  '        // ---------- 主体: 宽屏双栏, 窄屏还是原来那一套 ----------',
  '        if (this.wideLayout) {',
  '          this.twoColumnBody()',
  '        } else {',
  '          this.sessionListBody()',
  '        }'
)
$text = $text.Substring(0, $startIdx) + $dispatch + $text.Substring($chainEnd)
[Console]::WriteLine('  list block replaced by dispatch')

# ---- insert the builders before build() ---------------------------------------
$buildIdx = $text.IndexOf("  build() {")
if ($buildIdx -lt 0) { throw 'build() not found' }
$text = $text.Substring(0, $buildIdx) + $builder + $text.Substring($buildIdx)
[Console]::WriteLine('  builders inserted')

$enc = New-Object System.Text.UTF8Encoding($hasBom)
[System.IO.File]::WriteAllText($file, $text, $enc)
Write-Output ("wrote {0} ({1} bytes)" -f $file, (Get-Item $file).Length)

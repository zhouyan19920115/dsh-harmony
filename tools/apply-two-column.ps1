# Apply the large-screen (two column) adaptation to SessionListPage.ets.
#
# Everything is done with exact string replacement so the untouched parts of the
# file stay byte identical.
$ErrorActionPreference = 'Stop'

$file = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\src\main\ets\pages\SessionListPage.ets'
$bytes = [System.IO.File]::ReadAllBytes($file)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)

# --- helpers ------------------------------------------------------------------
# The working tree uses CRLF (git autocrlf), so every pattern has to be built
# with the same line ending the file actually has.
$script:NL = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
[Console]::WriteLine(("  line ending: {0}" -f $(if ($script:NL -eq "`r`n") { 'CRLF' } else { 'LF' })))

# Join lines into one block. (Here-strings are avoided: a terminator followed by
# more text on the same line is ambiguous.)
function Join-Lines {
  param([string[]]$Lines)
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($line in $Lines) { $list.Add($line) }
  return [string]::Join($script:NL, $list)
}

function Replace-Exact {
  param([string]$Content, [string]$Old, [string]$New, [string]$Label)
  $i = $Content.IndexOf($Old)
  if ($i -lt 0) { throw "PATTERN NOT FOUND: $Label" }
  [Console]::WriteLine(("  patched: {0}" -f $Label))
  return $Content.Substring(0, $i) + $New + $Content.Substring($i + $Old.Length)
}

# --- 1. imports ---------------------------------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  "import { Palette, Space, Radius, FontSize } from '../common/Theme';"
)) (Join-Lines @(
  "import { Palette, Space, Radius, FontSize } from '../common/Theme';",
  "import { BreakpointObserver } from '../common/Breakpoints';",
  "import { SessionDetailView } from './SessionDetailView';"
)) 'imports'

# --- 2. state -----------------------------------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  '  /** 折叠起来的工作区(cwd) */',
  '  @State collapsedKeys: string[] = [];',
  '',
  '  private listener: BridgeListener = new BridgeListener();'
)) (Join-Lines @(
  '  /** 折叠起来的工作区(cwd) */',
  '  @State collapsedKeys: string[] = [];',
  '',
  '  /** 宽屏(窗口 >= 600vp)时用双栏: 左边列表, 右边详情, 不再跳路由 */',
  '  @State wideLayout: boolean = false;',
  '  /** 双栏模式下右栏当前显示的会话 */',
  '  @State selectedId: string = '';',
  '  @State selectedTitle: string = '';',
  '  @State selectedCwd: string = '';',
  '  /** 断点订阅 id */',
  '  private bpListenerId: number = 0;',
  '',
  '  private listener: BridgeListener = new BridgeListener();'
)) 'state'

# --- 3. aboutToAppear ---------------------------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  '  async aboutToAppear(): Promise<void> {',
  "    this.endpointLabel = AppState.client.getEndpointLabel();"
)) (Join-Lines @(
  '  async aboutToAppear(): Promise<void> {',
  '    // 先把断点定下来: 宽屏双栏, 窄屏保持原来的单栏 + 路由跳转。',
  '    // init() 是异步的, 这里不 await —— 页面要先出来, 断点到了再切布局。',
  '    const bp = BreakpointObserver.getInstance();',
  '    bp.initSync();',
  '    this.wideLayout = bp.isWide();',
  '    this.bpListenerId = bp.subscribe((_widthVp: number, _heightVp: number, isWide: boolean): void => {',
  '      this.wideLayout = isWide;',
  '      if (!isWide) {',
  '        // 变回窄屏就清掉右栏的选中, 回到"点列表跳路由"的老行为',
  "        this.selectedId = '';",
  "        this.selectedTitle = '';",
  "        this.selectedCwd = '';",
  '      }',
  '    });',
  '    const host = this.getUIContext().getHostContext();',
  '    if (host !== undefined) {',
  '      bp.init(host as Context).then((): void => {',
  '        this.wideLayout = bp.isWide();',
  '      }).catch((err: Error): void => {',
  "        hilog.warn(DOMAIN, TAG, '断点初始化失败: %{public}s', err.message ?? '');",
  '      });',
  '    }',
  '',
  "    this.endpointLabel = AppState.client.getEndpointLabel();"
)) 'aboutToAppear'

# --- 4. aboutToDisappear ------------------------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  '  aboutToDisappear(): void {',
  '    AppState.client.removeListener(this.listener);',
  '  }'
)) (Join-Lines @(
  '  aboutToDisappear(): void {',
  '    AppState.client.removeListener(this.listener);',
  '    if (this.bpListenerId > 0) {',
  '      BreakpointObserver.getInstance().unsubscribe(this.bpListenerId);',
  '      this.bpListenerId = 0;',
  '    }',
  '  }'
)) 'aboutToDisappear'

# --- 5. sessionRowKey ---------------------------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  '  private stateLabel(state: string): string {',
  "    if (state === 'running') {",
  "      return '执行中';",
  '    }',
  "    if (state === 'error') {",
  "      return '异常';",
  '    }',
  "    return '空闲';",
  '  }'
)) (Join-Lines @(
  '  private stateLabel(state: string): string {',
  "    if (state === 'running') {",
  "      return '执行中';",
  '    }',
  "    if (state === 'error') {",
  "      return '异常';",
  '    }',
  "    return '空闲';",
  '  }',
  '',
  '  /**',
  '   * ForEach 的 key。',
  '   *',
  '   * 坑: ForEach 按 key 复用子组件, key 相同就不会重新走子组件里的 if 分支。',
  '   * 所以状态(转圈/异常)和选中态都必须拼进 key, 否则它们变了界面也不动。',
  '   */',
  '  private sessionRowKey(item: SessionSummary): string {',
  "    const mark: string = this.selectedId === item.id ? 'sel' : '';",
  '    return `${item.id}_${item.state}_${mark}`;',
  '  }'
)) 'sessionRowKey'

# --- 6. openSession -----------------------------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  '  private openSession(session: SessionSummary): void {',
  "    hilog.info(DOMAIN, TAG, 'openSession %{public}s', session.id);",
  '    const params: SessionRouteParams = {'
)) (Join-Lines @(
  '  private openSession(session: SessionSummary): void {',
  "    hilog.info(DOMAIN, TAG, 'openSession %{public}s', session.id);",
  '    if (this.wideLayout) {',
  '      // 双栏: 不跳路由, 右栏直接显示这个会话',
  '      this.selectedId = session.id;',
  '      this.selectedTitle = session.title;',
  '      this.selectedCwd = session.cwd;',
  '      return;',
  '    }',
  '    const params: SessionRouteParams = {'
)) 'openSession'

# --- 7. ForEach key + selection highlight ------------------------------------
$text = Replace-Exact $text (Join-Lines @(
  '                      .padding({ left: 40, right: Space.LG, top: Space.SM, bottom: Space.SM })',
  '                      .onClick(() => { this.openSession(item); })',
  '                    }, (item: SessionSummary): string => item.id)'
)) (Join-Lines @(
  '                      .padding({ left: 40, right: Space.LG, top: Space.SM, bottom: Space.SM })',
  '                      .backgroundColor(this.selectedId === item.id ? Palette.SURFACE : Color.Transparent)',
  '                      .onClick(() => { this.openSession(item); })',
  '                    }, (item: SessionSummary): string => this.sessionRowKey(item))'
)) 'ForEach key'

# --- 8. floating "新会话" button only on narrow screens ------------------------
$text = Replace-Exact $text (Join-Lines @(
  '      // ---------- 右下角新会话按钮 ----------',
  '      Column() {',
  "        Button('新会话')",
  '          .type(ButtonType.Normal)',
  '          .height(40)',
  '          .borderRadius(20)',
  '          .padding({ left: 20, right: 20 })',
  '          .backgroundColor(Palette.ACCENT_SOLID)',
  "          .fontColor('#FFFFFF')",
  '          .fontSize(FontSize.SMALL)',
  '          .onClick(() => { this.openNewSession(); })',
  '      }',
  "      .width('100%')",
  "      .height('100%')",
  '      .justifyContent(FlexAlign.End)',
  '      .alignItems(HorizontalAlign.End)',
  '      .padding({ right: Space.LG, bottom: Space.XL })',
  '      .hitTestBehavior(HitTestMode.Transparent)'
)) (Join-Lines @(
  '      // ---------- 右下角新会话按钮(双栏时列表栏底部已经有了, 这里不再浮一层) ----------',
  '      if (!this.wideLayout) {',
  '        Column() {',
  "          Button('新会话')",
  '            .type(ButtonType.Normal)',
  '            .height(40)',
  '            .borderRadius(20)',
  '            .padding({ left: 20, right: 20 })',
  '            .backgroundColor(Palette.ACCENT_SOLID)',
  "            .fontColor('#FFFFFF')",
  '            .fontSize(FontSize.SMALL)',
  '            .onClick(() => { this.openNewSession(); })',
  '        }',
  "        .width('100%')",
  "        .height('100%')",
  '        .justifyContent(FlexAlign.End)',
  '        .alignItems(HorizontalAlign.End)',
  '        .padding({ right: Space.LG, bottom: Space.XL })',
  '        .hitTestBehavior(HitTestMode.Transparent)',
  '      }'
)) 'floating new-session button'

# --- 9. move the list into a @Builder ----------------------------------------
$startMarker = Join-Lines @('        // ---------- 列表 ----------', '        if (this.loading) {')
$startIdx = $text.IndexOf($startMarker)
if ($startIdx -lt 0) { throw 'list block start not found' }
$chainStart = $startIdx + $startMarker.Length - '        if (this.loading) {'.Length

$endMarker = Join-Lines @('          .scrollBar(BarState.Off)', '        }')
$endIdx = $text.IndexOf($endMarker, $chainStart)
if ($endIdx -lt 0) { throw 'list block end not found' }
$chainEnd = $endIdx + $endMarker.Length
$chain = $text.Substring($chainStart, $chainEnd - $chainStart)
[Console]::WriteLine(("  list block: {0} chars" -f $chain.Length))

$indentedLines = New-Object System.Collections.Generic.List[string]
foreach ($line in ($chain -split "\r?\n")) {
  if ($line.Trim().Length -gt 0) { $indentedLines.Add('  ' + $line) } else { $indentedLines.Add($line) }
}
$indented = [string]::Join($script:NL, $indentedLines)

$dispatch = Join-Lines @(
  '        // ---------- 主体: 宽屏双栏, 窄屏还是原来那一套 ----------',
  '        if (this.wideLayout) {',
  '          this.twoColumnBody()',
  '        } else {',
  '          this.sessionListBody()',
  '        }'
)
$text = $text.Substring(0, $startIdx) + $dispatch + $text.Substring($chainEnd)
[Console]::WriteLine('  list block replaced by dispatch')

# --- 10. insert the builders --------------------------------------------------
$builderLines = New-Object System.Collections.Generic.List[string]
foreach ($line in (Join-Lines @(
  '  /**',
  '   * 会话列表(窄屏时铺满整屏, 宽屏时占左栏)。',
  '   */',
  '  @Builder',
  '  sessionListBody() {'
) -split "\r?\n")) { $builderLines.Add($line) }
foreach ($line in ($indented -split "\r?\n")) { $builderLines.Add($line) }
foreach ($line in (Join-Lines @(
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
) -split "\r?\n")) { $builderLines.Add($line) }
$builder = [string]::Join($script:NL, $builderLines)

$buildIdx = $text.IndexOf('  build() {')
if ($buildIdx -lt 0) { throw 'build() not found' }
$text = $text.Substring(0, $buildIdx) + $builder + $text.Substring($buildIdx)
[Console]::WriteLine('  builders inserted')

# --- verify -------------------------------------------------------------------
foreach ($needle in @(
    '  @Builder',
    '  sessionListBody() {',
    '  twoColumnBody() {',
    '  sessionDetailPane() {',
    '  build() {',
    'this.sessionListBody()',
    'this.twoColumnBody()',
    'this.sessionDetailPane()',
    'SessionDetailView({'
  )) {
  $count = 0
  $pos = 0
  while (($pos = $text.IndexOf($needle, $pos)) -ge 0) { $count++; $pos++ }
  if ($count -eq 0) { throw "VERIFY FAILED, missing: $needle" }
  [Console]::WriteLine(("  verify ok: {0} x{1}" -f $needle.Trim(), $count))
}
$open = ([regex]::Matches($text, '\{')).Count
$close = ([regex]::Matches($text, '\}')).Count
[Console]::WriteLine(("  braces: {0} open / {1} close" -f $open, $close))
if ($open -ne $close) { throw 'VERIFY FAILED: brace count mismatch' }

$enc = New-Object System.Text.UTF8Encoding($hasBom)
[System.IO.File]::WriteAllText($file, $text, $enc)
Write-Output ("wrote {0} ({1} bytes)" -f $file, (Get-Item $file).Length)

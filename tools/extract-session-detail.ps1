# Extract SessionPage.ets into a reusable SessionDetailView component.
# The copy keeps every line identical except for the handful of spots listed below,
# so the narrow-screen behaviour cannot drift.
$ErrorActionPreference = 'Stop'

$src = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\src\main\ets\pages\SessionPage.ets'
$dst = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\src\main\ets\pages\SessionDetailView.ets'

$bytes = [System.IO.File]::ReadAllBytes($src)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
Write-Output ("source BOM={0} newline={1}" -f $hasBom, $(if ($nl -eq "`r`n") { 'CRLF' } else { 'LF' }))

# Join literal lines into a block. (Here-strings are avoided on purpose: a
# terminator followed by more text on the same line is ambiguous.)
function L { param([string[]]$Lines) return ($Lines -join "`n") }

function Replace-Exact {
  param([string]$Content, [string]$Old, [string]$New, [string]$Label)
  $i = $Content.IndexOf($Old)
  if ($i -lt 0) { throw "PATTERN NOT FOUND: $Label" }
  # [Console]::WriteLine, not Write-Output: Write-Output would add the message to
  # the return value and turn $text into an array.
  [Console]::WriteLine(("  patched: {0}" -f $Label))
  return $Content.Substring(0, $i) + $New + $Content.Substring($i + $Old.Length)
}

# ---- 1. header comment ------------------------------------------------------
$text = Replace-Exact $text (L @(
  '/**',
  ' * 会话详情页 —— 交互模型对齐桌面端 DeepSeek Harness。'
)) (L @(
  '/**',
  ' * 会话详情**组件** —— 交互模型对齐桌面端 DeepSeek Harness。',
  ' *',
  ' * 单栏模式: 由 pages/SessionPage.ets 以 @Entry 页面承载, 路由参数从外面传进来。',
  ' * 双栏模式: 由 pages/SessionListPage.ets 直接嵌在右栏, 左边点列表换这里的 sessionId。',
  ' * 两种模式共用这一份实现, 行为完全一致。'
)) 'header comment'

# ---- 2. @Entry -> exported component ---------------------------------------
$text = Replace-Exact $text (L @(
  '@Entry',
  '@Component',
  'struct SessionPage {'
)) (L @(
  '@Component',
  'export struct SessionDetailView {'
)) 'struct declaration'

# ---- 3. session identity becomes props -------------------------------------
$text = Replace-Exact $text "  @State sessionId: string = '';" (L @(
  '  /** 当前会话(双栏模式下由列表页切换) */',
  "  @Prop @Watch('onSessionChanged') sessionId: string = '';"
)) 'sessionId prop'
$text = Replace-Exact $text "  @State title: string = '';" "  @Prop @Watch('onSessionChanged') title: string = '';" 'title prop'
$text = Replace-Exact $text "  @State cwd: string = '';" "  @Prop @Watch('onSessionChanged') cwd: string = '';" 'cwd prop'

# ---- 4. show-back prop + bound session bookkeeping --------------------------
$text = Replace-Exact $text '  @State stats: SessionStats | null = null;' (L @(
  '  @State stats: SessionStats | null = null;',
  '  /** 双栏模式下不显示返回箭头 */',
  '  @Prop showBack: boolean = true;',
  '  /** 当前实际订阅的会话 id(换会话时用来退订旧的) */',
  '  @State private boundSessionId: string = '''';'
)) 'showBack + boundSessionId'

# ---- 5. static helper rename -----------------------------------------------
$text = $text.Replace('SessionPage.clip(', 'SessionDetailView.clip(')
Write-Output '  patched: static helper rename'

# ---- 6. aboutToAppear: params come from the parent now ---------------------
$text = Replace-Exact $text (L @(
  '  aboutToAppear(): void {',
  '    const params = this.getUIContext().getRouter().getParams() as SessionRouteParams;',
  '    if (params !== undefined && params !== null) {',
  '      this.sessionId = params.sessionId;',
  '      this.title = params.title;',
  '      this.cwd = params.cwd;',
  '    }'
)) (L @(
  '  aboutToAppear(): void {'
)) 'aboutToAppear params'

# ---- 7. split attach / re-attach -------------------------------------------
$text = Replace-Exact $text (L @(
  '    AppState.client.addListener(this.listener);',
  '    // 必须先订阅, bridge 才会把这个会话的增量推给手机',
  '    AppState.client.subscribeSession(this.sessionId);',
  '    this.loadHistory();',
  '    this.loadStats();',
  '    this.loadQueue();',
  '    void this.loadModelName();',
  '    AppState.client.connect();',
  '  }',
  '',
  '  aboutToDisappear(): void {',
  '    AppState.client.removeListener(this.listener);',
  '    AppState.client.unsubscribeSession(this.sessionId);',
  '  }'
)) (L @(
  '    AppState.client.addListener(this.listener);',
  '    this.attachSession();',
  '  }',
  '',
  '  /**',
  '   * 订阅当前会话并把界面拉起来。',
  '   * 双栏模式下换了会话时也走这里。',
  '   */',
  '  private attachSession(): void {',
  '    if (this.sessionId.length === 0) {',
  '      return;',
  '    }',
  '    this.boundSessionId = this.sessionId;',
  '    // 必须先订阅, bridge 才会把这个会话的增量推给手机',
  '    AppState.client.subscribeSession(this.sessionId);',
  '    this.loadHistory();',
  '    this.loadStats();',
  '    this.loadQueue();',
  '    void this.loadModelName();',
  '    AppState.client.connect();',
  '  }',
  '',
  '  /**',
  '   * 外部换了会话(双栏模式下点左边的列表)时重新挂载。',
  '   */',
  '  onSessionChanged(): void {',
  '    if (this.sessionId.length === 0) {',
  '      return;',
  '    }',
  '    if (this.boundSessionId.length > 0 && this.boundSessionId !== this.sessionId) {',
  '      AppState.client.unsubscribeSession(this.boundSessionId);',
  '      this.messages = [];',
  "      this.notice = '';",
  '    }',
  '    this.attachSession();',
  '  }',
  '',
  '  aboutToDisappear(): void {',
  '    AppState.client.removeListener(this.listener);',
  '    if (this.boundSessionId.length > 0) {',
  '      AppState.client.unsubscribeSession(this.boundSessionId);',
  "      this.boundSessionId = '';",
  '    }',
  '  }'
)) 'attachSession split'

# ---- 8. back arrow becomes optional ----------------------------------------
$pattern = "(?m)^([ ]*)Text\('[^']*'\)\r?\n[ ]*\.fontSize\(24\)\r?\n[ ]*\.fontColor\(Palette\.TEXT_2\)\r?\n[ ]*\.width\(28\)\r?\n[ ]*\.onClick\(\(\) => \{ this\.getUIContext\(\)\.getRouter\(\)\.back\(\); \}\)"
$m = [regex]::Match($text, $pattern)
if (-not $m.Success) { throw 'PATTERN NOT FOUND: back arrow' }
$indent = $m.Groups[1].Value
$lines = $m.Value -split "`r?`n"
$indented = ($lines | ForEach-Object { if ($_.Trim().Length -gt 0) { '  ' + $_ } else { $_ } }) -join $nl
$new = "$indent`if (this.showBack) {${nl}$indented${nl}$indent}"
$text = $text.Substring(0, $m.Index) + $new + $text.Substring($m.Index + $m.Length)
Write-Output '  patched: back arrow'

# ---- write ------------------------------------------------------------------
$enc = New-Object System.Text.UTF8Encoding($hasBom)
[System.IO.File]::WriteAllText($dst, $text, $enc)
Write-Output ("wrote {0} ({1} bytes)" -f $dst, (Get-Item $dst).Length)

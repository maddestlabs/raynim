import raylib
import unicode
import strutils

# Types
type
  KeyRepeatState = object
    key: KeyboardKey
    pressTime: float64
    lastRepeatTime: float64
    repeating: bool
type
  GapBuffer = object
    data: seq[Rune]
    gapStart: int
    gapEnd: int

  LineInfo = object
    startPos: int
    length: int

  TextBuffer = object
    content: GapBuffer
    lines: seq[LineInfo]

  Cursor = object
    line: int
    column: int
    desiredColumn: int

  Selection = object
    anchor: Cursor
    head: Cursor
    active: bool

  FontMetrics = object
    glyphWidth: float32
    lineHeight: float32
    baseline: float32

  Viewport = object
    scrollX: float32
    scrollY: float32
    visibleLines: int
    firstVisibleLine: int

  Editor = object
    buffer: TextBuffer
    cursor: Cursor
    selection: Selection
    viewport: Viewport
    font: Font
    fontBold: Font
    fontItalic: Font
    metrics: FontMetrics
    fontSize: float32
    modified: bool
    keyRepeat: KeyRepeatState
    titleBarHeight: float32
    contentOffsetY: float32

# Gap Buffer Operations
proc newGapBuffer(initialSize: int = 256): GapBuffer =
  result.data = newSeq[Rune](initialSize)
  result.gapStart = 0
  result.gapEnd = initialSize

proc moveGapTo(gb: var GapBuffer, pos: int) =
  if pos < gb.gapStart:
    let distance = gb.gapStart - pos
    for i in countdown(gb.gapStart - 1, pos):
      gb.data[i + (gb.gapEnd - gb.gapStart)] = gb.data[i]
    gb.gapEnd -= distance
    gb.gapStart = pos
  elif pos > gb.gapStart:
    let distance = pos - gb.gapStart
    for i in gb.gapEnd..<(gb.gapEnd + distance):
      gb.data[gb.gapStart + (i - gb.gapEnd)] = gb.data[i]
    gb.gapStart += distance
    gb.gapEnd += distance

proc insertRune(gb: var GapBuffer, pos: int, r: Rune) =
  if gb.gapEnd - gb.gapStart == 0:
    # Expand buffer
    let newSize = gb.data.len * 2
    var newData = newSeq[Rune](newSize)
    for i in 0..<gb.gapStart:
      newData[i] = gb.data[i]
    let oldGapSize = gb.gapEnd - gb.gapStart
    gb.gapEnd = newSize - (gb.data.len - gb.gapEnd)
    for i in gb.gapEnd..<newSize:
      newData[i] = gb.data[i - (gb.gapEnd - gb.data.len + gb.data.len - oldGapSize)]
    gb.data = newData
  
  moveGapTo(gb, pos)
  gb.data[gb.gapStart] = r
  gb.gapStart += 1

proc deleteRune(gb: var GapBuffer, pos: int) =
  if pos >= gb.gapStart:
    moveGapTo(gb, pos)
    if gb.gapEnd < gb.data.len:
      gb.gapEnd += 1
  else:
    moveGapTo(gb, pos + 1)
    if gb.gapStart > 0:
      gb.gapStart -= 1

proc toString(gb: GapBuffer): string =
  result = ""
  for i in 0..<gb.gapStart:
    result.add(gb.data[i])
  for i in gb.gapEnd..<gb.data.len:
    result.add(gb.data[i])

proc length(gb: GapBuffer): int =
  gb.data.len - (gb.gapEnd - gb.gapStart)

# Text Buffer Operations
proc updateLines(tb: var TextBuffer) =
  tb.lines = @[]
  let text = tb.content.toString()
  var lineStart = 0
  var pos = 0
  
  for i, ch in text:
    if ch == '\n':
      tb.lines.add(LineInfo(startPos: lineStart, length: pos - lineStart))
      lineStart = pos + 1
    pos += 1
  
  # Add final line
  tb.lines.add(LineInfo(startPos: lineStart, length: pos - lineStart))

proc newTextBuffer(content: string): TextBuffer =
  result.content = newGapBuffer(max(content.len + 256, 256))
  var pos = 0
  for rune in content.runes:
    insertRune(result.content, pos, rune)
    pos += 1
  result.lines = @[LineInfo(startPos: 0, length: 0)]
  result.updateLines()

proc getLine(tb: TextBuffer, lineNum: int): string =
  if lineNum < 0 or lineNum >= tb.lines.len:
    return ""
  let text = tb.content.toString()
  let lineInfo = tb.lines[lineNum]
  if lineInfo.startPos + lineInfo.length > text.len:
    return ""
  result = text[lineInfo.startPos..<(lineInfo.startPos + lineInfo.length)]

proc getCursorPosition(tb: TextBuffer, cursor: Cursor): int =
  if cursor.line < 0 or cursor.line >= tb.lines.len:
    return 0
  result = tb.lines[cursor.line].startPos + min(cursor.column, tb.lines[cursor.line].length)

# Editor Operations
proc insertChar(editor: var Editor, r: Rune) =
  let pos = editor.buffer.getCursorPosition(editor.cursor)
  insertRune(editor.buffer.content, pos, r)
  editor.buffer.updateLines()
  editor.cursor.column += 1
  editor.cursor.desiredColumn = editor.cursor.column
  editor.modified = true

proc deleteChar(editor: var Editor) =
  if editor.cursor.column > 0:
    let pos = editor.buffer.getCursorPosition(editor.cursor)
    deleteRune(editor.buffer.content, pos - 1)
    editor.buffer.updateLines()
    editor.cursor.column -= 1
    editor.cursor.desiredColumn = editor.cursor.column
    editor.modified = true
  elif editor.cursor.line > 0:
    # Delete newline, join with previous line
    editor.cursor.line -= 1
    editor.cursor.column = editor.buffer.lines[editor.cursor.line].length
    let pos = editor.buffer.getCursorPosition(editor.cursor)
    deleteRune(editor.buffer.content, pos)
    editor.buffer.updateLines()
    editor.cursor.desiredColumn = editor.cursor.column
    editor.modified = true

proc insertNewline(editor: var Editor) =
  let pos = editor.buffer.getCursorPosition(editor.cursor)
  insertRune(editor.buffer.content, pos, Rune('\n'))
  editor.buffer.updateLines()
  editor.cursor.line += 1
  editor.cursor.column = 0
  editor.cursor.desiredColumn = 0
  editor.modified = true

proc moveCursorLeft(editor: var Editor) =
  if editor.cursor.column > 0:
    editor.cursor.column -= 1
  elif editor.cursor.line > 0:
    editor.cursor.line -= 1
    editor.cursor.column = editor.buffer.lines[editor.cursor.line].length
  editor.cursor.desiredColumn = editor.cursor.column

proc moveCursorRight(editor: var Editor) =
  let lineLen = editor.buffer.lines[editor.cursor.line].length
  if editor.cursor.column < lineLen:
    editor.cursor.column += 1
  elif editor.cursor.line < editor.buffer.lines.len - 1:
    editor.cursor.line += 1
    editor.cursor.column = 0
  editor.cursor.desiredColumn = editor.cursor.column

proc moveCursorUp(editor: var Editor) =
  if editor.cursor.line > 0:
    editor.cursor.line -= 1
    editor.cursor.column = min(editor.cursor.desiredColumn, 
                               editor.buffer.lines[editor.cursor.line].length)

proc moveCursorDown(editor: var Editor) =
  if editor.cursor.line < editor.buffer.lines.len - 1:
    editor.cursor.line += 1
    editor.cursor.column = min(editor.cursor.desiredColumn, 
                               editor.buffer.lines[editor.cursor.line].length)

proc moveCursorToMouse(editor: var Editor, mouseX, mouseY: float32) =
  # Adjust for scroll and padding
  let contentX = mouseX + editor.viewport.scrollX - 10.0f
  let contentY = mouseY + editor.viewport.scrollY - editor.contentOffsetY
  
  # Calculate line
  let clickedLine = (contentY / editor.metrics.lineHeight).int
  if clickedLine >= 0 and clickedLine < editor.buffer.lines.len:
    editor.cursor.line = clickedLine
    
    # Calculate column
    let clickedColumn = (contentX / editor.metrics.glyphWidth).int
    let lineLen = editor.buffer.lines[editor.cursor.line].length
    editor.cursor.column = clamp(clickedColumn, 0, lineLen)
    editor.cursor.desiredColumn = editor.cursor.column

# Rendering
proc renderLine(line: string, x, y: float32, font: Font, fontSize: float32, 
                glyphWidth: float32, color: Color) =
  var currentX = x
  for rune in line.runes:
    drawTextCodepoint(font, rune, Vector2(x: currentX, y: y), fontSize, color)
    currentX += glyphWidth

proc render(editor: var Editor) =
  beginDrawing()
  clearBackground(RayWhite)
  
  # Draw custom title bar
  drawRectangle(0, 0, getScreenWidth(), editor.titleBarHeight.int32, Color(r: 60, g: 60, b: 60, a: 255))
  drawText("Nim Text Editor", 10, ((editor.titleBarHeight - 20) / 2).int32, 20, RayWhite)
  
  # Calculate visible lines
  let windowHeight = getScreenHeight()
  let availableHeight = windowHeight.float32 - editor.titleBarHeight - 40  # -40 for status bar
  editor.viewport.visibleLines = (availableHeight / editor.metrics.lineHeight).int + 1
  
  # Render visible lines
  var y = editor.contentOffsetY - editor.viewport.scrollY
  for i in editor.viewport.firstVisibleLine..<
           min(editor.viewport.firstVisibleLine + editor.viewport.visibleLines,
               editor.buffer.lines.len):
    let line = editor.buffer.getLine(i)
    renderLine(line, 10.0f - editor.viewport.scrollX, y, editor.font, 
               editor.fontSize, editor.metrics.glyphWidth, Black)
    
    # Draw cursor on current line
    if i == editor.cursor.line:
      let cursorX = 10.0f + editor.cursor.column.float32 * editor.metrics.glyphWidth - 
                    editor.viewport.scrollX
      let cursorY = y
      drawRectangle(cursorX.int32, cursorY.int32, 2, editor.metrics.lineHeight.int32, Red)
    
    y += editor.metrics.lineHeight
  
  # Status bar
  let status = "Line " & $(editor.cursor.line + 1) & ", Col " & 
               $(editor.cursor.column + 1) & 
               (if editor.modified: " [Modified]" else: "")
  drawText(status, 10, getScreenHeight() - 30, 20, DarkGray)
  
  endDrawing()

# Input handling
proc handleKeyRepeat(editor: var Editor, key: KeyboardKey, action: proc(e: var Editor)) =
  const InitialDelay = 0.5  # 500ms initial delay
  const RepeatRate = 0.03   # 30ms repeat rate (33 repeats per second)
  
  let currentTime = raylib.getTime()
  
  if isKeyPressed(key):
    action(editor)
    editor.keyRepeat.key = key
    editor.keyRepeat.pressTime = currentTime
    editor.keyRepeat.lastRepeatTime = currentTime
    editor.keyRepeat.repeating = false
  elif isKeyDown(key):
    if editor.keyRepeat.key == key:
      let elapsed = currentTime - editor.keyRepeat.pressTime
      if not editor.keyRepeat.repeating and elapsed >= InitialDelay:
        editor.keyRepeat.repeating = true
        editor.keyRepeat.lastRepeatTime = currentTime
      
      if editor.keyRepeat.repeating:
        let timeSinceLastRepeat = currentTime - editor.keyRepeat.lastRepeatTime
        if timeSinceLastRepeat >= RepeatRate:
          action(editor)
          editor.keyRepeat.lastRepeatTime = currentTime
  elif isKeyReleased(key):
    if editor.keyRepeat.key == key:
      editor.keyRepeat.key = Null
      editor.keyRepeat.repeating = false

proc handleInput(editor: var Editor) =
  # Character input
  var key = getCharPressed()
  while key > 0:
    if key >= 32 and key < 127:  # Printable ASCII
      editor.insertChar(Rune(key))
    key = getCharPressed()
  
  # Special keys with repeat
  handleKeyRepeat(editor, Backspace, proc(e: var Editor) = e.deleteChar())
  handleKeyRepeat(editor, Left, proc(e: var Editor) = e.moveCursorLeft())
  handleKeyRepeat(editor, Right, proc(e: var Editor) = e.moveCursorRight())
  handleKeyRepeat(editor, Up, proc(e: var Editor) = e.moveCursorUp())
  handleKeyRepeat(editor, Down, proc(e: var Editor) = e.moveCursorDown())
  
  # Enter key (no repeat)
  if isKeyPressed(Enter):
    editor.insertNewline()
  
  # Mouse input
  if isMouseButtonPressed(Left):
    let mousePos = getMousePosition()
    editor.moveCursorToMouse(mousePos.x, mousePos.y)

# Main
proc main() =
  # Create borderless window that can still be resized
  setConfigFlags(flags(WindowUndecorated, WindowResizable, Msaa4xHint))
  initWindow(1280, 720, "Nim Text Editor")
  setTargetFPS(60)
  
  var editor = Editor(
    buffer: newTextBuffer("# Welcome to Nim Editor\n# Start typing...\n"),
    cursor: Cursor(line: 0, column: 0, desiredColumn: 0),
    fontSize: 16.0,
    modified: false,
    titleBarHeight: 40.0,
    contentOffsetY: 50.0  # titleBarHeight + 10px padding
  )
  
  # Load scientifica fonts
  editor.font = loadFont("fonts/AnomalyMono-Regular.otf")
  editor.fontBold = loadFont("fonts/AnomalyMono-Regular.otf")
  editor.fontItalic = loadFont("fonts/MonaspaceRadon-Italic.otf")
  
  # Enable font smoothing
  setTextureFilter(editor.font.texture, Bilinear)
  setTextureFilter(editor.fontBold.texture, Bilinear)
  setTextureFilter(editor.fontItalic.texture, Bilinear)
  
  # Calculate metrics
  let sampleSize = measureText(editor.font, "M", editor.fontSize, 0)
  editor.metrics = FontMetrics(
    glyphWidth: sampleSize.x,
    lineHeight: sampleSize.y * 1.3,
    baseline: sampleSize.y * 0.8
  )
  
  editor.viewport = Viewport(
    scrollX: 0,
    scrollY: 0,
    visibleLines: 0,
    firstVisibleLine: 0
  )
  
  editor.keyRepeat = KeyRepeatState(
    key: Null,
    pressTime: 0.0,
    lastRepeatTime: 0.0,
    repeating: false
  )
  
  while not windowShouldClose():
    editor.handleInput()
    editor.render()
  
  closeWindow()

when isMainModule:
  main()
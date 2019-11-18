import
  cligen
  , osproc
  , streams
  , strutils
  , sequtils
  , threadpool
  , longbow
  , sdl2
  , sdl2/gfx
  , sdl2/ttf

const
  BOARD = 512
  SQUARE = BOARD div 8
  FPS = 20.cint  # frames per second

type
  GFX = ref object of Rootobj
    window: WindowPtr
    renderer: RendererPtr
    evt: Event
    hand_cursor, wait_cursor: CursorPtr
    black, flip, player, pickup, running: bool
    depth, premove, postmove, lastpremove, lastpostmove: int
    texary: array[10, TexturePtr]
    moves: array[64, seq[int]]
    piece_char*: array[4, char]
    color*: array[64, int]
    piece*: array[64, int]

  Params = tuple
    black, flip: bool

  Info = tuple
    turn: string
    moves: seq[string]
    pre: seq[int]
    post: seq[int]
    move: string
    chose: string
    ready: bool
    action: bool
    over: bool
    overs: string

# globals
var channel: Channel[Info]

template staticReadRW(filename: string): ptr RWops =
  const file = staticRead(filename)  # embed fonts
  rwFromConstMem(file.cstring, file.len)

proc boardtex(renderer: RendererPtr): TexturePtr =
  result = renderer.createTexture(SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, BOARD, BOARD)
  renderer.setRenderTarget(result)
  var k = true
  for i in 0 .. 8:
    for j in 0 .. 8:
      if k:
        renderer.setDrawColor 128,128,128,255  # light
      else:
        renderer.setDrawColor 84,84,84,255  # dark
      k = not k
      var r = rect((i*SQUARE).cint, (j*SQUARE).cint, SQUARE, SQUARE)
      renderer.fillRect(addr r)
  renderer.setRenderTarget(nil)

proc piecetex(renderer: RendererPtr; font: FontPtr; t: string; c: Color): TexturePtr =
  var surf = font.renderTextBlended(t, c)
  result = renderer.createTextureFromSurface(surf)
  surf.destroy()

proc spotex(renderer: RendererPtr; col: Color ): TexturePtr =
  result = renderer.createTexture(SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, SQUARE, SQUARE)
  renderer.setRenderTarget(result)
  renderer.setDrawColor col
  var r = rect(0.cint, 0.cint, SQUARE, SQUARE)
  renderer.fillRect(addr r)
  renderer.setRenderTarget(nil)

method gettex(self: GFX; i: int): TexturePtr {.base.} =
  case self.color[i]:
    of WHITE:
      case self.piece[i]:
        of PAWN:
          result = self.texary[1]
        of KNIGHT:
          result = self.texary[2]
        of BISHOP:
          result = self.texary[3]
        else: discard
    of BLACK:
      case self.piece[i]:
        of PAWN:
          result = self.texary[4]
        of KNIGHT:
          result = self.texary[5]
        of BISHOP:
          result = self.texary[6]
        else: discard
    else: discard

method setup(self: GFX; params: Params) {.base.} =
  self.black = params.black
  self.flip = params.flip

  self.window = createWindow("Longbow", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, BOARD, BOARD, SDL_WINDOW_SHOWN)
  self.renderer = createRenderer(self.window, -1, Renderer_Accelerated or Renderer_PresentVsync or Renderer_TargetTexture)
  self.renderer.setDrawBlendMode(BlendMode_Blend)
  var
    font = openFontRW(staticReadRW("data/chess.otf"), freesrc = 1, BOARD.cint)
    black = color(0,0,0,255)
    white = color(255,255,255,255)
    red = color(255,0,0,128)
    green = color(0,255,0,128)
    blue = color(0,0,255,128)
    brd = boardtex(self.renderer)
    wp = self.renderer.piecetex(font,"p", white)
    wn = self.renderer.piecetex(font,"n", white)
    wb = self.renderer.piecetex(font,"b", white)
    bp = self.renderer.piecetex(font,"p", black)
    bn = self.renderer.piecetex(font,"n", black)
    bb = self.renderer.piecetex(font,"b", black)
    rs = self.renderer.spotex(red)
    gs = self.renderer.spotex(green)
    bs = self.renderer.spotex(blue)
  close(font)
  self.evt = defaultEvent
  self.hand_cursor = createSystemCursor(SDL_SYSTEM_CURSOR_HAND)
  self.wait_cursor = createSystemCursor(SDL_SYSTEM_CURSOR_WAIT)
  rs.setTextureBlendMode(BlendMode_Blend)
  gs.setTextureBlendMode(BlendMode_Blend)
  bs.setTextureBlendMode(BlendMode_Blend)
  self.texary[0] = brd
  self.texary[1] = wp
  self.texary[2] = wn
  self.texary[3] = wb
  self.texary[4] = bp
  self.texary[5] = bn
  self.texary[6] = bb
  self.texary[7] = rs
  self.texary[8] = gs
  self.texary[9] = bs
  self.running = true
  if not self.black:
    self.player = true
  self.piece_char = piece_char
  self.color = init_color
  self.piece = init_piece
  self.lastpremove = 64  # off-board
  self.lastpostmove = 64  # off-board

proc notEmpty(s: string): bool =
  len(s) > 0

proc listen(stream: Stream) {.thread.} =
  var
    turn: string
    moves: seq[string]
    chose: string
    ready: bool
    info: Info
    over: bool
    overs: string
  while true:
    try:
      var line = stream.readLine()
      # echo ">", line
      if line.contains("Turn"):
        turn = line
        ready = false
      if line.contains("chose"):
        chose = line
        ready = false
      if line.contains('['):
        moves = split(line.replace("[").replace("]"))
        moves.keepIf(notEmpty)
        ready = false
      if line.contains("quit"):
        ready = true
      if line.contains("WINNER") or line.contains("STALEMATE"):
        overs = line
        over = true
      if ready or over:
        info.turn = turn
        info.moves = moves
        info.chose = chose
        info.ready = ready
        info.over = over
        info.overs = overs
        channel.send(info)
        ready = false
        # info.moves = @[]
    except: discard

method events(self: GFX; info: var Info) {.base.} =
  var mr, mc, mouseX, mouseY: cint
  while pollEvent(self.evt):
    case self.evt.kind:
      of QuitEvent:
        self.running = false
        break
      of KeyDown:
        case self.evt.key.keysym.sym:
          of K_ESCAPE:
            self.running = false
            break
          else: discard
      of MouseButtonDown:
        if not self.player:
          break
        case self.evt.button.button:
          of BUTTON_LEFT:
            getMouseState(mouseX, mouseY)
            mc = mouseX div SQUARE
            mr = mouseY div SQUARE
            if not self.pickup:
              self.premove = 63-(8*mr+mc)
              if (self.premove in info.pre) and ((self.color[self.premove] == BLACK and self.black) or (self.color[self.premove] == WHITE and not self.black)):
                self.pickup = true
            else:
              self.postmove = 63-(8*mr+mc)
              for i, p in info.post:
                if (p == self.postmove) and (self.premove == info.pre[i]):  #  player makes a move
                  self.pickup = false
                  info.action = true
                  break
          of BUTTON_RIGHT:
            if self.pickup:
              self.pickup = false
          else: discard
      else: discard

method render(self: GFX; info: Info) {.base.} =
  var mouseX, mouseY: cint
  var x, y: int
  var R: Rect
  # board
  self.renderer.copy(self.texary[0], nil, nil)
  # spots
  if self.pickup:
    for i, j in info.post:
      if info.pre[i] != self.premove: continue
      x = SQUARE*COL(j)
      y = SQUARE*(7-ROW(j))
      R = rect(x.cint, y.cint, SQUARE.cint, SQUARE.cint)
      if self.piece[j] == 0:  # NONE
        self.renderer.copy(self.texary[8], nil, addr R)
      else:
        self.renderer.copy(self.texary[7], nil, addr R)
  if not self.pickup:
    x = SQUARE*COL(self.lastpremove)
    y = SQUARE*(7-ROW(self.lastpremove))
    R = rect(x.cint, y.cint, SQUARE.cint, SQUARE.cint)
    self.renderer.copy(self.texary[9], nil, addr R)
    x = SQUARE*COL(self.lastpostmove)
    y = SQUARE*(7-ROW(self.lastpostmove))
    R = rect(x.cint, y.cint, SQUARE.cint, SQUARE.cint)
    self.renderer.copy(self.texary[9], nil, addr R)
  # pieces
  for i in countdown(63, 0):
    if self.pickup and (i == self.premove):
      continue
    x = SQUARE*COL(i)
    y = SQUARE*(7-ROW(i))
    R = rect(x.cint, y.cint, SQUARE.cint, SQUARE.cint)
    var tex = self.gettex(i)
    if not isNil(tex):
      self.renderer.copy(tex, nil, addr R)
  # selected piece
  if self.pickup:
    getMouseState(mouseX, mouseY)
    R = rect((mouseX - SQUARE div 2).cint, (mouseY - SQUARE div 2).cint, SQUARE.cint, SQUARE.cint)
    self.renderer.copy(self.gettex(self.premove), nil, addr R)

  self.renderer.present

method loop(self: GFX; process: Process) {.base.} =
  var fpsman: FpsManager
  var info: Info
  fpsman.init
  fpsman.setFramerate(FPS)
  while self.running:
    var title: cstring
    if not info.over:
      if self.player:
        setCursor(self.hand_cursor)
        if self.black:
          title = "Longbow: Black to move"
        else:
          title = "Longbow: White to move"
      else:
        setCursor(self.wait_cursor)
        title = "Longbow: Thinking ..."
      self.window.setTitle(title)

      var (received, pinfo) = tryRecv(channel)
      if received and (pinfo.ready or pinfo.over):
        # echo "<", pinfo
        info.pre = @[]
        info.post = @[]
        info.turn = pinfo.turn
        info.moves = pinfo.moves
        info.chose = pinfo.chose
        info.ready = pinfo.ready
        info.over = pinfo.over
        info.overs = pinfo.overs
        for m in info.moves:
          var pq = transform(m)
          info.pre.add(pq.p)
          info.post.add(pq.q)
        pinfo.ready = false

      if info.action:
        info.move = coord(self.premove) & coord(self.postmove)
        self.color[self.postmove] = self.color[self.premove]
        self.color[self.premove] = NONE
        self.piece[self.postmove] = self.piece[self.premove]
        self.piece[self.premove] = EMPTY
        self.lastpremove = self.premove
        self.lastpostmove = self.postmove

        process.inputStream.writeLine(info.move)
        process.inputStream.flush()
        self.player = not self.player
        info.action = false

      if not self.player and info.ready and len(info.chose) > 0:
        var
          chose = info.chose[13..16]
          pq = transform(chose)
        self.premove = pq.p
        self.postmove = pq.q
        self.color[self.postmove] = self.color[self.premove]
        self.color[self.premove] = NONE
        self.piece[self.postmove] = self.piece[self.premove]
        self.piece[self.premove] = EMPTY
        self.player = not self.player
        self.lastpremove = self.premove
        self.lastpostmove = self.postmove
        info.chose = ""

    else:
      setCursor(self.wait_cursor)
      title = "Longbow: " & info.overs
      self.window.setTitle(title)

    self.events(info)
    self.render(info)
    fpsman.delay

proc main(depth=5, black=false, flip=false) =
  let
    gfx = GFX()
    params = (black: black, flip: flip)
  var args: seq[string]
  args.add("-d:" & $depth)
  if black:
    args.add("-b")
  if flip:
    args.add("-f")
  let process = startProcess("longbow", args=args, options={poDaemon})

  open(channel)
  spawn listen(process.outputStream)
  gfx.setup(params)
  gfx.loop(process)
  close(channel)
  close(process)

when isMainModule:
  discard sdl2.init(INIT_VIDEO)
  discard setHint("SDL_RENDER_SCALE_QUALITY", "2")
  discard ttfInit()
  dispatch(main)
  ttfQuit()
  sdl2.quit()

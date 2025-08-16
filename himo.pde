import hypermedia.net.*;

// ====== UDP入力用変数 ======
UDP udp;
boolean up=false, down=false, left=false, right=false, button=false;
boolean prevUp=false, prevDown=false, prevLeft=false, prevRight=false, prevButton=false;

// ====== ゲーム変数 ======
final int W = 760, H = 560;
final int MARGIN = 56;
final int BAR_Y = 120;
final int BASE_Y = H - 120;
final int SLOT_W = 96;

static final int STATE_HOME  = 0;
static final int STATE_PLAY  = 1;
static final int STATE_CLEAR = 2;
int state = STATE_HOME;

static final int MODE_SELECT = 0;
static final int MODE_EDIT   = 1;
int mode = MODE_SELECT;

int focusRow = 1;   
int focusCol = 0;   
int editTarget = -1;

final int N = 4;
color[] COLORS = {#8B5CF6, #22C55E, #F59E0B, #06B6D4};
float[] baseX = new float[N];
int[]   baseOrder = new int[N];
int[]   basePos   = new int[N];
float[] dispBaseX = new float[N];
float[] animFromX = new float[N];
float[] animToX   = new float[N];
float[] animT     = new float[N];
final float ANIM_SPEED = 0.18;

int queuedEdgeTarget = -1;
int queuedRope = -1;

int currentStage = 1;
int homeSel = 1;

int stageStartMillis = 0;
int clearTimeMillis = 0;

PFont uiFont;

// ====== Processing初期化 ======
void settings(){ size(W, H); smooth(4); }

void setup(){
  frameRate(60);
  uiFont = createFont("SansSerif", 16, true);
  textFont(uiFont);
  textAlign(CENTER, CENTER);
  for(int i=0;i<N;i++) baseX[i] = map(i, 0, N-1, MARGIN+60, W-MARGIN-60);

  // UDP開始
  udp = new UDP(this, 5005);
  udp.listen(true);
}

void receive(byte[] data, String ip, int port) {
  String msg = new String(data);
  String[] parts = split(msg, ',');
  if (parts.length == 3) {
    int axisX = int(parts[0]);
    int axisY = int(parts[1]);
    int swVal = int(parts[2]);

    left = (axisX < 30000);
    right = (axisX > 35000);
    up = (axisY < 30000);
    down = (axisY > 35000);
    button = (swVal == 1);
  }
}

void draw(){
  background(10);

  // 入力エッジ検出
  if (up && !prevUp) onUp();
  if (down && !prevDown) onDown();
  if (left && !prevLeft) onLeft();
  if (right && !prevRight) onRight();
  if (button && !prevButton) onA();

  prevUp = up;
  prevDown = down;
  prevLeft = left;
  prevRight = right;
  prevButton = button;

  drawGrid();
  updateAnimations();
  autoStepQueue();

  if(state == STATE_HOME){
    drawHome();
  } else if(state == STATE_PLAY){
    drawScene();
    drawTopButtons();
    drawPlayHUD();
    drawTimer();
    if(isSolved()){
      clearTimeMillis = millis() - stageStartMillis;
      state = STATE_CLEAR;
    }
  } else if(state == STATE_CLEAR){
    drawScene();
    drawTopButtons();
    drawClearBanner();
    drawTimer();
  }
}

void onUp(){
  if(state==STATE_HOME){
    int cols=5, rows=4; int idx = homeSel-1; int r=idx/cols, c=idx%cols;
    r = max(0, r-1);
    homeSel = r*cols + c + 1;
  } else if(state==STATE_PLAY && mode==MODE_SELECT){
    if(focusRow==1){ focusRow=0; if(focusCol>1) focusCol=1; }
  }
  // EDITモードでは上下無効
}

void onDown(){
  if(state==STATE_HOME){
    int cols=5, rows=4; int idx = homeSel-1; int r=idx/cols, c=idx%cols;
    r = min(rows-1, r+1);
    homeSel = r*cols + c + 1;
  } else if(state==STATE_PLAY && mode==MODE_SELECT){
    if(focusRow==0){ focusRow=1; if(focusCol>3) focusCol=3; }
  }
  // EDITモードでは上下無効
}

void onA(){
  if(state==STATE_HOME){
    startStage(homeSel);
  } else if(state==STATE_CLEAR){
    int next = (currentStage%20)+1; startStage(next);
  } else if(state==STATE_PLAY && mode==MODE_SELECT){
    onSelectA();
  } else if(state==STATE_PLAY && mode==MODE_EDIT){
    // EDITモード中にA押下でキャンセル
    mode = MODE_SELECT;
    editTarget = -1;
    queuedEdgeTarget = -1;
    queuedRope = -1;
  }
}

void onLeft(){
  if(state==STATE_HOME){
    int cols=5, rows=4; int idx = homeSel-1; int r=idx/cols, c=idx%cols;
    c = max(0, c-1);
    homeSel = r*cols + c + 1;
  } else if(state==STATE_PLAY && mode==MODE_SELECT){
    focusCol = max(0, focusCol-1);
  } else if(state==STATE_PLAY && mode==MODE_EDIT){
    if(!anyAnimating()){
      int b = basePos[editTarget];
      if(b>0) swapBasesAnimated(b, b-1);
    }
  }
}

void onRight(){
  if(state==STATE_HOME){
    int cols=5, rows=4; int idx = homeSel-1; int r=idx/cols, c=idx%cols;
    c = min(cols-1, c+1);
    homeSel = r*cols + c + 1;
  } else if(state==STATE_PLAY && mode==MODE_SELECT){
    focusCol = min((focusRow==0?1:3), focusCol+1);
  } else if(state==STATE_PLAY && mode==MODE_EDIT){
    if(!anyAnimating()){
      int b = basePos[editTarget];
      if(b<N-1) swapBasesAnimated(b, b+1);
    }
  }
}


// ====== ゲームロジック（あなたの元コードそのまま） ======
void startStage(int n){
  currentStage = constrain(n,1,20);
  for(int i=0;i<N;i++){ baseOrder[i]=i; basePos[i]=i; dispBaseX[i]=baseX[i]; animT[i]=1; }

  int turns = 3 + n;
  float hopChance = map(n, 1, 20, 0.25, 0.6);

  randomSeed(7000 + n*7919);
  for(int t=0;t<turns;t++){
    if(random(1)<0.5){ swapBasesImm(0,1); swapBasesImm(2,3); }
    else { swapBasesImm(2,3); swapBasesImm(0,1); }
    swapBasesImm(1,2);
    if(random(1)<hopChance){
      int a=(int)random(N);
      int b=constrain(a+ (random(1)<0.5?-1:+1)*2,0,N-1);
      swapBasesImm(a,b);
    }
  }
  if(isSolved()) swapBasesImm(0,1);

  state = STATE_PLAY; mode = MODE_SELECT;
  focusRow = 1; focusCol = 0; editTarget=-1; queuedEdgeTarget=-1; queuedRope=-1;

  stageStartMillis = millis();
  clearTimeMillis = 0;
}

boolean isSolved(){ for(int i=0;i<N;i++) if(baseOrder[i]!=i) return false; return true; }

void onSelectA(){
  if(focusRow==0){
    if(focusCol==0) startStage(currentStage);
    else state = STATE_HOME;
  } else {
    int ropeId = baseOrder[focusCol];
    editTarget = ropeId; mode = MODE_EDIT;
    queuedEdgeTarget=-1; queuedRope=-1;
  }
}

void autoStepQueue(){
  if(mode!=MODE_EDIT) return;
  if(queuedEdgeTarget<0) return;
  if(anyAnimating()) return;
  if(queuedRope!=editTarget){ queuedEdgeTarget=-1; return; }
  int b = basePos[editTarget];
  if(b == queuedEdgeTarget){ queuedEdgeTarget=-1; return; }
  int dir = (queuedEdgeTarget < b)? -1 : +1;
  swapBasesAnimated(b, b+dir);
}

void swapBasesImm(int a, int b){
  if(a==b) return;
  int ra = baseOrder[a];
  int rb = baseOrder[b];
  baseOrder[a]=rb; baseOrder[b]=ra;
  basePos[rb]=a; basePos[ra]=b;
  dispBaseX[ra] = baseX[basePos[ra]];
  dispBaseX[rb] = baseX[basePos[rb]];
  animT[ra]=animT[rb]=1;
}

void swapBasesAnimated(int a, int b){
  if(a==b) return;
  int ra = baseOrder[a];
  int rb = baseOrder[b];
  animFromX[ra] = dispBaseX[ra]; animToX[ra] = baseX[b]; animT[ra] = 0;
  animFromX[rb] = dispBaseX[rb]; animToX[rb] = baseX[a]; animT[rb] = 0;
  baseOrder[a]=rb; baseOrder[b]=ra;
  basePos[rb]=a; basePos[ra]=b;
}

void updateAnimations(){
  for(int id=0; id<N; id++){
    if(animT[id] < 1){
      animT[id] = min(1, animT[id] + ANIM_SPEED);
      float t = easeOutCubic(animT[id]);
      dispBaseX[id] = lerp(animFromX[id], animToX[id], t);
    } else {
      dispBaseX[id] = baseX[basePos[id]];
    }
  }
}

boolean anyAnimating(){ for(int id=0; id<N; id++) if(animT[id] < 1) return true; return false; }
float easeOutCubic(float t){ t=constrain(t,0,1); t=1-pow(1-t,3); return t; }

// ====== 描画関数 ======
void drawHome(){
  fill(255); textSize(28); text("紐解きパズル — ステージ選択", W/2, 64);
  textSize(14); fill(210); text("↑↓←→：移動  A：開始", W/2, 92);

  int cols = 5, rows = 4;
  float gx0 = MARGIN, gy0 = 140;
  float gw = (W - MARGIN*2) / cols;
  float gh = (H - gy0 - 140) / rows;
  for(int r=0;r<rows;r++){
    for(int c=0;c<cols;c++){
      int n = r*cols + c + 1;
      float x = gx0 + c*gw + gw/2;
      float y = gy0 + r*gh + gh/2;
      boolean sel = (homeSel == n);
      pushStyle(); rectMode(CENTER);
      int block = (n-1)/5;
      color bg = (block==0)?color(35,70,60): (block==1)?color(60,60,90): (block==2)?color(90,60,60): color(70,70,20);
      stroke(sel? color(255,230,120): color(160)); strokeWeight(sel?3:1.5);
      fill(bg); rect(x,y, gw*0.8, gh*0.7, 12);
      fill(255); textSize(18); text(n, x, y);
      popStyle();
    }
  }
}

void drawScene(){
  pushStyle(); noStroke(); fill(220,60,80); rectMode(CENTER);
  rect(W/2, BAR_Y, W*0.72, 18, 9);
  fill(240,200,120); circle(W*0.15, BAR_Y, 18); popStyle();

  for(int id=0; id<N; id++){
    int bIndex = basePos[id];
    float bx = dispBaseX[id];
    float sx = slotX(id);

    strokeWeight(18); stroke(COLORS[id]); noFill();
    beginShape();
    int seg = 6;
    for(int i=0;i<=seg;i++){
      float t = i/(float)seg;
      float y = lerp(BASE_Y, BAR_Y, t);
      float x = lerp(bx, sx, t);
      float amp = (animT[id] < 1) ? 18 * (1 - easeOutCubic(animT[id])) : 0;
      float wig = amp * sin(TWO_PI*(t*3 + id*0.12));
      curveVertex(x + wig, y);
    }
    endShape();

    noStroke(); fill(255); circle(sx, BAR_Y, 28); fill(COLORS[id]); circle(sx, BAR_Y, 22);
    boolean focused = (mode==MODE_SELECT && focusRow==1 && focusCol==bIndex);
    boolean editing = (mode==MODE_EDIT && editTarget==id);
    drawBase(bx, BASE_Y, COLORS[id], focused, editing);
  }
}

void drawBase(float x, float y, int col, boolean focused, boolean editing){
  pushStyle(); rectMode(CENTER);
  noStroke(); fill(50); rect(x, y+20, 80, 28, 12); fill(200); ellipse(x, y+20, 86, 10);
  fill(col); ellipse(x, y, 58, 34);
  if(focused){ noFill(); stroke(255,230,120); strokeWeight(4); ellipse(x, y, 70, 44); }
  if(editing){ noFill(); stroke(255,60,60); strokeWeight(4); ellipse(x, y, 74, 48); }
  popStyle();
}

void drawTopButtons(){
  String[] labels = {"リトライ", "やめる"};
  for(int i=0;i<2;i++){
    float x = W*0.5 + (i==0? -90: +90);
    float y = 64;
    boolean focus = (mode==MODE_SELECT && focusRow==0 && focusCol==i);
    pushStyle(); rectMode(CENTER);
    stroke( focus? color(255,230,120): color(160) ); strokeWeight(focus?3:1.5);
    fill( focus? color(40,60,80): color(25) );
    rect(x,y, 120, 34, 8);
    fill(255); text(labels[i], x, y);
    popStyle();
  }
}

void drawPlayHUD(){
  fill(220); textSize(14);
  text("ステージ "+currentStage+"  |  選択：矢印  A：決定", W/2, H-30);
}

void drawClearBanner(){
  pushStyle(); fill(60,180,120,220); noStroke(); rectMode(CENTER);
  rect(W/2, 64, 340, 56, 10);
  fill(0); textSize(20); text("クリア！  A：次へ", W/2, 48);
  textSize(16); text("タイム: " + nf(clearTimeMillis/1000.0, 0, 2) + " 秒", W/2, 78);
  popStyle();
}

void drawTimer(){
  pushStyle();
  fill(255);
  textSize(16);
  textAlign(RIGHT, TOP);
  int elapsed = (state==STATE_CLEAR && clearTimeMillis>0) ? clearTimeMillis : millis() - stageStartMillis;
  float sec = elapsed / 1000.0;
  text(nf(sec, 0, 2) + " 秒", W - 20, 20);
  popStyle();
}

void drawGrid(){ stroke(30); strokeWeight(1); for(int x=0;x<W;x+=40) line(x,0,x,H); for(int y=0;y<H;y+=40) line(0,y,W,y); }
float slotX(int index){ float left = (W - SLOT_W*(N-1))/2.0; return left + SLOT_W*index; }

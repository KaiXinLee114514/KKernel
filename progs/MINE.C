/* ============================================================================
 *  MINE.C — 扫雷(Minesweeper),KKernel 里的 C 程序
 *
 *  用法(shell 里):run MINE.BIN
 *
 *  编译:`make` 会做(MINE.C 是大写后缀,Makefile 里有一条 -x c 的规则,
 *  不然 gcc 会当 C++ 编)。链接地址 0x120000,和别的 progs/*.C 一样。
 *
 *  ── 玩法 ───────────────────────────────────────────────────────────────
 *  启动先选难度(1-4):
 *      1) 5x5    2) 6x6    3) 8x8    4) 12x12
 *  雷数不固定:每局随机取 总格子的 5%~12%(最少 1 颗),重开/换难度都重新随机。
 *  方向键移动光标,回车/空格翻开,`f` 插旗/取消旗,`r` 重开当前难度,
 *  `1`-`4` 随时换难度,**Ctrl-C**(或 ESC)回 shell。
 *  作弊码:依次输入 Q U I C K P A S S(大小写都行)→ 所有雷位置显示成红色 `[@]`,
 *  状态行出现 [CHEAT ON]。退出用 Ctrl-C/ESC,所以 `q` 只有作弊码用途。
 *
 *  ── 显示 ───────────────────────────────────────────────────────────────
 *  只用 ASCII(字库/字形不折腾),每格三个字符宽:
 *      [#] 未翻开      [%] 旗子       [*] 光标(永远显示这个)
 *      [ ] 翻开的空格  [1]-[8] 周围雷数   [@] 雷(踩中/揭晓时)
 *
 *  ── 几个实现上的选择 ───────────────────────────────────────────────────
 *  · 第一下必安全:雷在**第一次真的翻开**之后才布,而且排除那一格和周围 8 格。
 *  · 0 格展开用 BFS(一个小队列,棋盘最大 12x12 = 144 格,静态数组足够)。
 *  · 重画只画"内容变了的格子":shown[][] 里存着屏幕上的样子,
 *    光标挪一格只重画两格 —— VBE 逐像素慢,全盘重画在 QEMU 里会卡。
 *  · 随机数:先读 /DEV/RANDOM 拿 4 字节,再和 TSC 混一下做种子,
 *    设备读失败也不影响(只用 TSC 也够随机)。
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <kkernel.h>

#define MAXN        12
#define MAXCELLS    (MAXN * MAXN)

/* 四种难度:边长(雷数每局随机,见 start_game) */
static const int level_n[4] = { 5, 6, 8, 12 };

/* 作弊码:QUICKPASS */
static const char cheat_seq[] = "QUICKPASS";
static int cheat_idx;                   /* 已匹配到第几个字母 */
static int cheat_on;                    /* 1 = 雷位置显示红色 */

/* ---- 局面 ---- */
static int  board_n;                    /* 当前边长 */
static int  mine_total;                 /* 当前雷数 */
static unsigned char mine[MAXN][MAXN];  /* 1 = 有雷(第一次翻开后才填) */
static unsigned char opened[MAXN][MAXN];
static unsigned char flagged[MAXN][MAXN];
static unsigned char around[MAXN][MAXN];/* 周围雷数 0-8 */
static int  cursor_x, cursor_y;
static int  first_click;                /* 1 = 还没布雷 */
static int  flags_used;
static int  opened_count;
static int  state;                      /* 0 = 玩,1 = 输,2 = 赢 */
static int  level;                      /* 0-3 */

/* ---- 屏幕布局 ---- */
static int  scr_cols, scr_rows;
static int  title_row, status_row, board_row, msg_row, hint_row;
static int  board_col;

/* 屏幕上每格现在画的是什么(用来只重画变了的格子) */
static char shown[MAXN][MAXN][4];

/* 状态行下面那行提示文字(输赢/旗子满了之类) */
static char message[64];

/* ---------------------------------------------------------------------------
 *  小工具:居左/居中画一行(超过屏幕右边界就截断)
 * -------------------------------------------------------------------------*/
static void put_at(const char *s, int row, int col)
{
    if (row < 0 || row >= scr_rows)
        return;
    if (col < 0)
        col = 0;
    /* ★ j_puts_at 第 4 个参数是"画到哪一列为止"的**绝对列号**(不是格数):
     *   term_puts_at 拿 col 跟它比,超过就停。传 scr_cols = 一直画到屏幕右缘。 */
    j_puts_at(s, row, col, scr_cols);
}

static void put_center(const char *s, int row)
{
    int len = (int)strlen(s);
    int col = (scr_cols - len) / 2;

    if (col < 0)
        col = 0;
    put_at(s, row, col);
}

/* 把 s 补空格到 width 格再画:用来擦掉上一行更长的旧文字 */
static void put_padded(const char *s, int row, int col, int width)
{
    char buf[128];
    int i, len = (int)strlen(s);

    if (width > (int)sizeof(buf) - 1)
        width = (int)sizeof(buf) - 1;
    for (i = 0; i < width; i++)
        buf[i] = (i < len) ? s[i] : ' ';
    buf[width] = 0;
    put_at(buf, row, col);
}

/* ---------------------------------------------------------------------------
 *  随机数种子:读 /DEV/RANDOM,拿不到就用 TSC(minic 的 rand 本身也会用 TSC)
 * -------------------------------------------------------------------------*/
static void seed_random(void)
{
    unsigned char rb[4];
    unsigned int seed = j_rdtsc_lo();
    int n = j_readfile("DEV/RANDOM", rb, 4);

    if (n == 4)
        seed ^= ((unsigned int)rb[0])
              | ((unsigned int)rb[1] << 8)
              | ((unsigned int)rb[2] << 16)
              | ((unsigned int)rb[3] << 24);
    srand(seed);
}

/* ---------------------------------------------------------------------------
 *  难度切换 / 重开:清空局面,光标回左上,等第一下翻开再布雷
 * -------------------------------------------------------------------------*/
static void draw_title(void);
static void draw_status(void);
static void draw_message(void);
static void draw_hint(void);
static void draw_board(void);

static void start_game(int lv)
{
    int y, x;

    level = lv;
    board_n = level_n[lv];

    /* 雷数随机:总格子的 5%~12%,最少 1 颗 */
    {
        int total = board_n * board_n;
        int pct = 5 + (int)(rand() % 8);        /* 5..12 */
        mine_total = total * pct / 100;
        if (mine_total < 1)
            mine_total = 1;
        if (mine_total > total - 1)
            mine_total = total - 1;
    }
    cheat_idx = 0;
    cheat_on = 0;

    for (y = 0; y < MAXN; y++) {
        for (x = 0; x < MAXN; x++) {
            mine[y][x] = 0;
            opened[y][x] = 0;
            flagged[y][x] = 0;
            around[y][x] = 0;
            shown[y][x][0] = 0;
        }
    }
    cursor_x = 0;
    cursor_y = 0;
    first_click = 1;
    flags_used = 0;
    opened_count = 0;
    state = 0;
    message[0] = 0;

    /* 布局:整块(标题/状态/棋盘/提示)在屏幕上大致居中,棋盘水平居中 */
    title_row = (scr_rows - (board_n + 4)) / 2;
    if (title_row < 1)
        title_row = 1;
    status_row = title_row + 1;
    board_row = title_row + 2;
    msg_row = board_row + board_n;
    if (msg_row >= scr_rows - 1)
        msg_row = scr_rows - 2;
    hint_row = scr_rows - 1;
    board_col = (scr_cols - board_n * 3) / 2;
    if (board_col < 1)
        board_col = 1;

    j_clrscr();
    draw_title();
    draw_status();
    draw_board();
    draw_message();
    draw_hint();
}

/* ---------------------------------------------------------------------------
 *  第一次翻开之后布雷:排除 (sx,sy) 和周围 8 格。
 *  (雷数最多为总格子的 12%,远小于"总格数 - 9",拒绝采样一定能停下来。)
 * -------------------------------------------------------------------------*/
static void place_mines(int sx, int sy)
{
    int placed = 0, x, y, dx, dy;

    while (placed < mine_total) {
        x = (int)(rand() % board_n);
        y = (int)(rand() % board_n);
        if (mine[y][x])
            continue;
        if (x >= sx - 1 && x <= sx + 1 && y >= sy - 1 && y <= sy + 1)
            continue;
        mine[y][x] = 1;
        placed++;
    }
    for (y = 0; y < board_n; y++) {
        for (x = 0; x < board_n; x++) {
            int c = 0;
            if (mine[y][x])
                continue;
            for (dy = -1; dy <= 1; dy++) {
                for (dx = -1; dx <= 1; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= board_n || ny >= board_n)
                        continue;
                    if (mine[ny][nx])
                        c++;
                }
            }
            around[y][x] = (unsigned char)c;
        }
    }
}

/* ---------------------------------------------------------------------------
 *  翻开一格;是 0 就用 BFS 把连片的空白和它们的边界一起翻开
 * -------------------------------------------------------------------------*/
static void open_cell(int sx, int sy)
{
    int qx[MAXCELLS], qy[MAXCELLS];
    int head = 0, tail = 0;
    int x, y;

    if (opened[sy][sx] || flagged[sy][sx])
        return;

    opened[sy][sx] = 1;
    opened_count++;
    qx[tail] = sx;
    qy[tail] = sy;
    tail++;

    while (head < tail) {
        x = qx[head];
        y = qy[head];
        head++;
        if (around[y][x] != 0)
            continue;                   /* 数字格只翻开,不往外扩 */
        {
            int dx, dy;
            for (dy = -1; dy <= 1; dy++) {
                for (dx = -1; dx <= 1; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= board_n || ny >= board_n)
                        continue;
                    if (opened[ny][nx] || flagged[ny][nx])
                        continue;
                    opened[ny][nx] = 1;
                    opened_count++;
                    qx[tail] = nx;
                    qy[tail] = ny;
                    tail++;
                }
            }
        }
    }
}

/* ---------------------------------------------------------------------------
 *  一格该显示什么 + 用什么颜色
 *  ★ 光标所在格永远显示 [*](哪怕它是雷 / 已经翻开)。
 * -------------------------------------------------------------------------*/
static void cell_text(int x, int y, char *s, int *color)
{
    if (x == cursor_x && y == cursor_y) {
        strcpy(s, "[*]");
        *color = KK_YELLOW;
        return;
    }
    if (cheat_on && mine[y][x]) {           /* 作弊:雷位置标红 */
        strcpy(s, "[@]");
        *color = KK_LRED;
        return;
    }
    if (!opened[y][x]) {
        if (flagged[y][x]) {
            strcpy(s, "[%]");
            *color = KK_LRED;
        } else if (state == 1 && mine[y][x]) {
            strcpy(s, "[@]");           /* 输了:把雷都亮出来 */
            *color = KK_LRED;
        } else {
            strcpy(s, "[#]");
            *color = KK_GREY;
        }
        return;
    }
    if (around[y][x] == 0) {
        /* 已翻开的空格:方括号用浅灰(KK_DGREY 在 VBE 上太暗,
         * 一整片翻开的区域会看着像"没画") —— 里面留白,和 [#] 一眼能分开 */
        strcpy(s, "[ ]");
        *color = KK_GREY;
    } else {
        s[0] = '[';
        s[1] = (char)('0' + around[y][x]);
        s[2] = ']';
        s[3] = 0;
        *color = KK_WHITE;
    }
}

/* 只重画"内容和屏幕上不一样"的格子 —— VBE 逐像素慢,能少画一格是一格 */
static void draw_cell(int x, int y)
{
    char s[4];
    int color;

    cell_text(x, y, s, &color);
    if (!strcmp(s, shown[y][x]))
        return;
    j_color(color);
    j_puts_at(s, board_row + y, board_col + x * 3, board_col + x * 3 + 3);
    strcpy(shown[y][x], s);
}

static void draw_board(void)
{
    int x, y;

    for (y = 0; y < board_n; y++)
        for (x = 0; x < board_n; x++)
            draw_cell(x, y);
}

static void draw_title(void)
{
    char buf[64];

    sprintf(buf, "MINESWEEPER  LEVEL %d  %dx%d  %d MINES",
            level + 1, board_n, board_n, mine_total);
    j_color(KK_LCYAN);
    put_center(buf, title_row);
}

static void draw_status(void)
{
    char buf[64];

    sprintf(buf, "MINES LEFT %d   POS %d,%d%s",
            mine_total - flags_used, cursor_x + 1, cursor_y + 1,
            cheat_on ? "   [CHEAT ON]" : "");
    j_color(KK_LCYAN);
    put_padded(buf, status_row, board_col, 40);
}

static void draw_message(void)
{
    int color = KK_GREY;

    if (state == 1)
        color = KK_LRED;
    else if (state == 2)
        color = KK_LGREEN;
    j_color(color);
    put_padded(message, msg_row, board_col, 44);
}

static void draw_hint(void)
{
    j_color(KK_DGREY);
    put_center("ARROWS MOVE   ENTER/SPACE OPEN   F FLAG   R RESTART   1-4 LEVEL   CTRL-C QUIT",
               hint_row);
}

/* 一次按键之后的局部重画:棋盘(只画变的)+ 状态行 + 消息行 */
static void redraw(void)
{
    draw_board();
    draw_status();
    draw_message();
}

/* ---------------------------------------------------------------------------
 *  作弊码匹配:返回 1 = 这个字母被作弊码消费掉(调用方应重画后继续);
 *  返回 0 = 不是作弊码输入,交给游戏按键处理(目前只有 F / R)。
 * -------------------------------------------------------------------------*/
static int cheat_key(int k)
{
    char c;

    if (k >= 'a' && k <= 'z')
        c = (char)(k - 'a' + 'A');
    else if (k >= 'A' && k <= 'Z')
        c = (char)k;
    else
        return 0;

    if (c == cheat_seq[cheat_idx]) {
        cheat_idx++;
        if (cheat_seq[cheat_idx] == 0) {
            cheat_idx = 0;
            cheat_on = 1;
            strcpy(message, "CHEAT ON - MINES MARKED RED");
        }
    } else {
        cheat_idx = (c == 'Q') ? 1 : 0;
    }

    if (c == 'F' || c == 'R')
        return 0;                   /* 仍然是游戏键 */
    return 1;
}

/* ---------------------------------------------------------------------------
 *  菜单
 * -------------------------------------------------------------------------*/
static void draw_menu(void)
{
    int i, row;
    static const char *items[4] = {
        "1) 5x5",
        "2) 6x6",
        "3) 8x8",
        "4) 12x12"
    };

    j_clrscr();
    j_color(KK_LCYAN);
    put_center("MINESWEEPER", 2);
    j_color(KK_GREY);
    put_center("pick a level:  (mines 5%-12% of cells, random)", 4);
    for (i = 0; i < 4; i++) {
        row = 6 + i;
        j_color(KK_LGREEN);
        put_center(items[i], row);
    }
    j_color(KK_DGREY);
    put_center("ctrl-c  quit", 11);
}

/* 菜单里选难度;返回 0-3,或 -1 = 退出 */
static int menu(void)
{
    int k;

    draw_menu();
    for (;;) {
        k = j_getkey();
        if (k == 3 || k == 27)          /* Ctrl-C(kbd 给的控制码 3)/ ESC */
            return -1;
        if (k >= '1' && k <= '4')
            return k - '1';
    }
}

/* ---------------------------------------------------------------------------
 *  玩的一局:Ctrl-C / ESC 才返回(回 shell);重启/换难度原地做
 * -------------------------------------------------------------------------*/
static void play(void)
{
    int k;

    for (;;) {
        k = j_getkey();

        if (k == 3 || k == 27)          /* Ctrl-C / ESC */
            return;

        /* 先过作弊码(Q U I C K P A S S);F/R 仍交给游戏 */
        if (cheat_key(k)) {
            redraw();
            continue;
        }

        if (k >= '1' && k <= '4') {
            start_game(k - '1');
            continue;
        }
        if (k == 'r' || k == 'R') {
            start_game(level);
            continue;
        }

        if (k == KK_KEY_UP && cursor_y > 0) {
            cursor_y--;
            if (state == 0) message[0] = 0;
        } else if (k == KK_KEY_DOWN && cursor_y < board_n - 1) {
            cursor_y++;
            if (state == 0) message[0] = 0;
        } else if (k == KK_KEY_LEFT && cursor_x > 0) {
            cursor_x--;
            if (state == 0) message[0] = 0;
        } else if (k == KK_KEY_RIGHT && cursor_x < board_n - 1) {
            cursor_x++;
            if (state == 0) message[0] = 0;
        } else if (k == 13 || k == 32) {
            if (state == 0 && !opened[cursor_y][cursor_x]
                && !flagged[cursor_y][cursor_x]) {
                if (first_click) {
                    place_mines(cursor_x, cursor_y);
                    first_click = 0;
                }
                if (mine[cursor_y][cursor_x]) {
                    state = 1;
                    strcpy(message, "*** BOOM - GAME OVER (R TO RESTART) ***");
                } else {
                    open_cell(cursor_x, cursor_y);
                    if (opened_count == board_n * board_n - mine_total) {
                        int x, y;
                        state = 2;
                        for (y = 0; y < board_n; y++)
                            for (x = 0; x < board_n; x++)
                                if (mine[y][x] && !flagged[y][x]) {
                                    flagged[y][x] = 1;
                                    flags_used++;
                                }
                        strcpy(message, "*** YOU WIN! (R TO PLAY AGAIN) ***");
                    }
                }
            }
        } else if (k == 'f' || k == 'F') {
            if (state == 0) {
                if (flagged[cursor_y][cursor_x]) {
                    flagged[cursor_y][cursor_x] = 0;
                    flags_used--;
                    message[0] = 0;
                } else if (flags_used >= mine_total) {
                    strcpy(message, "no flags left - remove one first");
                } else {
                    flagged[cursor_y][cursor_x] = 1;
                    flags_used++;
                    message[0] = 0;
                }
            }
        } else {
            continue;                   /* 不认识的键:屏幕都不用动 */
        }
        redraw();
    }
}

int main(void)
{
    int lv;

    scr_cols = j_screensize(&scr_rows);
    seed_random();

    for (;;) {
        lv = menu();
        if (lv < 0)
            break;
        start_game(lv);
        play();
        /* 从对局里退出来(Ctrl-C):直接回 shell,不再回菜单 */
        break;
    }

    j_clrscr();
    j_color(KK_GREY);
    j_setcursor(0, 0);
    return 0;
}

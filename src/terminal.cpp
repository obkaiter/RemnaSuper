#include "terminal.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <climits>
#include <csignal>
#include <cstdlib>
#include <cwchar>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <stdexcept>
#include <string_view>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

namespace {
constexpr size_t queue_limit = 256 * 1024;
constexpr size_t history_limit = 800;

void append_cell(std::wstring &line, const VTermScreenCell &cell) {
    if (cell.chars[0] == UINT32_MAX) return;
    if (!cell.chars[0]) line += L' ';
    for (const auto c : cell.chars) {
        if (!c) break;
        line += static_cast<wchar_t>(c);
    }
}

int color_index(VTermColor value, bool foreground) {
    if ((foreground && VTERM_COLOR_IS_DEFAULT_FG(&value)) ||
        (!foreground && VTERM_COLOR_IS_DEFAULT_BG(&value))) {
        return 8;
    }
    if (VTERM_COLOR_IS_INDEXED(&value) && value.indexed.idx < 16) {
        return value.indexed.idx % 8;
    }
    if (VTERM_COLOR_IS_INDEXED(&value)) {
        const int index = value.indexed.idx;
        if (index >= 232) return index >= 244 ? COLOR_WHITE : COLOR_BLACK;
        const int cube = index - 16;
        return ((cube / 36 >= 3) ? COLOR_RED : 0) |
               (((cube / 6) % 6 >= 3) ? COLOR_GREEN : 0) |
               (((cube % 6) >= 3) ? COLOR_BLUE : 0);
    }
    return (value.rgb.red >= 128 ? COLOR_RED : 0) |
           (value.rgb.green >= 128 ? COLOR_GREEN : 0) |
           (value.rgb.blue >= 128 ? COLOR_BLUE : 0);
}

VTermKey terminal_key(wint_t key) {
    if (key >= KEY_F(1) && key <= KEY_F(24)) {
        return static_cast<VTermKey>(VTERM_KEY_FUNCTION(key - KEY_F(0)));
    }
    switch (key) {
    case KEY_UP: return VTERM_KEY_UP;
    case KEY_DOWN: return VTERM_KEY_DOWN;
    case KEY_LEFT: return VTERM_KEY_LEFT;
    case KEY_RIGHT: return VTERM_KEY_RIGHT;
    case KEY_HOME: return VTERM_KEY_HOME;
    case KEY_END: return VTERM_KEY_END;
    case KEY_PPAGE: return VTERM_KEY_PAGEUP;
    case KEY_NPAGE: return VTERM_KEY_PAGEDOWN;
    case KEY_BACKSPACE: return VTERM_KEY_BACKSPACE;
    case KEY_DC: return VTERM_KEY_DEL;
    case KEY_IC: return VTERM_KEY_INS;
    case KEY_ENTER: return VTERM_KEY_ENTER;
    case KEY_BTAB: return VTERM_KEY_TAB;
    default: return VTERM_KEY_NONE;
    }
}
}

std::wstring wide(const std::string &value) {
    std::wstring output;
    std::mbstate_t state{};
    for (size_t offset = 0; offset < value.size();) {
        wchar_t c;
        const size_t count = std::mbrtowc(&c, value.data() + offset, value.size() - offset, &state);
        if (count == static_cast<size_t>(-1) || count == static_cast<size_t>(-2)) {
            output.push_back(L'\ufffd');
            state = {};
            ++offset;
        } else {
            output.push_back(c);
            offset += std::max(count, size_t{1});
        }
    }
    return output;
}

std::string utf8(const std::wstring &value) {
    std::string output;
    std::mbstate_t state{};
    char bytes[MB_LEN_MAX];
    for (const auto c : value) {
        const auto count = std::wcrtomb(bytes, c, &state);
        if (count == static_cast<size_t>(-1)) {
            state = {};
        } else {
            output.append(bytes, count);
        }
    }
    return output;
}

void draw_text(WINDOW *window, int y, int x, int width, const std::wstring &value) {
    if (y < 0 || y >= getmaxy(window) || x < 0 || x >= getmaxx(window) || width <= 0) return;
    int cells = 0;
    size_t count = 0;
    for (const auto c : value) {
        const int columns = wcwidth(c);
        if (columns < 0 || cells + columns > width) break;
        cells += columns;
        ++count;
    }
    if (count) mvwaddnwstr(window, y, x, value.c_str(), static_cast<int>(count));
}

Terminal::Terminal() {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) || tcgetattr(STDIN_FILENO, &original_) < 0) {
        throw std::runtime_error("Для запуска нужен интерактивный терминал.");
    }
    const char *term = getenv("TERM");
    if (!term || std::string_view(term) == "dumb" || !(screen_ = newterm(nullptr, stdout, stdin))) {
        throw std::runtime_error("Терминал не поддерживается. Проверьте TERM и terminfo.");
    }
    raw();
    noecho();
    nonl();
    keypad(stdscr, TRUE);
    nodelay(stdscr, TRUE);
    set_escdelay(25);
    curs_set(0);
    define_key("\033[200~", paste_start);
    define_key("\033[201~", paste_end);
    fputs("\033[?2004h", stdout);
    fflush(stdout);
    if (has_colors() && start_color() == OK) {
        use_default_colors();
        const short background = COLORS >= 256 ? 18 : COLOR_BLUE;
        const short selection = COLORS >= 256 ? 80 : COLOR_CYAN;
        const short foreground = COLORS >= 256 ? 255 : COLOR_WHITE;
        const short modal = COLORS >= 256 ? 252 : COLOR_WHITE;
        init_pair(1, foreground, background);
        init_pair(2, COLOR_BLACK, selection);
        init_pair(3, COLOR_BLACK, modal);
        init_pair(4, selection, background);
        for (short fg = 0; fg < 9; ++fg) {
            for (short bg = 0; bg < 9; ++bg) {
                const short pair = 8 + fg * 9 + bg;
                if (pair < COLOR_PAIRS) init_pair(pair, fg == 8 ? -1 : fg, bg == 8 ? -1 : bg);
            }
        }
    }
}

Terminal::~Terminal() {
    fputs("\033[?2004l", stdout);
    fflush(stdout);
    curs_set(1);
    endwin();
    delscreen(screen_);
    tcsetattr(STDIN_FILENO, TCSANOW, &original_);
}

bool Terminal::read(Key &key) {
    const int status = get_wch(&key.value);
    key.special = status == KEY_CODE_YES;
    return status != ERR;
}

void Terminal::present() {
    doupdate();
}

Pty::Pty() = default;

Pty::~Pty() {
    hangup();
    if (child_ > 0) {
        for (int attempt = 0; attempt < 30; ++attempt) {
            const pid_t result = waitpid(child_, nullptr, WNOHANG);
            if (result == child_ || (result < 0 && errno == ECHILD)) return;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        kill(-child_, SIGKILL);
        while (waitpid(child_, nullptr, 0) < 0 && errno == EINTR) {}
    }
}

void Pty::hangup() {
    if (master_ >= 0) {
        const pid_t foreground = tcgetpgrp(master_);
        if (foreground > 1 && foreground != getpgrp()) {
            kill(-foreground, SIGHUP);
            kill(-foreground, SIGCONT);
        }
        close_master();
    }
    if (child_ > 1) {
        kill(-child_, SIGHUP);
        kill(-child_, SIGCONT);
    }
}

void Pty::close_master() {
    if (master_ >= 0) close(master_);
    master_ = -1;
}

bool connect_protocol(int request, int events) {
    return dup2(request, 3) >= 0 && dup2(events, 4) >= 0;
}

void Pty::start(const termios &mode, int rows, int cols, char *const argv[], int request, int events) {
    if (active()) throw std::logic_error("Терминал уже открыт.");
    rows_ = rows;
    cols_ = cols;
    pending_.clear();
    history_.clear();
    history_offset_ = 0;
    unread_ = false;
    cursor_ = true;
    paste_ = false;
    vt_.reset(vterm_new(rows, cols));
    if (!vt_) throw std::runtime_error("Не удалось создать виртуальный терминал.");
    vterm_set_utf8(vt_.get(), 1);
    screen_ = vterm_obtain_screen(vt_.get());
    static const VTermScreenCallbacks callbacks = [] {
        VTermScreenCallbacks result{};
        result.settermprop = property;
        result.sb_pushline = record_line;
        return result;
    }();
    vterm_screen_set_callbacks(screen_, &callbacks, this);
    vterm_screen_enable_altscreen(screen_, 1);
    vterm_output_set_callback(vt_.get(), queue, this);
    vterm_screen_reset(screen_, 1);

    winsize size{static_cast<unsigned short>(rows), static_cast<unsigned short>(cols), 0, 0};
    child_ = forkpty(&master_, nullptr, &mode, &size);
    if (child_ < 0) throw std::runtime_error("Не удалось открыть PTY.");
    if (child_ == 0) {
        for (int signal : {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGWINCH, SIGTSTP, SIGTTIN, SIGTTOU}) {
            std::signal(signal, SIG_DFL);
        }
        if (request >= 0 && !connect_protocol(request, events)) _exit(126);
        setenv("TERM", "xterm", 1);
        execv(argv[0], argv);
        static constexpr char error[] = "exec: shell unavailable\n";
        write(STDERR_FILENO, error, sizeof(error) - 1);
        _exit(127);
    }
    fcntl(master_, F_SETFL, O_NONBLOCK);
    fcntl(master_, F_SETFD, FD_CLOEXEC);
}

void Pty::start_shell(const termios &mode, int rows, int cols) {
    const char *shell = getenv("SHELL");
    if (!shell || shell[0] != '/' || access(shell, X_OK) != 0) shell = "/bin/bash";
    if (geteuid() == 0) {
        const std::string_view name(shell);
        if ((name.substr(0, 5) != "/bin/" && name.substr(0, 9) != "/usr/bin/") ||
            name.substr(name.find_last_of('/') + 1).empty() ||
            name.find('/', name.substr(0, 5) == "/bin/" ? 5 : 9) != std::string_view::npos) {
            shell = "/bin/bash";
        }
    }
    char interactive[] = "-i";
    char *const argv[]{const_cast<char *>(shell), interactive, nullptr};
    start(mode, rows, cols, argv);
}

void Pty::queue(const char *bytes, size_t size, void *context) {
    auto &self = *static_cast<Pty *>(context);
    if (size <= queue_limit - self.pending_.size()) self.pending_.append(bytes, size);
}

int Pty::property(VTermProp prop, VTermValue *value, void *context) {
    auto &self = *static_cast<Pty *>(context);
    if (prop == VTERM_PROP_CURSORVISIBLE) self.cursor_ = value->boolean;
    return 1;
}

int Pty::record_line(int cols, const VTermScreenCell *cells, void *context) {
    auto &self = *static_cast<Pty *>(context);
    if (self.history_.size() == history_limit) self.history_.pop_front();
    try {
        std::wstring line;
        for (int col = 0; col < cols; ++col) append_cell(line, cells[col]);
        self.history_.push_back(std::move(line));
        if (self.history_offset_) self.history_offset_ = std::min(self.history_.size(), self.history_offset_ + 1);
    } catch (const std::bad_alloc &) {
        return 0;
    }
    return 1;
}

void Pty::scroll_history(int lines) {
    history_offset_ = std::clamp(static_cast<long>(history_offset_) + lines, 0L, static_cast<long>(history_.size()));
}

void Pty::flush() {
    if (master_ < 0 || pending_.empty()) return;
    const auto sent = write(master_, pending_.data(), pending_.size());
    if (sent > 0) pending_.erase(0, static_cast<size_t>(sent));
}

short Pty::poll_events() const {
    return pending_.empty() ? POLLIN : POLLIN | POLLOUT;
}

bool Pty::pump() {
    bool changed = false;
    if (master_ >= 0) {
        std::array<char, 8192> bytes;
        for (int i = 0; i < 8; ++i) {
            const auto count = read(master_, bytes.data(), bytes.size());
            if (count <= 0) {
                if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) close_master();
                break;
            }
            vterm_input_write(vt_.get(), bytes.data(), static_cast<size_t>(count));
            changed = unread_ = true;
        }
        vterm_screen_flush_damage(screen_);
        flush();
    }
    if (child_ > 0 && waitpid(child_, &status_, WNOHANG) == child_) {
        child_ = -1;
        close_master();
        changed = true;
    }
    return changed;
}

void Pty::resize(int rows, int cols) {
    if (master_ < 0 || (rows == rows_ && cols == cols_)) return;
    rows_ = rows;
    cols_ = cols;
    vterm_set_size(vt_.get(), rows, cols);
    winsize size{static_cast<unsigned short>(rows), static_cast<unsigned short>(cols), 0, 0};
    ioctl(master_, TIOCSWINSZ, &size);
}

void Pty::send(Key key) {
    if (master_ < 0) return;
    history_offset_ = 0;
    if (key.special && key.value == paste_start) {
        paste_ = true;
        vterm_keyboard_start_paste(vt_.get());
    } else if (key.special && key.value == paste_end) {
        paste_ = false;
        vterm_keyboard_end_paste(vt_.get());
    } else if (key.special) {
        const auto code = terminal_key(key.value);
        if (code != VTERM_KEY_NONE) {
            vterm_keyboard_key(vt_.get(), code, key.value == KEY_BTAB ? VTERM_MOD_SHIFT : VTERM_MOD_NONE);
        }
    } else if (key.value == '\r' || key.value == '\n') {
        vterm_keyboard_key(vt_.get(), VTERM_KEY_ENTER, VTERM_MOD_NONE);
    } else if (key.value < 32 || key.value == 127) {
        const char byte = static_cast<char>(key.value);
        queue(&byte, 1, this);
    } else {
        vterm_keyboard_unichar(vt_.get(), key.value, VTERM_MOD_NONE);
    }
    flush();
}

void Pty::draw() {
    wbkgdset(stdscr, ' ');
    werase(stdscr);
    if (history_offset_) {
        const auto current = snapshot();
        const size_t start = history_.size() - history_offset_;
        int row = 0;
        for (size_t i = start; row < rows_ && i < history_.size(); ++i) {
            draw_text(stdscr, row++, 0, cols_, history_[i]);
        }
        for (size_t i = 0; row < rows_ && i < current.size(); ++i) {
            draw_text(stdscr, row++, 0, cols_, wide(current[i]));
        }
        curs_set(0);
        wnoutrefresh(stdscr);
        return;
    }
    for (int row = 0; row < rows_; ++row) {
        for (int col = 0; col < cols_; ++col) {
            VTermScreenCell cell{};
            if (!vterm_screen_get_cell(screen_, {row, col}, &cell) || cell.chars[0] == UINT32_MAX) continue;
            wchar_t chars[CCHARW_MAX + 1]{};
            if (cell.chars[0] == 0) chars[0] = L' ';
            for (size_t i = 0; i < CCHARW_MAX && i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; ++i) {
                chars[i] = static_cast<wchar_t>(cell.chars[i]);
            }
            attr_t attr = A_NORMAL;
            if (cell.attrs.bold) attr |= A_BOLD;
            if (cell.attrs.underline) attr |= A_UNDERLINE;
            if (cell.attrs.reverse) attr |= A_REVERSE;
            short pair = 8 + color_index(cell.fg, true) * 9 + color_index(cell.bg, false);
            if (!has_colors() || pair >= COLOR_PAIRS) pair = 0;
            cchar_t output{};
            if (setcchar(&output, chars, attr, pair, nullptr) == OK) mvwadd_wch(stdscr, row, col, &output);
        }
    }
    VTermPos cursor{};
    vterm_state_get_cursorpos(vterm_obtain_state(vt_.get()), &cursor);
    curs_set(cursor_ ? 1 : 0);
    wmove(stdscr, cursor.row, cursor.col);
    wnoutrefresh(stdscr);
    unread_ = false;
}

std::vector<std::string> Pty::snapshot() const {
    std::vector<std::string> lines;
    for (int row = 0; screen_ && row < rows_; ++row) {
        std::wstring line;
        for (int col = 0; col < cols_; ++col) {
            VTermScreenCell cell{};
            if (vterm_screen_get_cell(screen_, {row, col}, &cell)) append_cell(line, cell);
        }
        while (!line.empty() && line.back() == L' ') line.pop_back();
        if (!line.empty()) lines.push_back(utf8(line));
    }
    return lines;
}

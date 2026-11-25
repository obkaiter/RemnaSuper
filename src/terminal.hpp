#pragma once

#include <curses.h>
#include <vterm.h>

#include <memory>
#include <deque>
#include <string>
#include <termios.h>
#include <vector>

struct Key {
    wint_t value;
    bool special;
};

constexpr int paste_start = KEY_MAX + 1;
constexpr int paste_end = KEY_MAX + 2;

enum class ThemeColor : short {
    panel = 1,
    selection,
    dialog,
    dialog_focus,
    chrome,
    dialog_title,
    frame
};

attr_t theme(ThemeColor role, attr_t fallback = A_NORMAL);
std::wstring wide(const std::string &value);
std::string utf8(const std::wstring &value);
void draw_text(WINDOW *window, int y, int x, int width, const std::wstring &value);

class Terminal {
public:
    Terminal();
    ~Terminal();
    Terminal(const Terminal &) = delete;
    Terminal &operator=(const Terminal &) = delete;
    const termios &original_mode() const { return original_; }
    bool read(Key &key);
    void present();
private:
    termios original_{};
    SCREEN *screen_ = nullptr;
    WINDOW *input_ = nullptr;
};

class Pty {
public:
    Pty();
    ~Pty();
    Pty(const Pty &) = delete;
    Pty &operator=(const Pty &) = delete;
    void start(const termios &mode, int rows, int cols, char *const argv[], int request = -1, int events = -1);
    void start_shell(const termios &mode, int rows, int cols);
    void resize(int rows, int cols);
    bool pump();
    void send(Key key);
    void hangup();
    void draw();
    bool active() const { return child_ > 0 || master_ >= 0; }
    bool unread() const { return unread_; }
    bool pasting() const { return paste_; }
    int fd() const { return master_; }
    short poll_events() const;
    int status() const { return status_; }
    std::vector<std::string> snapshot() const;
    void scroll_history(int lines);
private:
    static void queue(const char *bytes, size_t size, void *context);
    static int property(VTermProp prop, VTermValue *value, void *context);
    static int record_line(int cols, const VTermScreenCell *cells, void *context);
    void close_master();
    void flush();
    pid_t child_ = -1;
    int master_ = -1;
    int status_ = 0;
    int rows_ = 0;
    int cols_ = 0;
    bool unread_ = false;
    bool cursor_ = true;
    bool paste_ = false;
    std::string pending_;
    std::deque<std::wstring> history_;
    size_t history_offset_ = 0;
    std::unique_ptr<VTerm, decltype(&vterm_free)> vt_{nullptr, vterm_free};
    VTermScreen *screen_ = nullptr;
};

bool connect_protocol(int request, int events);

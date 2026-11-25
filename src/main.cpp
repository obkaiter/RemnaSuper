#include "jobs.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <clocale>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <fstream>
#include <form.h>
#include <langinfo.h>
#include <menu.h>
#include <optional>
#include <panel.h>
#include <stdexcept>
#include <strings.h>
#include <string_view>
#include <sys/wait.h>
#include <tuple>
#include <unistd.h>

namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
volatile std::sig_atomic_t stopping = 0;

void stop(int signal) { stopping = signal; }

using Window = std::unique_ptr<WINDOW, decltype(&delwin)>;
using Panel = std::unique_ptr<PANEL, decltype(&del_panel)>;
using Field = std::unique_ptr<FIELD, decltype(&free_field)>;
using Form = std::unique_ptr<FORM, decltype(&free_form)>;
using Item = std::unique_ptr<ITEM, decltype(&free_item)>;
using Menu = std::unique_ptr<MENU, decltype(&free_menu)>;

constexpr int inner_width = 74;

attr_t theme(short pair, attr_t fallback = A_NORMAL) {
    return has_colors() ? COLOR_PAIR(pair) : fallback;
}

bool enter(Key key) {
    return key.special ? key.value == KEY_ENTER : key.value == '\r' || key.value == '\n';
}

bool escape(Key key) { return !key.special && key.value == 27; }

std::vector<std::wstring> wrap(const std::string &text, int width) {
    std::vector<std::wstring> lines(1);
    int cells = 0;
    for (const wchar_t c : wide(text)) {
        const int size = wcwidth(c);
        if (c == L'\n' || (size > 0 && cells + size > width)) {
            lines.emplace_back();
            cells = 0;
        }
        if (size >= 0 && c != L'\n') {
            lines.back() += c;
            cells += size;
        }
    }
    return lines;
}

void paragraph(WINDOW *win, int top, int x, int width, int height, const std::string &text, int offset = 0) {
    const auto lines = wrap(text, width);
    for (int row = 0; row < height && row + offset < static_cast<int>(lines.size()); ++row) {
        draw_text(win, top + row, x, width, lines[row + offset]);
    }
}

struct Dialog {
    std::string title;
    std::string description;
    bool choose = false;
    bool accept = false;
    bool editable = false;
    bool secret = false;
    std::wstring value;
    size_t cursor = 0;
    int offset = 0;
    Json choices;
    size_t selected = 0;
    bool edit_lines = false;
    bool reveal = false;
    std::string hidden;
};

struct Action {
    std::string id, title, summary, section, risk, execution;
    bool cancel;
    Json fields, resources;
};

std::vector<Action> load_actions(const std::filesystem::path &root) {
    std::ifstream file(root / "lib/backend/actions.json");
    const Json registry = Json::parse(file);
    if (registry.at("v") != 1) throw std::runtime_error("Неизвестная версия каталога действий.");
    std::vector<Action> actions;
    for (const Json &item : registry.at("actions")) {
        actions.push_back({item.at("id"), item.at("title"), item.at("summary"), item.at("section"),
                           item.at("risk"), item.value("execution", "task"), item.value("cancel", false),
                           item.value("fields", Json::array()), item.value("resources", Json::array())});
    }
    return actions;
}

std::string hostname() {
    char buffer[256]{};
    if (gethostname(buffer, sizeof(buffer) - 1) < 0) return "неизвестно";
    return buffer;
}

std::wstring lower(std::wstring value) {
    for (auto &c : value) c = towlower(c);
    return value;
}

class App {
public:
    App(std::filesystem::path root, std::vector<Action> actions, bool demo)
        : root_(std::move(root)), actions_(std::move(actions)), demo_(demo), host_(hostname()) {
        for (const auto &action : actions_) {
            if (std::find(sections_.begin(), sections_.end(), action.section) == sections_.end()) {
                sections_.push_back(action.section);
            }
        }
        if (sections_.empty()) throw std::runtime_error("Каталог действий пуст.");
        rebuild();
    }

    void run() {
        bool dirty = true;
        auto frame = Clock::now();
        if (!demo_ && (!getenv("REMNASUPER_SKIP_UPDATE") || std::string_view(getenv("REMNASUPER_SKIP_UPDATE")) != "1")) {
            const auto *check = find_action("update.check");
            if (check) startup_ = make_job(*check, Json::object());
        }
        while (!done_) {
            if (stopping) {
                if (!shutting_down_) {
                    shutting_down_ = true;
                    for (const auto &entry : jobs_) {
                        if (!entry.job->prompt().is_null()) entry.job->answer(false, "");
                        if (entry.job->can_cancel()) entry.job->cancel();
                    }
                }
                if (!active_jobs()) break;
            }
            if (shell_.pump()) {
                dirty = true;
                if (shell_visible_ && !shell_.active()) {
                    shell_visible_ = false;
                    notice_ = WIFEXITED(shell_.status()) && WEXITSTATUS(shell_.status()) == 127
                        ? "Не удалось запустить оболочку." : "Сеанс оболочки завершён.";
                }
            }
            for (const auto &entry : jobs_) {
                if (entry.job->pump()) dirty = true;
            }
            if (startup_ && startup_->pump() && !startup_->running()) {
                const auto &data = startup_->data();
                const std::string available = data.is_object() ? data.value("available", "") : "";
                if (!available.empty() && available.front() >= '0' && available.front() <= '9') {
                    notice_ = "Доступна версия " + available + ". Обновление находится в разделе «Система».";
                    if (!interacted_ && !active_jobs() && !shell_.active() && !dialog_ && !shutting_down_) {
                        if (const auto *apply = find_action("update.apply")) launch(*apply, Json::object());
                    }
                } else if (available.empty()) notice_ = "Проверить обновления не удалось.";
                startup_.reset();
                dirty = true;
            }
            for (const auto &entry : jobs_) {
                const auto &data = entry.job->data();
                if (!entry.job->running() && data.is_object() && data.value("installed", false)) installed_ = true;
            }
            if (installed_ && !shell_.active() && !active_jobs() && !dialog_ && !shutting_down_) {
                restart_ = true;
                return;
            }
            if (external_ && !external_->terminal()->active()) {
                external_ = nullptr;
                jobs_visible_ = true;
                dirty = true;
            }
            if (shutting_down_) {
                for (const auto &entry : jobs_) if (!entry.job->prompt().is_null()) entry.job->answer(false, "");
            } else if (!dialog_ && !shell_visible_) {
                const auto pending = std::find_if(jobs_.begin(), jobs_.end(), [](const Entry &entry) {
                    return !entry.job->prompt().is_null();
                });
                if (pending != jobs_.end()) {
                    prompt_job_ = pending->job.get();
                    const auto &info = prompt_job_->prompt();
                    const std::string kind = info.value("kind", "confirm");
                    Dialog dialog{pending->title, info.value("message", "Подтвердите действие"), true, false,
                        kind == "text" || kind == "secret" || kind == "editor", kind == "secret",
                        wide(info.value("default", ""))};
                    dialog.edit_lines = kind == "editor";
                    dialog.reveal = kind == "reveal";
                    dialog.hidden = info.value("sensitive", "");
                    dialog.choices = info.value("choices", Json::array());
                    for (size_t i = 0; i < dialog.choices.size(); ++i) {
                        if (dialog.choices[i].at("value") == info.value("default", "")) dialog.selected = i;
                    }
                    open(std::move(dialog), Purpose::reply);
                    dirty = true;
                }
            }
            const auto now = Clock::now();
            if (dirty && now >= frame && !shutting_down_) {
                draw();
                frame = now + 35ms;
                dirty = false;
            }
            if (literal_prefix_ && now >= *literal_prefix_) {
                if (auto *pty = visible_terminal()) pty->send({28, false});
                literal_prefix_.reset();
            }
            std::vector<pollfd> descriptors{{STDIN_FILENO, POLLIN, 0}};
            if (shell_.fd() >= 0) descriptors.push_back({shell_.fd(), shell_.poll_events(), 0});
            if (startup_) startup_->poll_descriptors(descriptors);
            for (const auto &entry : jobs_) entry.job->poll_descriptors(descriptors);
            const int polled = poll(descriptors.data(), descriptors.size(), dirty ? 20 : 100);
            if (polled < 0 && errno != EINTR) throw std::runtime_error("Ошибка опроса терминала.");
            if (descriptors.front().revents & (POLLHUP | POLLERR | POLLNVAL)) stopping = SIGHUP;
            Key key{};
            for (int i = 0; !shutting_down_ && i < 128 && terminal_.read(key); ++i) {
                if (!key.special || key.value != KEY_RESIZE) interacted_ = true;
                try { handle(key); }
                catch (const std::exception &failure) { notice_ = failure.what(); }
                dirty = true;
            }
        }
    }

    bool restart_requested() const { return restart_; }

private:
    enum class Purpose { help, filter, job_filter, field, confirm, reply, quit };
    struct Entry {
        std::string title;
        std::unique_ptr<Job> job;
        const Action *action;
        Json parameters;
    };

    size_t active_jobs() const {
        return std::count_if(jobs_.begin(), jobs_.end(), [](const auto &entry) { return entry.job->running(); });
    }

    const Action *find_action(std::string_view id) const {
        const auto entry = std::find_if(actions_.begin(), actions_.end(), [id](const auto &a) { return a.id == id; });
        return entry == actions_.end() ? nullptr : &*entry;
    }

    Pty *visible_terminal() {
        if (shell_visible_) return &shell_;
        if (dialog_) return nullptr;
        return external_ ? external_->terminal() : nullptr;
    }

    void rebuild() {
        visible_.clear();
        const auto needle = lower(filter_);
        for (const auto &action : actions_) {
            if (action.section != sections_[section_]) continue;
            if (needle.empty() || lower(wide(action.title + " " + action.id)).find(needle) != std::wstring::npos) {
                visible_.push_back(&action);
            }
        }
        selected_ = 0;
        top_ = 0;
    }

    void move_row(int offset, size_t count, size_t &selected) {
        if (count) selected = std::clamp(static_cast<long>(selected) + offset, 0L, static_cast<long>(count - 1));
    }

    void open(Dialog dialog, Purpose purpose) {
        dialog.cursor = dialog.value.size();
        dialog_ = std::make_unique<Dialog>(std::move(dialog));
        purpose_ = purpose;
    }

    void quit() {
        if (active_jobs()) {
            notice_ = "Дождитесь завершения задач или отмените задачи, для которых это доступно.";
        } else if (shell_.active()) {
            open({"Выход", "Закрыть оболочку и завершить RemnaSuper?", true}, Purpose::quit);
        } else done_ = true;
    }

    void choose_action() {
        if (visible_.empty()) return;
        action_ = visible_[selected_];
        if (action_->id == "update.apply" && (shell_.active() || active_jobs())) {
            notice_ = "Закройте оболочку и дождитесь завершения заданий перед обновлением.";
            return;
        }
        if (demo_ && action_->id != "demo.sample") {
            notice_ = "В DEMO системные действия отключены.";
            return;
        }
        if (jobs_.size() >= 24 && active_jobs() == jobs_.size()) {
            notice_ = "Дождитесь завершения одного из заданий.";
            return;
        }
        params_ = Json::object();
        field_ = 0;
        next_field();
    }

    void next_field() {
        if (field_ < action_->fields.size()) {
            const auto &field = action_->fields.at(field_);
            open({action_->title, field.at("label"), true, false, true, field.value("secret", false),
                  wide(field.value("default", ""))}, Purpose::field);
        } else if (action_->risk != "read_only") {
            std::string detail = action_->summary;
            for (const auto &field : action_->fields) {
                if (!field.value("secret", false)) {
                    const auto id = field.at("id").get<std::string>();
                    detail += "\n" + field.at("label").get<std::string>() + " — " + params_.at(id).get<std::string>();
                }
            }
            for (const auto &resource : action_->resources) detail += "\n" + resource.get<std::string>();
            open({action_->title, detail, true}, Purpose::confirm);
        } else run_action();
    }

    void run_action() {
        launch(*action_, params_);
        params_.clear();
    }

    std::unique_ptr<Job> make_job(const Action &action, const Json &params) {
        return std::make_unique<Job>(root_ / "lib/backend/dispatch.py", std::to_string(++sequence_), action.id, params,
            action.cancel, terminal_.original_mode(), LINES, COLS, action.execution == "terminal");
    }

    void launch(const Action &action, const Json &params) {
        while (jobs_.size() >= 24) {
            const auto old = std::find_if(jobs_.begin(), jobs_.end(), [](const auto &entry) { return !entry.job->running(); });
            if (old == jobs_.end()) throw std::runtime_error("Достигнут предел заданий.");
            jobs_.erase(old);
        }
        auto job = make_job(action, params);
        if (job->terminal()) external_ = job.get();
        jobs_.push_back({action.title, std::move(job), &action, params});
        job_row_ = jobs_.size() - 1;
        job_offset_ = 0;
        job_column_ = 0;
        report_table_ = 0;
        report_sort_ = -1;
        show_job_log_ = false;
        jobs_visible_ = true;
    }

    void close_dialog(bool accepted) {
        auto value = std::move(dialog_->value);
        if (accepted && !dialog_->choices.empty()) {
            value = wide(dialog_->choices[dialog_->selected].at("value").get<std::string>());
        }
        std::fill(dialog_->hidden.begin(), dialog_->hidden.end(), '\0');
        dialog_.reset();
        if (purpose_ == Purpose::reply && prompt_job_) {
            prompt_job_->answer(accepted, accepted ? utf8(value) : "");
            std::fill(value.begin(), value.end(), L'\0');
            prompt_job_ = nullptr;
        } else if (!accepted) {
            params_.clear();
        } else if (purpose_ == Purpose::quit) done_ = true;
        else if (purpose_ == Purpose::filter) {
            filter_ = std::move(value);
            rebuild();
        } else if (purpose_ == Purpose::job_filter) {
            job_filter_ = lower(std::move(value));
            job_offset_ = 0;
        } else if (purpose_ == Purpose::field) {
            params_[action_->fields.at(field_++).at("id").get<std::string>()] = utf8(value);
            std::fill(value.begin(), value.end(), L'\0');
            next_field();
        } else if (purpose_ == Purpose::confirm) run_action();
    }

    void edit_dialog(Key key) {
        auto &d = *dialog_;
        if (escape(key)) return close_dialog(false);
        if (d.reveal) {
            if (enter(key) && !d.hidden.empty()) {
                d.description = std::move(d.hidden);
                d.hidden.clear();
                d.accept = true;
            } else if (enter(key)) close_dialog(true);
            return;
        }
        if (!d.choices.empty()) {
            if (enter(key)) return close_dialog(true);
            if (key.special && key.value == KEY_UP) move_row(-1, d.choices.size(), d.selected);
            if (key.special && key.value == KEY_DOWN) move_row(1, d.choices.size(), d.selected);
            return;
        }
        if (enter(key) && d.edit_lines) {
            if (d.value.size() < 3500) d.value.insert(d.cursor++, 1, L'\n');
            return;
        }
        if (d.edit_lines && !key.special && key.value == 19) return close_dialog(true);
        if (enter(key)) return close_dialog(d.choose && (d.accept || d.editable));
        if (!d.choose && !key.special && key.value == ' ') return close_dialog(false);
        if (key.special && (key.value == KEY_UP || key.value == KEY_DOWN ||
                            key.value == KEY_PPAGE || key.value == KEY_NPAGE)) {
            const int limit = static_cast<int>(wrap(d.description, std::min(inner_width, COLS - 2) - 4).size()) - 1;
            const int delta = key.value == KEY_UP ? -1 : key.value == KEY_DOWN ? 1 : key.value == KEY_PPAGE ? -8 : 8;
            d.offset = std::clamp(d.offset + delta, 0, std::max(0, limit));
        } else if ((!key.special && key.value == '\t') || (key.special && key.value == KEY_BTAB) ||
                   (!d.editable && key.special && (key.value == KEY_LEFT || key.value == KEY_RIGHT))) {
            if (d.choose) d.accept = !d.accept;
        } else if (d.editable) {
            if (key.special && key.value == KEY_LEFT && d.cursor) --d.cursor;
            else if (key.special && key.value == KEY_RIGHT && d.cursor < d.value.size()) ++d.cursor;
            else if (key.special && key.value == KEY_HOME) d.cursor = 0;
            else if (key.special && key.value == KEY_END) d.cursor = d.value.size();
            else if (key.special && key.value == KEY_DC && d.cursor < d.value.size()) d.value.erase(d.cursor, 1);
            else if (((key.special && key.value == KEY_BACKSPACE) ||
                      (!key.special && (key.value == 127 || key.value == 8))) && d.cursor) {
                d.value.erase(--d.cursor, 1);
            } else if (!key.special && iswprint(key.value) && d.value.size() < (d.edit_lines ? 3500U : 768U)) {
                d.value.insert(d.cursor++, 1, static_cast<wchar_t>(key.value));
            }
        }
    }

    void handle(Key key) {
        if (key.special && key.value == KEY_RESIZE) {
            shell_.resize(LINES, COLS);
            for (const auto &entry : jobs_) if (entry.job->terminal()) entry.job->terminal()->resize(LINES, COLS);
            return;
        }
        auto *pty = visible_terminal();
        if (!pty && key.special && key.value == paste_start) { ui_paste_ = true; return; }
        if (!pty && key.special && key.value == paste_end) { ui_paste_ = false; return; }
        if (ui_paste_ && (!dialog_ || key.special || !iswprint(key.value))) return;
        if (!key.special && key.value == 15 && !(pty && pty->pasting())) {
            if (literal_prefix_ && pty) {
                pty->send(key);
                literal_prefix_.reset();
                return;
            }
            if (demo_) { notice_ = "Оболочка доступна в рабочем режиме."; return; }
            if (!shell_visible_ && !shell_.active()) shell_.start_shell(terminal_.original_mode(), LINES, COLS);
            shell_visible_ = !shell_visible_;
            if (shell_visible_ && active_jobs()) notice_ = "Открыта оболочка. Фоновые операции продолжаются.";
            return;
        }
        if (pty) {
            if (literal_prefix_) {
                if (external_ && !shell_visible_ && !key.special && key.value == 29) {
                    external_ = nullptr;
                    literal_prefix_.reset();
                    return;
                }
                pty->send({28, false});
                literal_prefix_.reset();
            }
            if (!key.special && key.value == 28 && !pty->pasting()) literal_prefix_ = Clock::now() + 350ms;
            else pty->send(key);
            return;
        }
        if (dialog_) return edit_dialog(key);
        if (key.special && key.value == KEY_F(10)) return quit();
        if (key.special && key.value == KEY_F(1)) {
            return open({"Справка", "↑/↓ — выбор. Enter / F2 — открыть действие. ←/→ / Tab — раздел. "
                        "F3 — описание. F6 — задания, Ctrl+C — отмена доступной задачи. F7 — поиск. "
                        "F9 — строка разделов. F10 — выход. Ctrl+O — постоянная оболочка. "
                        "Для передачи Ctrl+O программе в оболочке нажмите Ctrl+\\, затем Ctrl+O."}, Purpose::help);
        }
        if (key.special && key.value == KEY_F(6)) {
            jobs_visible_ = !jobs_visible_;
            return;
        }
        if (jobs_visible_) {
            if (escape(key)) jobs_visible_ = false;
            else if (key.special && (key.value == KEY_LEFT || key.value == KEY_RIGHT)) {
                move_row(key.value == KEY_LEFT ? -1 : 1, jobs_.size(), job_row_);
                job_offset_ = 0;
                job_column_ = 0;
                report_table_ = 0;
                report_sort_ = -1;
                show_job_log_ = false;
            } else if (!jobs_.empty()) {
                auto &entry = jobs_[job_row_];
                auto &job = *entry.job;
                const bool report = !show_job_log_ && !job.tables().empty();
                const size_t limit = report ? job.tables()[report_table_].rows.size() : job.lines().size();
                const int direction = report ? 1 : -1;
                if (key.special && key.value == KEY_UP) move_row(-direction, limit, job_offset_);
                if (key.special && key.value == KEY_DOWN) move_row(direction, limit, job_offset_);
                if (key.special && key.value == KEY_PPAGE) move_row(-10 * direction, limit, job_offset_);
                if (key.special && key.value == KEY_NPAGE) move_row(10 * direction, limit, job_offset_);
                if (key.special && key.value == KEY_HOME) job_offset_ = report ? 0 : limit;
                if (key.special && key.value == KEY_END) job_offset_ = report ? limit : 0;
                if (key.special && key.value == KEY_SLEFT) job_column_ = std::max(0, job_column_ - 10);
                if (key.special && key.value == KEY_SRIGHT) job_column_ = std::min(4096, job_column_ + 10);
                if (key.special && key.value == KEY_F(2) && report) {
                    report_sort_ = (report_sort_ + 1) % static_cast<int>(job.tables()[report_table_].columns.size());
                    job_offset_ = 0;
                }
                if (key.special && key.value == KEY_F(3)) {
                    show_job_log_ = !show_job_log_;
                    job_offset_ = 0;
                    job_column_ = 0;
                }
                if (key.special && key.value == KEY_F(5) && !job.running() && entry.action->risk == "read_only") {
                    const Json params = entry.parameters;
                    return launch(*entry.action, params);
                }
                if (!key.special && key.value == '\t' && job.tables().size() > 1) {
                    report_table_ = (report_table_ + 1) % job.tables().size();
                    report_sort_ = -1;
                    job_offset_ = 0;
                    job_column_ = 0;
                }
                if (key.special && key.value == KEY_F(7)) {
                    return open({"Поиск", "Введите текст для фильтрации вывода.", true, false, true, false,
                                 job_filter_}, Purpose::job_filter);
                }
                if (!key.special && key.value == 3) job.cancel();
                if (enter(key) && job.terminal() && job.terminal()->active()) external_ = &job;
            }
            return;
        }
        if (COLS < 60 || LINES < 20) {
            if (escape(key)) quit();
            return;
        }
        if (key.special && key.value == KEY_F(7)) {
            return open({"Поиск действий", "Введите часть названия.", true,
                         false, true, false, filter_}, Purpose::filter);
        }
        if (key.special && key.value == KEY_F(9)) { section_focus_ = !section_focus_; return; }
        if (key.special && key.value == KEY_F(5)) { const size_t selection = selected_; rebuild();
            if (!visible_.empty()) selected_ = std::min(selection, visible_.size() - 1);
            return;
        }
        if ((!key.special && key.value == '\t') || (key.special &&
            (key.value == KEY_BTAB || key.value == KEY_LEFT || key.value == KEY_RIGHT))) {
            const bool reverse = key.special && (key.value == KEY_LEFT || key.value == KEY_BTAB);
            section_ = (section_ + (reverse ? sections_.size() - 1 : 1)) % sections_.size();
            filter_.clear();
            rebuild();
            return;
        }
        if (escape(key)) {
            if (!filter_.empty()) { filter_.clear(); rebuild(); }
            else if (section_focus_) section_focus_ = false;
            else quit();
            return;
        }
        if (enter(key) && section_focus_) { section_focus_ = false; return; }
        if (enter(key) || (key.special && key.value == KEY_F(2))) return choose_action();
        if (!key.special) return;
        switch (key.value) {
        case KEY_UP: move_row(-1, visible_.size(), selected_); break;
        case KEY_DOWN: move_row(1, visible_.size(), selected_); break;
        case KEY_PPAGE: move_row(-std::max(1, LINES - 8), visible_.size(), selected_); break;
        case KEY_NPAGE: move_row(std::max(1, LINES - 8), visible_.size(), selected_); break;
        case KEY_HOME: selected_ = 0; break;
        case KEY_END: if (!visible_.empty()) selected_ = visible_.size() - 1; break;
        case KEY_F(3):
            if (!visible_.empty()) open({visible_[selected_]->title, visible_[selected_]->summary}, Purpose::help);
            break;
        }
    }

    void draw_dialog() {
        const auto &d = *dialog_;
        const int width = std::min(inner_width, COLS - 2);
        const int height = std::min(LINES - 2, std::max(8, d.edit_lines ? 18 :
            static_cast<int>(wrap(d.description, width - 4).size() + d.choices.size()) + 7));
        Window win(newwin(height, width, (LINES - height) / 2, (COLS - width) / 2), delwin);
        if (!win) return;
        Panel panel(new_panel(win.get()), del_panel);
        if (!panel) return;
        wbkgd(win.get(), ' ' | theme(3));
        box(win.get(), 0, 0);
        draw_text(win.get(), 0, 2, width - 4, L" " + wide(d.title) + L" ");
        paragraph(win.get(), 2, 2, width - 4, (d.edit_lines || !d.choices.empty()) ? 2 : height - 6,
                  d.description, d.offset);
        if (!d.choices.empty()) {
            const size_t room = height - 6;
            const size_t start = d.selected >= room ? d.selected - room + 1 : 0;
            for (size_t i = start; i < start + room && i < d.choices.size(); ++i) {
                if (i == d.selected) wattron(win.get(), A_REVERSE);
                draw_text(win.get(), 4 + static_cast<int>(i - start), 2, width - 4,
                          wide(d.choices[i].at("label").get<std::string>()));
                wattroff(win.get(), A_REVERSE);
            }
            draw_text(win.get(), height - 2, 2, width - 4, L"Enter — выбрать · Esc — отменить");
        } else if (d.edit_lines) {
            const auto before = wrap(utf8(d.value.substr(0, d.cursor)), width - 6);
            const int room = height - 6;
            const int row = static_cast<int>(before.size()) - 1;
            const int start = std::max(0, row - room + 1);
            paragraph(win.get(), 4, 3, width - 6, room, utf8(d.value), start);
            const auto &line = before.back();
            const int column = std::clamp(wcswidth(line.data(), line.size()), 0, width - 6);
            draw_text(win.get(), height - 2, 2, width - 4, L"Ctrl+S — применить · Esc — отменить");
            wmove(win.get(), row - start + 4, column + 3);
            curs_set(1);
        } else if (d.editable) {
            Window field_window(derwin(win.get(), 1, width - 6, height - 4, 3), delwin);
            Field field(field_window ? new_field(1, width - 6, 0, 0, 0, 0) : nullptr, free_field);
            FIELD *fields[]{field.get(), nullptr};
            Form form(field ? new_form(fields) : nullptr, free_form);
            if (form) {
                field_opts_off(field.get(), O_AUTOSKIP);
                set_field_back(field.get(), A_UNDERLINE);
                set_form_win(form.get(), win.get());
                set_form_sub(form.get(), field_window.get());
                std::wstring text = d.secret ? std::wstring(d.value.size(), L'*') : d.value;
                size_t start = 0;
                int used = 0;
                for (size_t pos = d.cursor; pos > 0; --pos) {
                    used += std::max(0, wcwidth(text[pos - 1]));
                    if (used >= width - 6) { start = pos; break; }
                }
                set_field_buffer(field.get(), 0, utf8(text.substr(start)).c_str());
                if (post_form(form.get()) == E_OK) {
                    form_driver(form.get(), REQ_BEG_FIELD);
                    for (size_t pos = start; pos < d.cursor; ++pos) form_driver(form.get(), REQ_NEXT_CHAR);
                    if (!d.accept) {
                        pos_form_cursor(form.get());
                        curs_set(1);
                    }
                    unpost_form(form.get());
                    draw_text(win.get(), height - 4, 3, width - 6, text.substr(start));
                }
            }
        }
        if (d.reveal) {
            draw_text(win.get(), height - 2, 2, width - 4,
                      d.hidden.empty() ? L"Enter — продолжить · Esc — отменить" : L"Enter — показать · Esc — отменить");
        } else if (d.choose && !d.edit_lines && d.choices.empty() && !d.editable) {
            Item cancel(new_item("Отмена", ""), free_item), apply(new_item("Применить", ""), free_item);
            ITEM *items[]{cancel.get(), apply.get(), nullptr};
            Menu menu(cancel && apply ? new_menu(items) : nullptr, free_menu);
            Window row(derwin(win.get(), 1, width - 4, height - 2, 2), delwin);
            if (menu && row) {
                set_menu_win(menu.get(), win.get());
                set_menu_sub(menu.get(), row.get());
                set_menu_format(menu.get(), 1, 2);
                set_menu_mark(menu.get(), "");
                set_menu_fore(menu.get(), A_REVERSE | A_BOLD);
                set_menu_back(menu.get(), theme(3));
                set_current_item(menu.get(), d.accept ? apply.get() : cancel.get());
                if (post_menu(menu.get()) == E_OK) {
                    touchwin(win.get());
                    update_panels();
                    terminal_.present();
                    unpost_menu(menu.get());
                    return;
                }
            }
            draw_text(win.get(), height - 2, 2, width - 4,
                      d.accept ? L"Отмена   [Применить]" : L"[Отмена]   Применить");
        } else if (d.editable && !d.edit_lines) {
            draw_text(win.get(), height - 2, 2, width - 4, L"Enter — продолжить · Esc — отменить");
        } else if (!d.choose) draw_text(win.get(), height - 2, 2, width - 4, L"Esc — закрыть");
        update_panels();
        terminal_.present();
    }

    void draw_jobs(int top, int bottom) {
        if (jobs_.empty()) {
            paragraph(stdscr, top, 2, COLS - 4, 1, "Заданий пока нет.");
            return;
        }
        const auto &entry = jobs_[job_row_];
        const auto &lines = entry.job->lines();
        draw_text(stdscr, top, 2, COLS - 4, wide(std::to_string(job_row_ + 1) + "/" + std::to_string(jobs_.size()) +
                  " · " + entry.title + " · " + entry.job->status()));
        if (!show_job_log_ && (!entry.job->tables().empty() || !entry.job->report_text().empty())) {
            return draw_report(*entry.job, top + 2, bottom);
        }
        std::vector<std::wstring> matching;
        for (const auto &line : lines) {
            auto display = wide(line);
            if (job_filter_.empty() || lower(display).find(job_filter_) != std::wstring::npos) {
                matching.push_back(std::move(display));
            }
        }
        const size_t end = matching.size() - std::min(job_offset_, matching.empty() ? size_t{0} : matching.size() - 1);
        const size_t room = std::max(0, bottom - top - 2);
        const size_t start = end - std::min(end, room);
        int row = top + 2;
        for (size_t i = start; i < end; ++i) {
            const auto &line = matching[i];
            draw_text(stdscr, row++, 2, COLS - 4, line.substr(std::min<size_t>(job_column_, line.size())));
        }
    }

    void draw_report(const Job &job, int top, int bottom) {
        if (job.tables().empty()) {
            paragraph(stdscr, top, 2, COLS - 4, bottom - top, job.report_text());
            return;
        }
        const auto &table = job.tables()[report_table_];
        const auto lines = wrap(job.report_text(), COLS - 4);
        const int summary = std::min(4, static_cast<int>(lines.size()));
        for (int row = 0; row < summary; ++row) draw_text(stdscr, top + row, 2, COLS - 4, lines[row]);
        top += summary;
        if (top >= bottom - 1) return;
        std::vector<size_t> widths;
        for (const auto &column : table.columns) widths.push_back(std::clamp(wide(column).size() + 2, size_t{12}, size_t{26}));
        const auto render_row = [&](const auto &cells) {
            std::wstring output;
            for (size_t i = 0; i < cells.size(); ++i) {
                auto cell = wide(cells[i]);
                int used = 0;
                for (const wchar_t c : cell) {
                    const int size = std::max(0, wcwidth(c));
                    if (used + size > static_cast<int>(widths[i]) - 2) break;
                    used += size;
                    output += c;
                }
                output.append(widths[i] - used, L' ');
            }
            while (!output.empty() && output.back() == L' ') output.pop_back();
            return output.substr(std::min<size_t>(job_column_, output.size()));
        };
        auto indexes = std::vector<size_t>{};
        for (size_t row = 0; row < table.rows.size(); ++row) {
            const auto &cells = table.rows[row];
            if (job_filter_.empty() || std::any_of(cells.begin(), cells.end(), [this](const auto &cell) {
                return lower(wide(cell)).find(job_filter_) != std::wstring::npos;
            })) indexes.push_back(row);
        }
        if (report_sort_ >= 0 && static_cast<size_t>(report_sort_) < table.columns.size()) {
            std::stable_sort(indexes.begin(), indexes.end(), [&](size_t a, size_t b) {
                const auto key = [&](size_t row) {
                    const auto &cell = table.rows[row][report_sort_];
                    if (table.rows[row][0] == "ИТОГО") return std::make_tuple(2, 0.0, std::string{});
                    char *tail = nullptr;
                    const double number = strtod(cell.c_str(), &tail);
                    if (tail != cell.c_str() && std::isfinite(number)) {
                        const std::string_view unit(tail);
                        if (unit.empty() || unit == " B" || unit == " KiB" || unit == " MiB" || unit == " GiB") {
                            const double scale = unit == " KiB" ? 1024.0 : unit == " MiB" ? 1048576.0 :
                                unit == " GiB" ? 1073741824.0 : 1.0;
                            return std::make_tuple(0, number * scale, std::string{});
                        }
                    }
                    return std::make_tuple(1, 0.0, cell);
                };
                return key(a) < key(b);
            });
        }
        auto headers = table.columns;
        if (report_sort_ >= 0 && static_cast<size_t>(report_sort_) < headers.size()) headers[report_sort_] += " ↑";
        wattron(stdscr, theme(2, A_REVERSE));
        draw_text(stdscr, top++, 2, COLS - 4, render_row(headers));
        wattroff(stdscr, theme(2, A_REVERSE));
        const size_t first = std::min(job_offset_, indexes.empty() ? size_t{0} : indexes.size() - 1);
        for (size_t i = first; i < indexes.size() && top < bottom; ++i) {
            draw_text(stdscr, top++, 2, COLS - 4, render_row(table.rows[indexes[i]]));
        }
    }

    void draw_actions(int top, int bottom) {
        const bool split = COLS >= 80 && LINES >= 24;
        const int left = split ? std::max(36, COLS * 47 / 100) : COLS;
        Window list(newwin(bottom - top, left, top, 0), delwin);
        if (!list) return;
        wbkgd(list.get(), ' ' | theme(1));
        box(list.get(), 0, 0);
        draw_text(list.get(), 0, 2, left - 4, L" " + wide(sections_[section_]) + L" ");
        const int room = bottom - top - 2;
        if (selected_ < top_) top_ = selected_;
        if (selected_ >= top_ + room) top_ = selected_ - room + 1;
        if (visible_.empty()) draw_text(list.get(), 2, 2, left - 4, L"Поиск не дал результатов");
        for (int row = 0; row < room && top_ + row < visible_.size(); ++row) {
            const size_t index = top_ + row;
            if (index == selected_) {
                wattron(list.get(), theme(2, A_REVERSE));
                mvwhline(list.get(), row + 1, 1, ' ', left - 2);
            }
            draw_text(list.get(), row + 1, 2, left - 4, wide(visible_[index]->title));
            wattroff(list.get(), theme(2, A_REVERSE));
        }
        wnoutrefresh(list.get());
        if (!split) return;
        Window detail(newwin(bottom - top, COLS - left, top, left), delwin);
        if (!detail) return;
        wbkgd(detail.get(), ' ' | theme(1));
        box(detail.get(), 0, 0);
        const int width = COLS - left - 4;
        draw_text(detail.get(), 0, 2, width, L" О действии ");
        if (!visible_.empty()) {
            const auto &action = *visible_[selected_];
            paragraph(detail.get(), 2, 2, width, room - 2, action.summary);
        }
        wnoutrefresh(detail.get());
    }

    void draw() {
        if (auto *pty = visible_terminal()) {
            pty->draw();
            terminal_.present();
            return;
        }
        curs_set(0);
        wbkgdset(stdscr, ' ' | theme(1));
        werase(stdscr);
        if (LINES < 20 || COLS < 60) {
            paragraph(stdscr, 0, 0, COLS - 1, LINES,
                      "Увеличьте терминал до 60×20. F10 — выход. Ctrl+O — оболочка.");
            wnoutrefresh(stdscr);
        } else {
            wattron(stdscr, theme(2, A_REVERSE) | A_BOLD);
            mvwhline(stdscr, 0, 0, ' ', COLS);
            draw_text(stdscr, 0, 1, COLS - 2, wide(std::string(demo_ ? "DEMO · " : "") +
                      "RemnaSuper " REMNASUPER_VERSION " · " + host_ + " · Задачи: " + std::to_string(active_jobs())));
            wattroff(stdscr, theme(2, A_REVERSE) | A_BOLD);
            int x = 1;
            for (size_t i = section_focus_ ? section_ : 0; i < sections_.size() && x < COLS - 2; ++i) {
                const auto label = L" " + wide(sections_[i]) + L" ";
                if (i == section_) wattron(stdscr, theme(2, A_REVERSE));
                draw_text(stdscr, 1, x, COLS - x - 1, label);
                if (i == section_) wattroff(stdscr, theme(2, A_REVERSE));
                x += std::max(1, wcswidth(label.c_str(), label.size()));
            }
            std::string status = notice_.empty() ? "Ctrl+O — консоль · F9 — разделы" : notice_;
            if (installed_) status = "Обновление установлено. Перезапуск после закрытия оболочки и заданий.";
            if (!filter_.empty()) status += " · Фильтр: " + utf8(filter_);
            if (shell_.unread()) status += " · Есть вывод оболочки";
            draw_text(stdscr, LINES - 2, 1, COLS - 2, wide(status));
            wattron(stdscr, theme(2, A_REVERSE));
            mvwhline(stdscr, LINES - 1, 0, ' ', COLS);
            draw_text(stdscr, LINES - 1, 1, COLS - 2, jobs_visible_
                ? L"F2 Сорт.  F3 Вид  F5 Обновить  F6 Назад  F7 Поиск  F10 Выход"
                : L"F1 Справка  F2 Выбор  F3 Обзор  F5 Обновить  F6 Задачи  F7 Поиск  F10 Выход");
            wattroff(stdscr, theme(2, A_REVERSE));
            if (jobs_visible_) draw_jobs(3, LINES - 2);
            wnoutrefresh(stdscr);
            if (!jobs_visible_) draw_actions(3, LINES - 2);
        }
        if (dialog_ && LINES >= 12 && COLS >= 28) draw_dialog();
        else terminal_.present();
    }

    std::filesystem::path root_;
    std::vector<Action> actions_;
    bool demo_;
    std::string host_;
    Terminal terminal_;
    Pty shell_;
    std::vector<std::string> sections_;
    std::vector<const Action *> visible_;
    std::vector<Entry> jobs_;
    std::unique_ptr<Job> startup_;
    std::unique_ptr<Dialog> dialog_;
    Purpose purpose_ = Purpose::help;
    std::optional<Clock::time_point> literal_prefix_;
    Job *external_ = nullptr;
    Job *prompt_job_ = nullptr;
    const Action *action_ = nullptr;
    Json params_;
    std::wstring filter_;
    std::wstring job_filter_;
    std::string notice_;
    size_t section_ = 0, selected_ = 0, top_ = 0, job_row_ = 0, job_offset_ = 0, field_ = 0;
    unsigned sequence_ = 0;
    int job_column_ = 0;
    size_t report_table_ = 0;
    int report_sort_ = -1;
    bool show_job_log_ = false;
    bool ui_paste_ = false;
    bool section_focus_ = false, shell_visible_ = false, jobs_visible_ = false, done_ = false, shutting_down_ = false;
    bool restart_ = false, installed_ = false, interacted_ = false;
};
}

int main(int argc, char **argv) {
    bool demo = false, self_test = false;
    for (int i = 1; i < argc; ++i) {
        const std::string_view argument(argv[i]);
        if (argument == "--version") { puts(REMNASUPER_VERSION); return 0; }
        if (argument == "--help") {
            puts("Использование: rs-tui [--help | --version | --self-test | --demo]");
            return 0;
        }
        if (argument == "--demo") demo = true;
        else if (argument == "--self-test") self_test = true;
        else { fprintf(stderr, "Неизвестный аргумент: %s\n", argv[i]); return 2; }
    }
    try {
        if (!setlocale(LC_ALL, "") || strcasecmp(nl_langinfo(CODESET), "UTF-8") != 0) {
            if (!setlocale(LC_ALL, "C.UTF-8")) throw std::runtime_error("Нужна локаль UTF-8.");
        }
        setlocale(LC_NUMERIC, "C");
        const auto root = std::filesystem::canonical("/proc/self/exe").parent_path().parent_path();
        auto actions = load_actions(root);
        if (self_test) {
            if (actions.empty() || !std::filesystem::is_regular_file(root / "lib/backend/dispatch.py")) return 1;
            return 0;
        }
        if (!demo && geteuid() != 0) throw std::runtime_error("Запустите приложение через sudo rs-tui.");
        std::signal(SIGPIPE, SIG_IGN);
        std::signal(SIGTSTP, SIG_IGN);
        for (int signal : {SIGINT, SIGTERM, SIGHUP, SIGQUIT}) std::signal(signal, stop);
        if (demo) {
            actions.erase(std::remove_if(actions.begin(), actions.end(), [](const auto &item) {
                return item.id != "demo.sample";
            }), actions.end());
        } else {
            actions.erase(std::remove_if(actions.begin(), actions.end(), [](const auto &item) {
                return item.id == "demo.sample";
            }), actions.end());
        }
        bool restart;
        {
            App app(root, std::move(actions), demo);
            app.run();
            restart = app.restart_requested();
        }
        if (restart) {
            execl("/usr/local/bin/rs-tui", "rs-tui", static_cast<char *>(nullptr));
            throw std::runtime_error("Не удалось перезапустить rs-tui.");
        }
        return stopping ? 128 + stopping : 0;
    } catch (const std::exception &failure) {
        fprintf(stderr, "RemnaSuper: %s\n", failure.what());
        return 1;
    }
}

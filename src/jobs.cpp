#include "jobs.hpp"

#include <array>
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <stdexcept>
#include <sys/wait.h>
#include <unistd.h>

namespace {
constexpr size_t max_message = 64 * 1024;
constexpr size_t max_line = 4096;
constexpr size_t max_lines = 1200;

void close_fd(int &fd) {
    if (fd >= 0) close(fd);
    fd = -1;
}

class Pipe {
public:
    explicit Pipe(bool nonblocking = false) {
        if (pipe2(fds_, O_CLOEXEC) < 0) throw std::runtime_error("Не удалось открыть канал задания.");
        for (int &fd : fds_) {
            if (fd > 4) continue;
            const int copy = fcntl(fd, F_DUPFD_CLOEXEC, 5);
            if (copy < 0) {
                for (int &open_fd : fds_) close_fd(open_fd);
                throw std::runtime_error("Не удалось настроить канал задания.");
            }
            close(fd);
            fd = copy;
        }
        if (nonblocking) fcntl(fds_[0], F_SETFL, O_NONBLOCK);
    }
    ~Pipe() {
        for (int &fd : fds_) close_fd(fd);
    }
    int reader() const { return fds_[0]; }
    int writer() const { return fds_[1]; }
    int take(int index) {
        const int fd = fds_[index];
        fds_[index] = -1;
        return fd;
    }
private:
    int fds_[2]{};
};

bool put(int fd, const Json &value) {
    const std::string line = value.dump() + '\n';
    if (line.size() > 4096) return false;
    return write(fd, line.data(), line.size()) == static_cast<ssize_t>(line.size());
}

template<typename Callback>
bool drain(int &fd, const Callback &consume) {
    if (fd < 0) return false;
    bool changed = false;
    std::array<char, 4096> buffer;
    for (int i = 0; i < 8; ++i) {
        const auto count = read(fd, buffer.data(), buffer.size());
        if (count <= 0) {
            if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) close_fd(fd);
            break;
        }
        consume(std::string(buffer.data(), static_cast<size_t>(count)));
        changed = true;
    }
    return changed;
}

std::string display_output(const std::string &line) {
    enum class Escape { none, start, sequence, control, end };
    auto state = Escape::none;
    std::string clean;
    for (unsigned char c : line) {
        switch (state) {
        case Escape::none:
            if (c == 27) state = Escape::start;
            else if (c == '\t') clean += "    ";
            else if (c >= 32 && c != 127) clean += static_cast<char>(c);
            break;
        case Escape::start:
            if (c == '[') state = Escape::sequence;
            else if (c == ']' || c == 'P' || c == '^' || c == '_') state = Escape::control;
            else state = Escape::none;
            break;
        case Escape::sequence:
            if (c >= 0x40 && c <= 0x7e) state = Escape::none;
            break;
        case Escape::control:
            if (c == 7) state = Escape::none;
            else if (c == 27) state = Escape::end;
            break;
        case Escape::end:
            state = c == '\\' ? Escape::none : Escape::control;
            break;
        }
    }
    return clean;
}
}

Job::Job(const std::filesystem::path &script, const std::string &id, const std::string &action,
         const Json &parameters, bool can_cancel, const termios &mode, int rows, int cols, bool interactive,
         bool retain_terminal)
    : id_(id), cancel_signal_(can_cancel ?
          (action == "diag.pair" || action == "setup.configure.ssh.key.login" ? SIGINT : SIGTERM) : 0),
      retain_terminal_(retain_terminal) {
    Pipe request, events(true), output(true), errors(true);
    fcntl(request.writer(), F_SETFL, O_NONBLOCK);
    if (!put(request.writer(), {{"v", 1}, {"job_id", id}, {"action_id", action}, {"params", parameters}})) {
        throw std::runtime_error("Не удалось передать параметры задания.");
    }
    const std::string script_name = script.string();
    char python[] = "/usr/bin/python3";
    char no_cache[] = "-B";
    char *const argv[]{python, no_cache, const_cast<char *>(script_name.c_str()), nullptr};
    if (interactive) {
        terminal_ = std::make_unique<Pty>();
        terminal_->start(mode, rows, cols, argv, request.reader(), events.writer());
    } else {
        child_ = fork();
        if (child_ < 0) throw std::runtime_error("Не удалось запустить задание.");
        if (child_ == 0) {
            setpgid(0, 0);
            for (int signal : {SIGINT, SIGTERM, SIGHUP, SIGPIPE}) std::signal(signal, SIG_DFL);
            int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
            if (input < 0 || dup2(input, 0) < 0 || dup2(output.writer(), 1) < 0 ||
                dup2(errors.writer(), 2) < 0 || !connect_protocol(request.reader(), events.writer())) _exit(126);
            execv(argv[0], argv);
            _exit(127);
        }
        setpgid(child_, child_);
        output_ = output.take(0);
        errors_ = errors.take(0);
    }
    request_ = request.take(1);
    events_ = events.take(0);
}

Job::~Job() {
    for (int *fd : {&request_, &events_, &output_, &errors_}) close_fd(*fd);
    if (child_ > 0) {
        if (can_cancel()) kill(-child_, cancel_signal_);
        while (waitpid(child_, nullptr, 0) < 0 && errno == EINTR) {}
    }
}

void Job::poll_descriptors(std::vector<pollfd> &descriptors) const {
    for (const int fd : {output_, errors_, events_}) {
        if (fd >= 0) descriptors.push_back({fd, POLLIN, 0});
    }
    if (terminal_ && terminal_->fd() >= 0) descriptors.push_back({terminal_->fd(), terminal_->poll_events(), 0});
}

void Job::answer(bool accepted, const std::string &value) {
    if (prompt_.is_null()) return;
    if (!put(request_, {{"v", 1}, {"job_id", id_}, {"prompt_id", prompt_["prompt_id"]},
                        {"accepted", accepted}, {"value", value}})) {
        protocol_error_ = true;
        close_fd(request_);
    }
    prompt_ = nullptr;
}

void Job::cancel() {
    if (!can_cancel() || !running_) return;
    cancelled_ = true;
    if (terminal_) terminal_->send({3, false});
    else if (child_ > 0) kill(-child_, cancel_signal_);
}

void Job::append(std::string line) {
    if (lines_.size() == max_lines) lines_.pop_front();
    if (line.size() > max_line) line.resize(max_line);
    lines_.push_back(display_output(line));
}

void Job::consume_output(std::string &buffer, const std::string &chunk, const char *prefix) {
    for (const char c : chunk) {
        if (c == '\n') {
            append(prefix + buffer);
            buffer.clear();
        } else if (buffer.size() < max_line) {
            buffer += c;
        }
    }
}

void Job::consume_events(const std::string &bytes) {
    for (const char c : bytes) {
        if (c != '\n') {
            if (pending_events_.size() >= max_message) {
                protocol_error_ = true;
                close_fd(request_);
            } else pending_events_ += c;
            continue;
        }
        try {
            const auto event = Json::parse(pending_events_);
            if (event.at("v") != 1 || event.at("job_id") != id_ || received_result_) {
                throw std::runtime_error("неожиданное событие");
            }
            const std::string type = event.at("type");
            if (type == "result") {
                received_result_ = true;
                const std::string result = event.at("status");
                const int code = event.at("exit_code");
                if (result == "ok" && code == 0) status_ = "Завершено";
                else if (result == "partial") status_ = "Выполнено частично";
                else if (result == "cancelled") status_ = "Отменено";
                else if (result == "rollback_failed") status_ = "Откат завершился ошибкой";
                else if (result == "failed") status_ = "Ошибка";
                else throw std::runtime_error("неизвестный результат");
                data_ = event.value("data", Json{});
                append(status_ + " · код " + std::to_string(code));
            } else if (type == "selection") {
                selection_ = event.at("message").get<std::string>();
            } else if (type == "report_text") {
                if (report_text_.size() < 32768) report_text_ += event.at("message").get<std::string>() + "\n";
            } else if (type == "report_header") {
                if (tables_.size() >= 12) throw std::runtime_error("слишком много таблиц");
                auto columns = event.at("columns").get<std::vector<std::string>>();
                if (columns.empty() || columns.size() > 64) throw std::runtime_error("некорректные столбцы");
                tables_.push_back({std::move(columns), {}});
            } else if (type == "report_row") {
                auto cells = event.at("cells").get<std::vector<std::string>>();
                if (tables_.empty() || tables_.back().rows.size() >= 1000 || cells.size() != tables_.back().columns.size()) {
                    throw std::runtime_error("некорректная строка");
                }
                tables_.back().rows.push_back(std::move(cells));
            } else if (type == "prompt") {
                if (!prompt_.is_null() || !event.at("prompt_id").is_string()) {
                    throw std::runtime_error("неожиданный запрос");
                }
                prompt_ = event;
            } else if (type != "started") append(event.at("message").get<std::string>());
        } catch (const std::exception &) {
            protocol_error_ = true;
            close_fd(request_);
        }
        pending_events_.clear();
    }
}

bool Job::pump() {
    if (!running_) return false;
    bool changed = drain(events_, [this](const auto &bytes) { consume_events(bytes); });
    changed |= drain(output_, [this](const auto &bytes) { consume_output(pending_output_, bytes, ""); });
    changed |= drain(errors_, [this](const auto &bytes) { consume_output(pending_errors_, bytes, "[stderr] "); });
    if (terminal_) {
        changed |= terminal_->pump();
        if (terminal_->active()) return changed;
        exit_status_ = terminal_->status();
    } else if (child_ > 0) {
        if (waitpid(child_, &exit_status_, WNOHANG) != child_) return changed;
        child_ = -1;
        return true;
    }
    if (events_ >= 0 || output_ >= 0 || errors_ >= 0) {
        if (changed) return true;
        for (int *fd : {&events_, &output_, &errors_}) close_fd(*fd);
    }
    close_fd(request_);
    running_ = false;
    prompt_ = nullptr;
    if (terminal_ && retain_terminal_) {
        for (auto &line : terminal_->snapshot()) append(std::move(line));
    }
    if (!pending_output_.empty()) append(pending_output_);
    if (!pending_errors_.empty()) append("[stderr] " + pending_errors_);
    const int code = WIFEXITED(exit_status_) ? WEXITSTATUS(exit_status_) : 128 + WTERMSIG(exit_status_);
    if (protocol_error_ || !pending_events_.empty() || !received_result_ || (code != 0 && status_ == "Завершено")) {
        status_ = cancelled_ && !protocol_error_ && (code == 130 || code == 143)
            ? "Отменено" : "Ошибка протокола задания";
        append(status_ + " · код процесса " + std::to_string(code));
    }
    return true;
}

#pragma once

#include "terminal.hpp"

#include <deque>
#include <filesystem>
#include <nlohmann/json.hpp>
#include <poll.h>
#include <vector>

using Json = nlohmann::json;

struct ReportTable {
    std::vector<std::string> columns;
    std::vector<std::vector<std::string>> rows;
};

class Job {
public:
    Job(const std::filesystem::path &script, const std::string &id, const std::string &action,
        const Json &parameters, bool can_cancel, const termios &mode, int rows, int cols, bool interactive,
        bool retain_terminal);
    ~Job();
    Job(const Job &) = delete;
    Job &operator=(const Job &) = delete;
    void poll_descriptors(std::vector<pollfd> &descriptors) const;
    bool pump();
    void answer(bool accepted, const std::string &value);
    void cancel();
    bool running() const { return running_; }
    bool can_cancel() const { return cancel_signal_ != 0; }
    const std::deque<std::string> &lines() const { return lines_; }
    const std::string &status() const { return status_; }
    const Json &prompt() const { return prompt_; }
    const Json &data() const { return data_; }
    const std::vector<ReportTable> &tables() const { return tables_; }
    const std::string &report_text() const { return report_text_; }
    const std::string &selection() const { return selection_; }
    Pty *terminal() const { return terminal_.get(); }
private:
    void append(std::string line);
    void consume_output(std::string &buffer, const std::string &chunk, const char *prefix);
    void consume_events(const std::string &bytes);
    int request_ = -1;
    int events_ = -1;
    int output_ = -1;
    int errors_ = -1;
    pid_t child_ = -1;
    int exit_status_ = 0;
    std::string id_;
    int cancel_signal_ = 0;
    bool cancelled_ = false;
    bool running_ = true;
    bool protocol_error_ = false;
    bool received_result_ = false;
    bool retain_terminal_;
    std::string status_ = "Выполняется";
    std::deque<std::string> lines_;
    std::string pending_events_;
    std::string pending_output_;
    std::string pending_errors_;
    std::unique_ptr<Pty> terminal_;
    std::vector<ReportTable> tables_;
    std::string report_text_;
    std::string selection_;
    Json prompt_;
    Json data_;
};

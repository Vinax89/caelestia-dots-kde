#pragma once
#include <string>
#include <vector>

namespace Runner {
    struct Step {
        std::string name;
        std::string script_path;
        std::string status; // "PENDING", "RUNNING", "OK", "FAILED", "IGNORED"
    };

    extern std::vector<Step> steps;

    // Steps the user explicitly chose to skip via the "Ignore" action. The
    // installation still completes; main() reports these in the exit summary.
    extern std::vector<std::string> ignored_steps;

    std::string show_error_dialog(const std::string& step_name, const std::string& script_path, int term_w, int term_h);
    void draw_progress_ui(int current_step);
    bool execute();
}

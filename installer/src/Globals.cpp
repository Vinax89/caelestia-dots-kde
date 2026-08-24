#include "Globals.hpp"
#include <iostream>
#include <fstream>
#include <filesystem>
#include <unistd.h>
#include <cctype>
#include <cstdlib>
#include <algorithm>
#include <signal.h>

std::atomic<bool> g_resized{false};
std::atomic<bool> g_quit{false};
int g_term_width = 80;
int g_term_height = 24;
std::string g_base_distro = "unknown";
std::string g_bundle_dir = ".";
std::string g_installer_runtime_dir;
std::string g_sudo_bin_dir;

int run_shell(const std::string& command) {
    const int status = std::system(command.c_str());
    if (status == -1) {
        std::cerr << "Failed to run: " << command << '\n';
    }
    return status;
}

bool is_valid_env_name(const std::string& name) {
    if (name.empty())
        return false;
    const unsigned char first = static_cast<unsigned char>(name.front());
    if (!(std::isalpha(first) || name.front() == '_'))
        return false;
    for (char c : name) {
        const unsigned char value = static_cast<unsigned char>(c);
        if (!(std::isalnum(value) || c == '_'))
            return false;
    }
    return true;
}

// Read a PID written by a backgrounded shell command and signal it. Guards
// against a truncated or absent file writing 0 into `pid`, which would signal
// the whole process group.
static void terminate_recorded_pid(const std::string& path) {
    std::ifstream pidFile(path);
    pid_t pid = 0;
    if (pidFile >> pid && pid > 1)
        kill(pid, SIGTERM);
}

void cleanup_installer_runtime() {
    if (g_installer_runtime_dir.empty())
        return;

    std::error_code error;
    // The sudo-timestamp keepalive exits on its own once this process is gone
    // (it polls `kill -0`), but stopping it here avoids leaving it running for
    // up to one extra sleep interval.
    terminate_recorded_pid(g_installer_runtime_dir + "/sudo-keepalive.pid");
    terminate_recorded_pid(g_installer_runtime_dir + "/inhibit.pid");
    std::ifstream cookieFile(g_installer_runtime_dir + "/inhibit.cookie");
    std::string cookie;
    if (cookieFile >> cookie && !cookie.empty()
        && std::all_of(cookie.begin(), cookie.end(), [](unsigned char c) { return std::isdigit(c); })) {
        run_shell("qdbus6 org.freedesktop.ScreenSaver /ScreenSaver "
            "org.freedesktop.ScreenSaver.UnInhibit " + cookie + " >/dev/null 2>&1");
    }
    std::filesystem::remove_all(g_installer_runtime_dir, error);
    g_installer_runtime_dir.clear();
    g_sudo_bin_dir.clear();
}
bool g_confirm_arg = false;

Config g_config;
bool g_logout = false;
json g_theme;
json g_menu;
std::unordered_map<std::string, std::string> g_theme_colors;

void load_theme() {
    g_theme_colors.clear();

    std::string path = g_bundle_dir + "/installer/theme.json";
    std::ifstream f(path);
    if (f.is_open()) {
        try {
            g_theme = json::parse(f, nullptr, true, true);
            if (g_theme.contains("colors") && g_theme["colors"].is_object()) {
                for (auto& [name, value] : g_theme["colors"].items()) {
                    if (value.is_string()) {
                        g_theme_colors[name] = "\x1b[" + value.get<std::string>();
                    }
                }
            }
        } catch (...) {
            std::cerr << "Failed to parse theme.json" << std::endl;
        }
    } else {
        std::cerr << "Could not open theme.json at " << path << std::endl;
    }

    std::string menu_path = g_bundle_dir + "/installer/menu.json";
    std::ifstream f2(menu_path);
    if (f2.is_open()) {
        try {
            g_menu = json::parse(f2, nullptr, true, true);
        } catch (...) {
            std::cerr << "Failed to parse menu.json" << std::endl;
        }
    } else {
        std::cerr << "Could not open menu.json at " << menu_path << std::endl;
    }
}


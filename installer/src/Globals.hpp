#pragma once
#include "json.hpp"
#include <atomic>
#include <string>
#include <unordered_map>
#include <vector>

using json = nlohmann::json;

extern json g_theme;
extern json g_menu;
extern std::unordered_map<std::string, std::string> g_theme_colors;

extern std::atomic<bool> g_resized;
extern std::atomic<bool> g_quit;
extern int g_term_width;
extern int g_term_height;
extern std::string g_base_distro;
extern std::string g_bundle_dir;
extern std::string g_installer_runtime_dir;
extern std::string g_sudo_bin_dir;

void cleanup_installer_runtime();

// Run a shell command via system(). Returns the raw system() status so callers
// that care can inspect it; callers that don't get warn_unused_result handled
// here instead of ignoring it at each site.
int run_shell(const std::string& command);
extern bool g_confirm_arg;

void load_bundle_dir();

bool is_valid_env_name(const std::string& name);
void load_theme();

struct Config {
  bool enable_transaction_confirm = true;
  bool remove_cache = false;
  bool apply_darkly = true;
  bool enable_material_you = true;
  bool apply_custom_fonts = true;
};

extern Config g_config;
extern bool g_logout;

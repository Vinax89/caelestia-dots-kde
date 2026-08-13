// SPDX-License-Identifier: GPL-3.0-only
#include "plasmawindows.hpp"

#include <QCoreApplication>
#include <QLoggingCategory>
#include <QUuid>

namespace caelestia::services {

namespace {

Q_LOGGING_CATEGORY(logPlasmaWindows, "caelestia.services.plasmawindows");

// get_window_by_uuid, which is what lets us address a window without mirroring
// KWin's entire window list. get_icon needs 7, so 12 covers both.
constexpr int kRequiredVersion = 12;

// Set once the Wayland connection is on its way out. Releasing a proxy is
// itself a request, so doing it afterwards marshals onto freed memory and takes
// the shell down with a SIGSEGV. Everything is released up front from
// aboutToQuit, while the connection is still live; anything that survives past
// that point must let its proxy leak rather than touch it.
bool s_connectionGone = false;

} // namespace

PlasmaWindowHandle::PlasmaWindowHandle(::org_kde_plasma_window* window)
    : QtWayland::org_kde_plasma_window(window) {}

PlasmaWindowHandle::~PlasmaWindowHandle() {
    if (!s_connectionGone && isInitialized()) {
        destroy();
    }
}

QString PlasmaWindowHandle::uuid() const {
    return m_uuid;
}

void PlasmaWindowHandle::setUuid(const QString& uuid) {
    m_uuid = uuid;
}

void PlasmaWindowHandle::org_kde_plasma_window_title_changed(const QString& title) {
    if (m_title != title) {
        m_title = title;
        emit titleChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_app_id_changed(const QString& app_id) {
    if (m_appId != app_id) {
        m_appId = app_id;
        emit appIdChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_state_changed(uint32_t flags) {
    bool active = (flags & QtWayland::org_kde_plasma_window_management::state_active);
    bool minimized = (flags & QtWayland::org_kde_plasma_window_management::state_minimized);
    bool maximized = (flags & QtWayland::org_kde_plasma_window_management::state_maximized);
    bool fullscreen = (flags & QtWayland::org_kde_plasma_window_management::state_fullscreen);
    bool demandsAttention = (flags & QtWayland::org_kde_plasma_window_management::state_demands_attention);
    bool skipTaskbar = (flags & QtWayland::org_kde_plasma_window_management::state_skiptaskbar);
    
    bool changed = false;
    if (m_isActive != active) { m_isActive = active; changed = true; }
    if (m_isMinimized != minimized) { m_isMinimized = minimized; changed = true; }
    if (m_isMaximized != maximized) { m_isMaximized = maximized; changed = true; }
    if (m_isFullscreen != fullscreen) { m_isFullscreen = fullscreen; changed = true; }
    if (m_demandsAttention != demandsAttention) { m_demandsAttention = demandsAttention; changed = true; }
    if (m_skipTaskbar != skipTaskbar) { m_skipTaskbar = skipTaskbar; changed = true; }
    
    if (changed) {
        emit stateChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_geometry(int32_t x, int32_t y, uint32_t width, uint32_t height) {
    if (m_x != x || m_y != y || m_width != width || m_height != height) {
        m_x = x;
        m_y = y;
        m_width = width;
        m_height = height;
        emit geometryChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_pid_changed(uint32_t pid) {
    if (m_pid != pid) {
        m_pid = pid;
        emit pidChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_virtual_desktop_entered(const QString& id) {
    if (!m_desktops.contains(id)) {
        m_desktops.append(id);
        emit desktopsChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_virtual_desktop_left(const QString& id) {
    if (m_desktops.removeOne(id)) {
        emit desktopsChanged();
    }
}

void PlasmaWindowHandle::org_kde_plasma_window_unmapped() {
    emit unmapped();
}

PlasmaWindowManagement::PlasmaWindowManagement(QObject* parent)
    : QWaylandClientExtensionTemplate<PlasmaWindowManagement>(kRequiredVersion) {
    setParent(parent);
    initialize();
    if (!isInitialized() || !isActive()) {
        qCWarning(logPlasmaWindows)
            << "org_kde_plasma_window_management is not available (isInitialized:" << isInitialized()
            << ", isActive:" << isActive() << ")."
            << "The compositor may not support it at version" << kRequiredVersion
            << "or this app is missing org_kde_plasma_window_management from"
               " X-KDE-Wayland-Interfaces in its desktop file.";
    }
}

// org_kde_plasma_window_management has no destructor request, so there is
// nothing to release here beyond the base class teardown.
PlasmaWindowManagement::~PlasmaWindowManagement() = default;

void PlasmaWindowManagement::org_kde_plasma_window_management_window_with_uuid(uint32_t id, const QString& uuid) {
    emit windowWithUuid(id, uuid);
}

PlasmaWindows::PlasmaWindows(QObject* parent)
    : QObject(parent) {
    if (auto* app = QCoreApplication::instance()) {
        connect(app, &QCoreApplication::aboutToQuit, this, &PlasmaWindows::shutdown);
    }
}

PlasmaWindows* PlasmaWindows::instance() {
    static auto* s_instance = new PlasmaWindows();
    return s_instance;
}

QString PlasmaWindows::normaliseUuid(const QString& uuid) {
    // A uuid that differs only in its braces resolves to a window that is
    // immediately unmapped, which looks exactly like the protocol silently
    // doing nothing.
    const auto parsed = QUuid::fromString(uuid);
    return parsed.isNull() ? uuid : parsed.toString(QUuid::WithBraces);
}

bool PlasmaWindows::available() {
    if (s_connectionGone) {
        return false;
    }
    if (!m_management) {
        m_management = new PlasmaWindowManagement(this);
        connect(m_management, &PlasmaWindowManagement::windowWithUuid, this, &PlasmaWindows::onWindowWithUuid);
    }
    return m_management->isActive();
}

void PlasmaWindows::onWindowWithUuid(uint32_t id, const QString& raw_uuid) {
    const auto key = normaliseUuid(raw_uuid);
    if (m_handles.contains(key)) {
        return; // We already know about this one.
    }
    
    // We must request the window object using the id that the compositor just sent us.
    auto* window = m_management->get_window(id);
    auto* handle = new PlasmaWindowHandle(window);
    handle->setUuid(key);
    handle->setParent(this);
    connect(handle, &PlasmaWindowHandle::unmapped, this, [this, key]() { forget(key); });
    
    m_handles.insert(key, handle);
    emit windowAdded(key);
}

PlasmaWindowHandle* PlasmaWindows::handleFor(const QString& uuid) {
    if (uuid.isEmpty() || !available()) {
        return nullptr;
    }

    const auto key = normaliseUuid(uuid);
    if (const auto it = m_handles.constFind(key); it != m_handles.constEnd()) {
        return *it;
    }

    auto* handle = new PlasmaWindowHandle(m_management->get_window_by_uuid(key));
    handle->setUuid(key);
    handle->setParent(this);
    // The compositor answers an unknown uuid with an immediately unmapped
    // window rather than an error, so this doubles as the "no such window"
    // path: drop it and let the next call ask again.
    connect(handle, &PlasmaWindowHandle::unmapped, this, [this, key]() { forget(key); });
    m_handles.insert(key, handle);
    return handle;
}

void PlasmaWindows::forget(const QString& uuid) {
    if (auto* handle = m_handles.take(uuid)) {
        handle->deleteLater();
    }
    emit handleLost(uuid);
}

void PlasmaWindows::shutdown() {
    if (s_connectionGone) {
        return;
    }

    const auto uuids = m_handles.keys();
    for (const auto& uuid : uuids) {
        delete m_handles.take(uuid);
    }

    delete m_management;
    m_management = nullptr;

    s_connectionGone = true;
}

} // namespace caelestia::services

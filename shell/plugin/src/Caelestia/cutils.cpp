#include "cutils.hpp"

#include <QtConcurrent/qtconcurrentrun.h>
#include <algorithm>
#include <qcryptographichash.h>
#include <QtQuick/qquickitemgrabresult.h>
#include <QtQuick/qquickwindow.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qfuturewatcher.h>
#include <qloggingcategory.h>
#include <qqmlengine.h>
#include <QStandardPaths>
#include <KWindowEffects>
#include <KModifierKeyInfo>

Q_LOGGING_CATEGORY(lcCUtils, "caelestia.cutils", QtInfoMsg)

namespace caelestia {

namespace {
bool isWithinRoot(const QString& path, const QString& root) {
    const QFileInfo rootInfo(root);
    const QString canonicalRoot = rootInfo.canonicalFilePath();
    if (canonicalRoot.isEmpty())
        return false;

    const QFileInfo pathInfo(path);
    const QString absolutePath = pathInfo.absoluteFilePath();
    QString existing = absolutePath;
    while (!QFileInfo::exists(existing)) {
        const QString parent = QFileInfo(existing).absolutePath();
        if (parent == existing)
            return false;
        existing = parent;
    }

    const QString canonicalExisting = QFileInfo(existing).canonicalFilePath();
    if (canonicalExisting.isEmpty())
        return false;

    const QString relative = QDir(existing).relativeFilePath(absolutePath);
    const QString canonicalPath = QDir::cleanPath(
        QDir(canonicalExisting).filePath(relative));
    return canonicalPath == canonicalRoot
        || canonicalPath.startsWith(canonicalRoot + QLatin1Char('/'));
}

bool isAllowedPath(const QString& path) {
    const QStringList roots = {
        QDir::homePath(),
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation),
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation),
        QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation)
    };
    return std::any_of(roots.cbegin(), roots.cend(), [&path](const QString& root) {
        return !root.isEmpty() && isWithinRoot(path, root);
    });
}
}

class CUtils::Private {
public:
    KModifierKeyInfo keyInfo;
};

CUtils::CUtils(QObject* parent)
    : QObject(parent)
    , d(new Private) {
    connect(&d->keyInfo, &KModifierKeyInfo::keyLocked, this, [this](Qt::Key key, bool locked) {
        Q_UNUSED(locked);
        if (key == Qt::Key_CapsLock) {
            emit capsLockChanged();
        } else if (key == Qt::Key_NumLock) {
            emit numLockChanged();
        }
    });
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path) {
    this->saveItem(target, path, QRect(), QJSValue(), QJSValue());
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path, const QRect& rect) {
    this->saveItem(target, path, rect, QJSValue(), QJSValue());
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path, QJSValue onSaved) {
    this->saveItem(target, path, QRect(), onSaved, QJSValue());
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path, QJSValue onSaved, QJSValue onFailed) {
    this->saveItem(target, path, QRect(), onSaved, onFailed);
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path, const QRect& rect, QJSValue onSaved) {
    this->saveItem(target, path, rect, onSaved, QJSValue());
}


void CUtils::saveItem(QQuickItem* target, const QUrl& path, const QRect& rect, QJSValue onSaved, QJSValue onFailed) {
    if (!target) {
        qCWarning(lcCUtils) << "saveItem: a target is required";
        return;
    }

    if (!path.isLocalFile() || !isAllowedPath(path.toLocalFile())) {
        qCWarning(lcCUtils) << "saveItem: refusing path outside allowed local roots" << path;
        if (onFailed.isCallable())
            onFailed.call();
        return;
    }

    if (!target->window()) {
        qCWarning(lcCUtils) << "saveItem: unable to save target" << target << "without a window";
        return;
    }
    const auto scale = target->window()->devicePixelRatio();
    QRect scaledRect = rect;
    if (rect.isValid() && !qFuzzyCompare(scale + 1.0, 2.0)) {
        scaledRect =
            QRectF(rect.left() * scale, rect.top() * scale, rect.width() * scale, rect.height() * scale).toRect();
    }

    const QSharedPointer<const QQuickItemGrabResult> grabResult = target->grabToImage();
    if (!grabResult) {
        qCWarning(lcCUtils) << "saveItem: target is not currently renderable";
        if (onFailed.isCallable())
            onFailed.call();
        return;
    }
    QObject::connect(grabResult.data(), &QQuickItemGrabResult::ready, this,
        [grabResult, scaledRect, path, onSaved, onFailed, this]() {
            const auto future = QtConcurrent::run([=]() {
                QImage image = grabResult->image();

                if (scaledRect.isValid()) {
                    image = image.copy(scaledRect);
                }

                const QString file = path.toLocalFile();
                const QString parent = QFileInfo(file).absolutePath();
                if (!isAllowedPath(file) || !QDir().mkpath(parent) || !isAllowedPath(file))
                    return false;
                return image.save(file);
            });

            auto* watcher = new QFutureWatcher<bool>(this);
            auto* engine = qmlEngine(this);

            QObject::connect(watcher, &QFutureWatcher<bool>::finished, this, [=]() {
                if (watcher->result()) {
                    if (onSaved.isCallable()) {
                        QJSValueList args = { QJSValue(path.toLocalFile()) };
                        if (engine) {
                            args << engine->toScriptValue(QVariant::fromValue(path));
                        }
                        onSaved.call(args);
                    }
                } else {
                    qCWarning(lcCUtils) << "saveItem: failed to save" << path;
                    if (onFailed.isCallable()) {
                        if (engine) {
                            onFailed.call({ engine->toScriptValue(QVariant::fromValue(path)) });
                        } else {
                            onFailed.call();
                        }
                    }
                }
                watcher->deleteLater();
            });
            watcher->setFuture(future);
        });
}

bool CUtils::copyFile(const QUrl& source, const QUrl& target, bool overwrite) {
    if (!source.isLocalFile() || !target.isLocalFile()
        || !isAllowedPath(source.toLocalFile())
        || !isAllowedPath(target.toLocalFile())) {
        qCWarning(lcCUtils) << "copyFile: refusing path outside allowed local roots"
                            << source << target;
        return false;
    }

    if (overwrite && QFile::exists(target.toLocalFile())) {
        if (!QFile::remove(target.toLocalFile())) {
            qCWarning(lcCUtils) << "copyFile: overwrite was specified but failed to remove" << target.toLocalFile();
            return false;
        }
    }

    return QFile::copy(source.toLocalFile(), target.toLocalFile());
}

bool CUtils::deleteFile(const QUrl& path) {
    if (!path.isLocalFile() || !isAllowedPath(path.toLocalFile())) {
        qCWarning(lcCUtils) << "deleteFile: refusing path outside allowed local roots" << path;
        return false;
    }

    return QFile::remove(path.toLocalFile());
}

QString CUtils::toLocalFile(const QUrl& url) {
    if (!url.isLocalFile()) {
        qCWarning(lcCUtils) << "toLocalFile: given url is not a local file" << url;
        return QString();
    }

    return url.toLocalFile();
}

QString CUtils::sha256(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        qCWarning(lcCUtils) << "sha256: failed to open" << path;
        return QString();
    }

    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(&file);
    file.close();

    return hash.result().toHex();
}

void CUtils::enableBlurBehind(QQuickWindow* window, bool enable) {
    if (window) {
        KWindowEffects::enableBlurBehind(window, enable);
    }
}

qreal CUtils::clamp(qreal value, qreal min, qreal max) {
    return qBound(min, value, max);
}

#ifndef CAELESTIA_VERSION
#define CAELESTIA_VERSION ""
#endif

QString CUtils::version() const {
    return QStringLiteral(CAELESTIA_VERSION);
}

QString CUtils::qtVersion() const {
    return QStringLiteral(QT_VERSION_STR);
}

bool CUtils::capsLock() const {
    return d->keyInfo.isKeyLocked(Qt::Key_CapsLock);
}

bool CUtils::numLock() const {
    return d->keyInfo.isKeyLocked(Qt::Key_NumLock);
}

} // namespace caelestia

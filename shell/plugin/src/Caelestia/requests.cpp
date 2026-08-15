#include "requests.hpp"

#include <qjsvalueiterator.h>
#include <qloggingcategory.h>
#include <qnetworkaccessmanager.h>
#include <qnetworkcookiejar.h>
#include <qnetworkreply.h>
#include <qnetworkrequest.h>

#include <qtimer.h>
#include <chrono>
Q_LOGGING_CATEGORY(lcRequests, "caelestia.requests", QtInfoMsg)

namespace caelestia {

Requests::Requests(QObject* parent)
    : QObject(parent)
    , m_manager(new QNetworkAccessManager(this)) {}

void Requests::get(const QUrl& url, QJSValue onSuccess, QJSValue onError, QJSValue headers) const {
    if (!onSuccess.isCallable()) {
        qCWarning(lcRequests) << "get: onSuccess is not callable";
        return;
    }

    QNetworkRequest request(url);
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    request.setRawHeader("Cache-Control", "no-cache, no-store");
    request.setRawHeader("Pragma", "no-cache");
    request.setRawHeader("Connection", "close");

    if (headers.isObject()) {
        QJSValueIterator it(headers);
        while (it.hasNext()) {
            it.next();
            request.setRawHeader(it.name().toUtf8(), it.value().toString().toUtf8());
        }
    }

    auto reply = m_manager->get(request);
    constexpr qint64 maxResponseBytes = 8 * 1024 * 1024;

    // The response is only consumed in the finished handler, so nothing drains
    // the buffer while it fills and bytesAvailable() is the total received so
    // far. The old code set the read buffer to exactly the limit it then tested
    // against, which capped bytesAvailable() at that same value and made the
    // comparison unreachable: an oversized response was throttled by
    // backpressure and held the connection open until the 30s timer fired.
    // Giving the buffer headroom above the limit makes the check fire.
    reply->setReadBufferSize(maxResponseBytes + 64 * 1024);
    QObject::connect(reply, &QNetworkReply::readyRead, reply, [reply]() {
        if (reply->bytesAvailable() > maxResponseBytes) {
            qCWarning(lcRequests) << "get: aborting response larger than" << maxResponseBytes << "bytes";
            reply->abort();
        }
    });
    QTimer::singleShot(std::chrono::seconds(30), reply, [reply]() {
        if (reply->isRunning())
            reply->abort();
    });

    QObject::connect(reply, &QNetworkReply::finished, [reply, onSuccess, onError]() {
        if (reply->error() == QNetworkReply::NoError) {
            onSuccess.call({ QString(reply->readAll()) });
        } else if (onError.isCallable()) {
            onError.call({ reply->errorString() });
        } else {
            qCWarning(lcRequests) << "get: request failed with error" << reply->errorString();
        }

        reply->deleteLater();
    });
}

void Requests::resetCookies() const {
    m_manager->setCookieJar(new QNetworkCookieJar(m_manager));
}

} // namespace caelestia

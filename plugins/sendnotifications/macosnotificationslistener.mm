/**
 * SPDX-FileCopyrightText: 2026 João Melo <joaolvcm@gmail.com>
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#include "macosnotificationslistener.h"

#include <QDir>
#include <QImage>
#include <QTimer>

#include <core/kdeconnectplugin.h>
#include <core/kdeconnectpluginconfig.h>

#include "plugin_sendnotifications_debug.h"

#import <AppKit/AppKit.h>
#include <sqlite3.h>

namespace
{
const int PollInterval = 1000;

QString databasePath()
{
    return QDir::homePath() + QStringLiteral("/Library/Group Containers/group.com.apple.usernoted/db2/db");
}

QString stringValue(NSDictionary *dict, NSString *key)
{
    id value = dict[key];
    return [value isKindOfClass:[NSString class]] ? QString::fromNSString(value) : QString();
}

QString applicationName(NSURL *appUrl, const QString &bundleId)
{
    if (appUrl) {
        NSDictionary *info = [NSBundle bundleWithURL:appUrl].infoDictionary;
        for (NSString *key : {@"CFBundleDisplayName", @"CFBundleName"}) {
            const QString name = stringValue(info, key);
            if (!name.isEmpty()) {
                return name;
            }
        }
    }
    return bundleId;
}

QImage applicationIcon(NSURL *appUrl)
{
    if (!appUrl) {
        return QImage();
    }
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appUrl.path];
    NSRect rect = NSMakeRect(0, 0, 64, 64);
    CGImageRef cgImage = [icon CGImageForProposedRect:&rect context:nil hints:nil];
    if (!cgImage) {
        return QImage();
    }
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:cgImage] autorelease];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return QImage::fromData(QByteArray::fromNSData(png), "PNG");
}
}

MacOSNotificationsListener::MacOSNotificationsListener(KdeConnectPlugin *aPlugin)
    : NotificationsListener(aPlugin)
    , m_timer(new QTimer(this))
{
    m_timer->setInterval(PollInterval);
    connect(m_timer, &QTimer::timeout, this, &MacOSNotificationsListener::poll);
    m_timer->start();
    poll();
}

MacOSNotificationsListener::~MacOSNotificationsListener()
{
    closeDatabase();
}

bool MacOSNotificationsListener::openDatabase()
{
    if (m_db) {
        return true;
    }

    if (sqlite3_open_v2(databasePath().toUtf8().constData(), &m_db, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
        if (!m_openFailureReported) {
            qCWarning(KDECONNECT_PLUGIN_SENDNOTIFICATIONS) << "Cannot open the Notification Center database, is Full Disk Access granted?"
                                                           << sqlite3_errmsg(m_db);
            m_openFailureReported = true;
        }
        closeDatabase();
        return false;
    }

    m_openFailureReported = false;
    return true;
}

void MacOSNotificationsListener::closeDatabase()
{
    sqlite3_close(m_db);
    m_db = nullptr;
}

void MacOSNotificationsListener::poll()
{
    if (!openDatabase()) {
        return;
    }

    sqlite3_stmt *stmt = nullptr;
    qint64 maxRecordId = -1;
    if (sqlite3_prepare_v2(m_db, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &stmt, nullptr) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        maxRecordId = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);

    if (maxRecordId < 0) {
        qCWarning(KDECONNECT_PLUGIN_SENDNOTIFICATIONS) << "Failed to query the Notification Center database:" << sqlite3_errmsg(m_db);
        closeDatabase();
        return;
    }

    // Skip notifications that were posted before we started, or a database that was recreated
    if (m_lastRecordId < 0 || maxRecordId < m_lastRecordId) {
        m_lastRecordId = maxRecordId;
        return;
    }
    if (maxRecordId == m_lastRecordId) {
        return;
    }

    const char *query =
        "SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON a.app_id = r.app_id"
        " WHERE r.rec_id > ?1 ORDER BY r.rec_id";
    if (sqlite3_prepare_v2(m_db, query, -1, &stmt, nullptr) != SQLITE_OK) {
        qCWarning(KDECONNECT_PLUGIN_SENDNOTIFICATIONS) << "Failed to query the Notification Center database:" << sqlite3_errmsg(m_db);
        closeDatabase();
        return;
    }
    sqlite3_bind_int64(stmt, 1, m_lastRecordId);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const qint64 recordId = sqlite3_column_int64(stmt, 0);
        const QString bundleId = QString::fromUtf8(reinterpret_cast<const char *>(sqlite3_column_text(stmt, 1)));
        const QByteArray data(static_cast<const char *>(sqlite3_column_blob(stmt, 2)), sqlite3_column_bytes(stmt, 2));
        m_lastRecordId = recordId;
        handleRecord(recordId, bundleId, data);
    }
    sqlite3_finalize(stmt);
}

void MacOSNotificationsListener::handleRecord(qint64 recordId, const QString &bundleId, const QByteArray &data)
{
    // Drop notifications that the notifications plugin created from a remote device, to avoid echoing them back
    if (bundleId.startsWith(QLatin1String("org.kde.kdeconnect"), Qt::CaseInsensitive)) {
        return;
    }

    @autoreleasepool {
        NSDictionary *record = [NSPropertyListSerialization propertyListWithData:data.toNSData() options:NSPropertyListImmutable format:nil error:nil];
        if (![record isKindOfClass:[NSDictionary class]] || ![record[@"req"] isKindOfClass:[NSDictionary class]]) {
            return;
        }
        NSDictionary *request = record[@"req"];

        NSURL *appUrl = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleId.toNSString()];
        const QString appName = applicationName(appUrl, bundleId);

        QString title = stringValue(request, @"titl");
        const QString subtitle = stringValue(request, @"subt");
        QString body = stringValue(request, @"body");
        if (!subtitle.isEmpty()) {
            body = body.isEmpty() ? subtitle : subtitle + QLatin1Char('\n') + body;
        }
        if (title.isEmpty()) {
            title = appName;
        }
        if (body.isEmpty() && title == appName) {
            return;
        }

        if (!checkApplicationName(appName, QString())) {
            return;
        }

        auto *config = m_plugin->config();
        const bool includeBody = config->getBool(QStringLiteral("generalIncludeBody"), true);

        QString ticker = title;
        if (!body.isEmpty() && includeBody) {
            ticker += QLatin1String(": ") + body;
        }

        if (checkIsInBlacklist(appName, ticker)) {
            return;
        }

        qCDebug(KDECONNECT_PLUGIN_SENDNOTIFICATIONS) << "Sending notification from" << appName << "with id" << recordId;

        NetworkPacket np(PACKET_TYPE_NOTIFICATION,
                         {
                             {QStringLiteral("id"), QString::number(recordId)},
                             {QStringLiteral("appName"), appName},
                             {QStringLiteral("ticker"), ticker},
                             {QStringLiteral("isClearable"), true},
                             {QStringLiteral("title"), title},
                             {QStringLiteral("silent"), false},
                         });

        if (!body.isEmpty() && includeBody) {
            np.set(QStringLiteral("text"), body);
        }

        if (config->getBool(QStringLiteral("generalSynchronizeIcons"), true)) {
            QSharedPointer<QIODevice> iconSource = iconFromQImage(applicationIcon(appUrl));
            if (iconSource) {
                np.setPayload(iconSource, iconSource->size());
            }
        }

        m_plugin->sendPacket(np);
    }
}

#include "moc_macosnotificationslistener.cpp"

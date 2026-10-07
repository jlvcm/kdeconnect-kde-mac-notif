/**
 * SPDX-FileCopyrightText: 2026 João Melo <joaolvcm@gmail.com>
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#pragma once

#include "notificationslistener.h"

struct sqlite3;
class QTimer;

/*
 * macOS has no public API to observe notifications posted by other applications,
 * so this polls the Notification Center database (requires Full Disk Access).
 */
class MacOSNotificationsListener : public NotificationsListener
{
    Q_OBJECT

public:
    explicit MacOSNotificationsListener(KdeConnectPlugin *aPlugin);
    ~MacOSNotificationsListener() override;

private:
    bool openDatabase();
    void closeDatabase();
    void poll();
    void handleRecord(qint64 recordId, const QString &bundleId, const QByteArray &data);

    sqlite3 *m_db = nullptr;
    qint64 m_lastRecordId = -1;
    bool m_openFailureReported = false;
    QTimer *m_timer;
};

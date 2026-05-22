// KDL syntax highlighter, attached to a QML TextEdit's QQuickTextDocument
// via the `textDocument` property. The QML side feeds in the token spans
// as JSON (same `[[start, len, "kind"], ...]` shape that
// WorkflowController::tokenize_kdl emits, used everywhere the source
// pane is rendered) and a colors map keyed by token kind, both driven
// from Theme. Highlights apply via QSyntaxHighlighter::setFormat, which
// updates QTextCharFormat ranges on the existing QTextDocument without
// rebuilding the document — so the cursor stays put across keystrokes
// and the live re-highlight thread doesn't fight Qt the way the
// RichText/HTML rebuild did.
#pragma once

#include <QColor>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QJsonValue>
#include <QList>
#include <QPointer>
#include <QQuickTextDocument>
#include <QString>
#include <QSyntaxHighlighter>
#include <QTextBlock>
#include <QTextCharFormat>
#include <QTextDocument>
#include <QVariant>
#include <QVariantMap>

class KdlSyntaxHighlighter : public QSyntaxHighlighter {
    Q_OBJECT
    Q_PROPERTY(QQuickTextDocument *textDocument READ textDocument WRITE setTextDocument NOTIFY textDocumentChanged)
    Q_PROPERTY(QString spansJson READ spansJson WRITE setSpansJson NOTIFY spansJsonChanged)
    Q_PROPERTY(QVariantMap colors READ colors WRITE setColors NOTIFY colorsChanged)

public:
    explicit KdlSyntaxHighlighter(QObject *parent = nullptr)
        : QSyntaxHighlighter(static_cast<QTextDocument *>(nullptr)) {
        Q_UNUSED(parent);
    }

    QQuickTextDocument *textDocument() const { return m_qq.data(); }

    void setTextDocument(QQuickTextDocument *doc) {
        if (m_qq.data() == doc) return;
        m_qq = doc;
        setDocument(doc ? doc->textDocument() : nullptr);
        emit textDocumentChanged();
    }

    QString spansJson() const { return m_spansJson; }

    void setSpansJson(const QString &s) {
        if (m_spansJson == s) return;
        m_spansJson = s;
        parseSpans();
        emit spansJsonChanged();
        if (document()) rehighlight();
    }

    QVariantMap colors() const { return m_colors; }

    void setColors(const QVariantMap &c) {
        m_colors = c;
        m_colorCache.clear();
        for (auto it = m_colors.constBegin(); it != m_colors.constEnd(); ++it) {
            QColor col = it.value().value<QColor>();
            if (col.isValid()) m_colorCache.insert(it.key(), col);
        }
        emit colorsChanged();
        if (document()) rehighlight();
    }

signals:
    void textDocumentChanged();
    void spansJsonChanged();
    void colorsChanged();

protected:
    void highlightBlock(const QString &text) override {
        if (m_spans.isEmpty() || m_colorCache.isEmpty()) return;
        const QTextBlock blk = currentBlock();
        const int blockStart = blk.position();
        const int blockEnd = blockStart + text.length();

        for (const Span &span : m_spans) {
            const int spanStart = span.start;
            const int spanEnd = span.start + span.len;
            if (spanStart >= blockEnd) break; // spans are in document order
            if (spanEnd <= blockStart) continue;

            const int localStart = qMax(0, spanStart - blockStart);
            const int localEnd = qMin(text.length(), spanEnd - blockStart);
            if (localEnd <= localStart) continue;

            const auto it = m_colorCache.constFind(span.kind);
            if (it == m_colorCache.constEnd()) continue;

            QTextCharFormat fmt;
            fmt.setForeground(it.value());
            if (span.kind == QLatin1String("comment")) fmt.setFontItalic(true);
            setFormat(localStart, localEnd - localStart, fmt);
        }
    }

private:
    struct Span {
        int start;
        int len;
        QString kind;
    };

    void parseSpans() {
        m_spans.clear();
        if (m_spansJson.isEmpty()) return;
        QJsonParseError err{};
        const QJsonDocument doc = QJsonDocument::fromJson(m_spansJson.toUtf8(), &err);
        if (err.error != QJsonParseError::NoError || !doc.isArray()) return;
        const QJsonArray arr = doc.array();
        m_spans.reserve(arr.size());
        for (const QJsonValue &v : arr) {
            if (!v.isArray()) continue;
            const QJsonArray tup = v.toArray();
            if (tup.size() < 3) continue;
            Span s;
            s.start = tup.at(0).toInt();
            s.len = tup.at(1).toInt();
            s.kind = tup.at(2).toString();
            if (s.len <= 0 || s.start < 0) continue;
            m_spans.push_back(s);
        }
    }

    QPointer<QQuickTextDocument> m_qq;
    QString m_spansJson;
    QVariantMap m_colors;
    QHash<QString, QColor> m_colorCache;
    QList<Span> m_spans;
};

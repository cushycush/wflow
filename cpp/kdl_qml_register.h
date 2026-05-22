// Runtime QML type registration for the KDL syntax highlighter.
// Called from Rust main before QQmlApplicationEngine loads any QML, so
// `import Wflow 1.0; KdlSyntaxHighlighter {}` resolves at QML parse
// time.
#pragma once

#include "kdl_syntax_highlighter.h"
#include <QtQml/qqml.h>

inline void register_kdl_qml_types() {
    qmlRegisterType<KdlSyntaxHighlighter>("Wflow", 1, 0, "KdlSyntaxHighlighter");
}

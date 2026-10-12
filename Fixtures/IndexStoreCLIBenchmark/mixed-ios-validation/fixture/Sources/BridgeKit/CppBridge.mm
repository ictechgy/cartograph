#include "CGCore.h"

static int cppHelper(int value) {
    return CGHeaderCppRoute(value);
}

static long cppHelper(long value) {
    return value + 700;
}

extern "C" int CGCppBridge(int value) {
    return cppHelper(value);
}

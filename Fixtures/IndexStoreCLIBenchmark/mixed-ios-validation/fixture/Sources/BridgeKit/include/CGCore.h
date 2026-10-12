#ifndef CG_CORE_H
#define CG_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

int CGBase(int value);
int CGAlternate(int value);
int CGBridge(int value);
int CGCppBridge(int value);
int CGUnusedC(int value);

#ifdef __cplusplus
static inline int CGHeaderCppRoute(int value) {
    return CGBase(value);
}
#else
static inline int CGHeaderRoute(int value) {
    return CGBase(value);
}
#endif

#ifdef __cplusplus
}
#endif

#endif

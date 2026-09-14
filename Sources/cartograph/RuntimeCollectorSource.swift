/// 실행 파일과 같은 프로세스에만 붙는 Objective-C 런타임 수집기 소스.
///
/// 별도 바이너리를 배포하면 도구 버전과 수집기 형식이 어긋날 수 있어 명령 실행 때
/// 현재 소스를 clang으로 컴파일한다. 앱의 인자·반환값은 기록하지 않는다.
enum RuntimeCollectorSource {
    static let source = #"""
    #import <Foundation/Foundation.h>
    #import <objc/runtime.h>
    #include <dlfcn.h>
    #include <execinfo.h>
    #include <fcntl.h>
    #include <mach-o/dyld.h>
    #include <mach/mach_time.h>
    #include <os/lock.h>
    #include <ptrauth.h>
    #include <pthread.h>
    #include <stdatomic.h>
    #include <stdbool.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <sys/types.h>
    #include <unistd.h>

    #define TRACE_MAX_EVENTS 20000
    #define TRACE_MAX_EVENT_BYTES 4096
    #define TRACE_EXPECTED_HOOK_MASK 0x7f

    static int traceEventFD = -1;
    static int traceStatusFD = -1;
    static pid_t traceProcessID = 0;
    static uint64_t traceEmittedEvents = 0;
    static uint64_t traceDroppedEvents = 0;
    static _Atomic uint64_t traceTruncatedValues = 0;
    static uint32_t traceHookMask = 0;
    static _Atomic uint32_t traceExitMarker = 0;
    static _Atomic uint32_t traceCaptureState = 0;
    static bool traceOverflowWritten = false;
    static os_unfair_lock traceLock = OS_UNFAIR_LOCK_INIT;
    static _Thread_local int traceDepth = 0;
    static char traceExecutablePath[4096];
    static char traceSealRequestPath[4096];
    static char traceSealAckPath[4096];
    static char traceSealNonce[33];
    static uint64_t traceStartedAt = 0;

    typedef struct {
        char bytes[TRACE_MAX_EVENT_BYTES];
        size_t length;
        bool valid;
    } TraceBuffer;

    static bool tracePrivateRegularFile(int descriptor) {
        struct stat status;
        if (fstat(descriptor, &status) != 0) {
            return false;
        }
        return S_ISREG(status.st_mode)
            && status.st_uid == geteuid()
            && (status.st_mode & (S_IRWXG | S_IRWXO)) == 0;
    }

    static void traceStore32(unsigned char *bytes, size_t offset, uint32_t value) {
        memcpy(bytes + offset, &value, sizeof(value));
    }

    static void traceStore64(unsigned char *bytes, size_t offset, uint64_t value) {
        memcpy(bytes + offset, &value, sizeof(value));
    }

    static bool traceWriteStatus(bool active) {
        if (traceStatusFD < 0) {
            return false;
        }
        unsigned char bytes[56] = {0};
        memcpy(bytes, "CTTRACE1", 8);
        traceStore32(bytes, 8, 1);
        traceStore32(bytes, 12, (uint32_t)traceProcessID);
        traceStore32(bytes, 16, active ? 1 : 0);
        traceStore32(bytes, 20, 0);
        traceStore64(bytes, 24, traceEmittedEvents);
        traceStore64(bytes, 32, traceDroppedEvents);
        traceStore64(bytes, 40, atomic_load(&traceTruncatedValues));
        traceStore32(bytes, 48, traceHookMask);
        traceStore32(bytes, 52, atomic_load(&traceExitMarker));
        return pwrite(traceStatusFD, bytes, sizeof(bytes), 0) == (ssize_t)sizeof(bytes)
            && fsync(traceStatusFD) == 0;
    }

    static void traceMarkComplete(void) {
        if (!traceWriteStatus(true)) {
            return;
        }
        uint32_t complete = 1;
        if (pwrite(traceStatusFD, &complete, sizeof(complete), 20) == (ssize_t)sizeof(complete)) {
            (void)fsync(traceStatusFD);
        }
    }

    static void traceAppendBytes(TraceBuffer *buffer, const char *bytes, size_t count) {
        if (!buffer->valid || count > sizeof(buffer->bytes) - buffer->length) {
            buffer->valid = false;
            return;
        }
        memcpy(buffer->bytes + buffer->length, bytes, count);
        buffer->length += count;
    }

    static void traceAppendCString(TraceBuffer *buffer, const char *value) {
        traceAppendBytes(buffer, value, strlen(value));
    }

    static void traceAppendJSON(TraceBuffer *buffer, const char *value) {
        traceAppendCString(buffer, "\"");
        for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0'; cursor++) {
            switch (*cursor) {
            case '\"': traceAppendCString(buffer, "\\\""); break;
            case '\\': traceAppendCString(buffer, "\\\\"); break;
            case '\n': traceAppendCString(buffer, "\\n"); break;
            case '\r': traceAppendCString(buffer, "\\r"); break;
            case '\t': traceAppendCString(buffer, "\\t"); break;
            default:
                if (*cursor < 0x20) {
                    char escaped[7];
                    snprintf(escaped, sizeof(escaped), "\\u%04x", *cursor);
                    traceAppendCString(buffer, escaped);
                } else {
                    traceAppendBytes(buffer, (const char *)cursor, 1);
                }
            }
        }
        traceAppendCString(buffer, "\"");
    }

    static void traceAppendUnsigned(TraceBuffer *buffer, uint64_t value) {
        char digits[32];
        snprintf(digits, sizeof(digits), "%llu", (unsigned long long)value);
        traceAppendCString(buffer, digits);
    }

    static void traceIncrementDroppedLocked(void) {
        traceDroppedEvents++;
        if (!traceOverflowWritten && traceEventFD >= 0) {
            const char marker[] =
                "{\"api\":\"cartograph.collector\",\"phase\":\"overflow\","
                "\"result\":false,\"droppedEvents\":1}\n";
            ssize_t written = write(traceEventFD, marker, sizeof(marker) - 1);
            if (written == (ssize_t)(sizeof(marker) - 1)) {
                traceEmittedEvents++;
                traceOverflowWritten = true;
            }
        }
        (void)traceWriteStatus(true);
    }

    static void traceWriteEvent(TraceBuffer *buffer) {
        traceAppendCString(buffer, "\n");
        os_unfair_lock_lock(&traceLock);
        if (atomic_load(&traceCaptureState) != 0) {
            os_unfair_lock_unlock(&traceLock);
            return;
        }
        if (traceEmittedEvents >= TRACE_MAX_EVENTS - 1) {
            traceIncrementDroppedLocked();
            os_unfair_lock_unlock(&traceLock);
            return;
        }
        if (!buffer->valid) {
            traceIncrementDroppedLocked();
            os_unfair_lock_unlock(&traceLock);
            return;
        }
        ssize_t written = write(traceEventFD, buffer->bytes, buffer->length);
        if (written == (ssize_t)buffer->length) {
            traceEmittedEvents++;
        } else {
            traceIncrementDroppedLocked();
        }
        os_unfair_lock_unlock(&traceLock);
    }

    static const char *traceBoundedCString(const char *value, size_t limit) {
        if (value == NULL) {
            return NULL;
        }
        if (strnlen(value, limit + 1) > limit) {
            atomic_fetch_add(&traceTruncatedValues, 1);
            return NULL;
        }
        return value;
    }

    static const char *traceString(NSString *value, char *buffer, size_t capacity) {
        if (value == nil || capacity == 0) {
            return NULL;
        }
        CFIndex maximum = CFStringGetMaximumSizeForEncoding(
            CFStringGetLength((CFStringRef)value),
            kCFStringEncodingUTF8
        ) + 1;
        if (maximum <= 0 || maximum > (CFIndex)capacity) {
            atomic_fetch_add(&traceTruncatedValues, 1);
            return NULL;
        }
        if (!CFStringGetCString((CFStringRef)value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8)) {
            atomic_fetch_add(&traceTruncatedValues, 1);
            return NULL;
        }
        return buffer;
    }

    static bool traceSameImage(const char *candidate) {
        char resolved[4096];
        if (candidate == NULL || realpath(candidate, resolved) == NULL) {
            return false;
        }
        return strcmp(resolved, traceExecutablePath) == 0;
    }

    static void traceCaller(
        char *image, size_t imageCapacity,
        char *symbol, size_t symbolCapacity,
        uint64_t *offset,
        bool *found
    ) {
        *found = false;
        image[0] = '\0';
        symbol[0] = '\0';
        *offset = 0;
        void *frames[32];
        int count = backtrace(frames, 32);
        for (int index = 1; index < count; index++) {
            Dl_info info = {0};
            if (dladdr(frames[index], &info) == 0 || !traceSameImage(info.dli_fname)) {
                continue;
            }
            const char *boundedImage = traceBoundedCString(info.dli_fname, imageCapacity - 1);
            const char *boundedSymbol = traceBoundedCString(info.dli_sname, symbolCapacity - 1);
            if (boundedImage == NULL) {
                return;
            }
            snprintf(image, imageCapacity, "%s", boundedImage);
            if (boundedSymbol != NULL) {
                snprintf(symbol, symbolCapacity, "%s", boundedSymbol);
            }
            if (info.dli_saddr != NULL) {
                *offset = (uint64_t)((uintptr_t)frames[index] - (uintptr_t)info.dli_saddr);
            }
            *found = true;
            return;
        }
    }

    static const char *traceReceiverClass(id receiver, bool *isClass) {
        if (receiver == nil) {
            return NULL;
        }
        *isClass = object_isClass(receiver);
        Class cls = *isClass ? (Class)receiver : object_getClass(receiver);
        return traceBoundedCString(class_getName(cls), 1023);
    }

    static void traceCallee(
        id receiver,
        SEL selector,
        char *image,
        size_t imageCapacity,
        char *symbol,
        size_t symbolCapacity,
        bool *found
    ) {
        *found = false;
        image[0] = '\0';
        symbol[0] = '\0';
        if (receiver == nil || selector == NULL) {
            return;
        }
        Method method = class_getInstanceMethod(object_getClass(receiver), selector);
        if (method == NULL) {
            return;
        }
        IMP implementation = method_getImplementation(method);
        const void *implementationAddress = (const void *)(uintptr_t)implementation;
    #if __has_feature(ptrauth_calls)
        implementationAddress = ptrauth_strip(implementationAddress, ptrauth_key_function_pointer);
    #endif
        Dl_info info = {0};
        if (implementation == NULL || dladdr(implementationAddress, &info) == 0) {
            return;
        }
        const void *symbolAddress = info.dli_saddr;
    #if __has_feature(ptrauth_calls)
        symbolAddress = ptrauth_strip(symbolAddress, ptrauth_key_function_pointer);
    #endif
        if (symbolAddress != implementationAddress) {
            return;
        }
        const char *boundedImage = traceBoundedCString(info.dli_fname, imageCapacity - 1);
        const char *boundedSymbol = traceBoundedCString(info.dli_sname, symbolCapacity - 1);
        if (boundedImage == NULL) {
            return;
        }
        snprintf(image, imageCapacity, "%s", boundedImage);
        if (boundedSymbol != NULL) {
            snprintf(symbol, symbolCapacity, "%s", boundedSymbol);
        }
        *found = true;
    }

    static void traceRecord(
        const char *api,
        const char *phase,
        NSString *nameValue,
        bool result,
        id receiver,
        SEL selector,
        bool dispatchUncertain
    ) {
        if (atomic_load(&traceCaptureState) != 0
            || traceEventFD < 0 || getpid() != traceProcessID || traceDepth != 0) {
            return;
        }
        traceDepth++;
        char name[1025];
        const char *nameString = traceString(nameValue, name, sizeof(name));
        bool receiverIsClass = false;
        const char *receiverClass = traceReceiverClass(receiver, &receiverIsClass);
        char callerImage[4096];
        char callerSymbol[1025];
        uint64_t callerOffset = 0;
        bool hasCaller = false;
        traceCaller(
            callerImage, sizeof(callerImage),
            callerSymbol, sizeof(callerSymbol),
            &callerOffset, &hasCaller
        );
        char calleeImage[4096];
        char calleeSymbol[1025];
        bool hasCallee = false;
        if (!dispatchUncertain) {
            traceCallee(
                receiver, selector,
                calleeImage, sizeof(calleeImage),
                calleeSymbol, sizeof(calleeSymbol),
                &hasCallee
            );
        }

        TraceBuffer buffer = {.length = 0, .valid = true};
        traceAppendCString(&buffer, "{\"api\":");
        traceAppendJSON(&buffer, api);
        traceAppendCString(&buffer, ",\"phase\":");
        traceAppendJSON(&buffer, phase);
        if (nameString != NULL) {
            traceAppendCString(&buffer, ",\"name\":");
            traceAppendJSON(&buffer, nameString);
        }
        traceAppendCString(&buffer, result ? ",\"result\":true" : ",\"result\":false");
        if (dispatchUncertain) traceAppendCString(&buffer, ",\"dispatchUncertain\":true");
        if (receiverClass != NULL) {
            traceAppendCString(&buffer, ",\"receiverClass\":");
            traceAppendJSON(&buffer, receiverClass);
            traceAppendCString(
                &buffer,
                receiverIsClass ? ",\"receiverIsClass\":true" : ",\"receiverIsClass\":false"
            );
        }
        if (hasCaller) {
            traceAppendCString(&buffer, ",\"callerImage\":");
            traceAppendJSON(&buffer, callerImage);
            if (callerSymbol[0] != '\0') {
                traceAppendCString(&buffer, ",\"callerSymbol\":");
                traceAppendJSON(&buffer, callerSymbol);
            }
            traceAppendCString(&buffer, ",\"callerOffset\":");
            traceAppendUnsigned(&buffer, callerOffset);
        }
        if (hasCallee) {
            traceAppendCString(&buffer, ",\"calleeImage\":");
            traceAppendJSON(&buffer, calleeImage);
            if (calleeSymbol[0] != '\0') {
                traceAppendCString(&buffer, ",\"calleeSymbol\":");
                traceAppendJSON(&buffer, calleeSymbol);
            }
        }
        traceAppendCString(&buffer, "}");
        traceWriteEvent(&buffer);
        traceDepth--;
    }

    Class cartograph_NSClassFromString(NSString *name) {
        Class result = NSClassFromString(name);
        traceRecord("NSClassFromString", "lookup", name, result != Nil, nil, NULL, false);
        return result;
    }

    SEL cartograph_NSSelectorFromString(NSString *name) {
        SEL result = NSSelectorFromString(name);
        traceRecord("NSSelectorFromString", "lookup", name, result != NULL, nil, NULL, false);
        return result;
    }

    Protocol *cartograph_NSProtocolFromString(NSString *name) {
        Protocol *result = NSProtocolFromString(name);
        traceRecord("NSProtocolFromString", "lookup", name, result != nil, nil, NULL, false);
        return result;
    }

    __attribute__((noreturn))
    void cartograph_exit(int code) {
        if (getpid() == traceProcessID && traceStatusFD >= 0) {
            atomic_store(&traceExitMarker, ((uint32_t)code & 0xff) + 1);
        }
        exit(code);
    }

    #define DYLD_INTERPOSE(_replacement, _replacee)                                      \
        __attribute__((used)) static struct {                                             \
            const void *replacement;                                                      \
            const void *replacee;                                                         \
        } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {       \
            (const void *)(uintptr_t)&_replacement, (const void *)(uintptr_t)&_replacee    \
        };

    DYLD_INTERPOSE(cartograph_NSClassFromString, NSClassFromString)
    DYLD_INTERPOSE(cartograph_NSSelectorFromString, NSSelectorFromString)
    DYLD_INTERPOSE(cartograph_NSProtocolFromString, NSProtocolFromString)
    DYLD_INTERPOSE(cartograph_exit, exit)

    typedef id (*TracePerform0)(id, SEL, SEL);
    typedef id (*TracePerform1)(id, SEL, SEL, id);
    typedef id (*TracePerform2)(id, SEL, SEL, id, id);
    typedef void (*TraceNotificationRegistration)(id, SEL, id, SEL, NSNotificationName, id);

    static IMP traceInstancePerform0;
    static IMP traceInstancePerform1;
    static IMP traceInstancePerform2;
    static IMP traceClassPerform0;
    static IMP traceClassPerform1;
    static IMP traceClassPerform2;
    static IMP traceNotificationRegistration;

    typedef struct { Class cls; IMP implementation; } TraceDispatchIdentity;

    static TraceDispatchIdentity traceDispatchIdentity(id receiver, SEL selector) {
        TraceDispatchIdentity identity = {.cls = Nil, .implementation = NULL};
        if (atomic_load(&traceCaptureState) != 0 || getpid() != traceProcessID) return identity;
        identity.cls = object_getClass(receiver);
        // method list를 읽어 진단을 위한 조회가 dynamic method resolution을 실행하지 않게 한다.
        for (Class cls = identity.cls; cls != Nil && identity.implementation == NULL; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned int index = 0; index < count; index++) {
                if (method_getName(methods[index]) == selector) {
                    identity.implementation = method_getImplementation(methods[index]);
                    break;
                }
            }
            free(methods);
        }
        return identity;
    }

    static bool traceDispatchUncertain(TraceDispatchIdentity before, id receiver, SEL selector) {
        TraceDispatchIdentity after = traceDispatchIdentity(receiver, selector);
        return before.cls != after.cls || before.implementation == NULL || after.implementation == NULL
            || before.implementation != after.implementation;
    }

    static id traceInstancePerformSelector0(id receiver, SEL command, SEL selector) {
        TraceDispatchIdentity before = traceDispatchIdentity(receiver, selector);
        id result = ((TracePerform0)traceInstancePerform0)(receiver, command, selector);
        traceRecord(
            "NSObject.performSelector", "invocation-returned",
            NSStringFromSelector(selector), true, receiver, selector, traceDispatchUncertain(before, receiver, selector)
        );
        return result;
    }

    static id traceInstancePerformSelector1(id receiver, SEL command, SEL selector, id object) {
        TraceDispatchIdentity before = traceDispatchIdentity(receiver, selector);
        id result = ((TracePerform1)traceInstancePerform1)(receiver, command, selector, object);
        traceRecord(
            "NSObject.performSelector:withObject", "invocation-returned",
            NSStringFromSelector(selector), true, receiver, selector, traceDispatchUncertain(before, receiver, selector)
        );
        return result;
    }

    static id traceInstancePerformSelector2(id receiver, SEL command, SEL selector, id first, id second) {
        TraceDispatchIdentity before = traceDispatchIdentity(receiver, selector);
        id result = ((TracePerform2)traceInstancePerform2)(receiver, command, selector, first, second);
        traceRecord(
            "NSObject.performSelector:withObject:withObject", "invocation-returned",
            NSStringFromSelector(selector), true, receiver, selector, traceDispatchUncertain(before, receiver, selector)
        );
        return result;
    }

    static id traceClassPerformSelector0(id receiver, SEL command, SEL selector) {
        TraceDispatchIdentity before = traceDispatchIdentity(receiver, selector);
        id result = ((TracePerform0)traceClassPerform0)(receiver, command, selector);
        traceRecord(
            "NSObject.performSelector", "invocation-returned",
            NSStringFromSelector(selector), true, receiver, selector, traceDispatchUncertain(before, receiver, selector)
        );
        return result;
    }

    static id traceClassPerformSelector1(id receiver, SEL command, SEL selector, id object) {
        TraceDispatchIdentity before = traceDispatchIdentity(receiver, selector);
        id result = ((TracePerform1)traceClassPerform1)(receiver, command, selector, object);
        traceRecord(
            "NSObject.performSelector:withObject", "invocation-returned",
            NSStringFromSelector(selector), true, receiver, selector, traceDispatchUncertain(before, receiver, selector)
        );
        return result;
    }

    static id traceClassPerformSelector2(id receiver, SEL command, SEL selector, id first, id second) {
        TraceDispatchIdentity before = traceDispatchIdentity(receiver, selector);
        id result = ((TracePerform2)traceClassPerform2)(receiver, command, selector, first, second);
        traceRecord(
            "NSObject.performSelector:withObject:withObject", "invocation-returned",
            NSStringFromSelector(selector), true, receiver, selector, traceDispatchUncertain(before, receiver, selector)
        );
        return result;
    }

    static void traceAddObserver(
        id center,
        SEL command,
        id observer,
        SEL selector,
        NSNotificationName name,
        id object
    ) {
        TraceDispatchIdentity before = traceDispatchIdentity(observer, selector);
        ((TraceNotificationRegistration)traceNotificationRegistration)(
            center, command, observer, selector, name, object
        );
        traceRecord(
            "NotificationCenter.addObserver", "registration",
            NSStringFromSelector(selector), true, observer, selector, traceDispatchUncertain(before, observer, selector)
        );
    }

    static bool traceReplaceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
        Method method = class_getInstanceMethod(cls, selector);
        if (method == NULL) {
            return false;
        }
        *original = method_setImplementation(method, replacement);
        return *original != NULL;
    }

    static void traceResolveExecutablePath(void) {
        uint32_t size = sizeof(traceExecutablePath);
        char unresolved[4096];
        if (_NSGetExecutablePath(unresolved, &size) == 0
            && realpath(unresolved, traceExecutablePath) != NULL) {
            return;
        }
        traceExecutablePath[0] = '\0';
    }

    static void traceFinish(void);

    static uint64_t traceElapsedNanoseconds(void) {
        mach_timebase_info_data_t timebase;
        if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 0;
        return (mach_absolute_time() - traceStartedAt) * timebase.numer / timebase.denom;
    }

    static bool traceSealRequested(void) {
        int request = open(traceSealRequestPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (request < 0) return false;
        unsigned char bytes[57];
        ssize_t count = tracePrivateRegularFile(request) ? read(request, bytes, sizeof(bytes)) : -1;
        close(request);
        if (count != 56 || memcmp(bytes, "CTREQ001", 8) != 0
            || memcmp(bytes + 16, traceSealNonce, 32) != 0) return false;
        uint32_t version, pid;
        uint64_t requestedMilliseconds;
        memcpy(&version, bytes + 8, 4);
        memcpy(&pid, bytes + 12, 4);
        memcpy(&requestedMilliseconds, bytes + 48, 8);
        return version == 1 && pid == (uint32_t)traceProcessID
            && requestedMilliseconds > 0 && requestedMilliseconds <= 3600000
            && traceElapsedNanoseconds() >= requestedMilliseconds * 1000000;
    }

    static bool tracePublishSeal(void) {
        char pending[4104];
        int length = snprintf(pending, sizeof(pending), "%s.pending", traceSealAckPath);
        if (length < 0 || (size_t)length >= sizeof(pending)) return false;
        int ack = open(pending, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR);
        if (ack < 0) return false;
        unsigned char bytes[88] = {0};
        memcpy(bytes, "CTSEAL01", 8);
        traceStore32(bytes, 8, 1);
        traceStore32(bytes, 12, (uint32_t)traceProcessID);
        memcpy(bytes + 16, traceSealNonce, 32);
        traceStore64(bytes, 48, traceEmittedEvents);
        traceStore64(bytes, 56, traceDroppedEvents);
        traceStore64(bytes, 64, atomic_load(&traceTruncatedValues));
        traceStore32(bytes, 72, traceHookMask);
        traceStore32(bytes, 76, 1);
        traceStore64(bytes, 80, traceElapsedNanoseconds());
        bool written = write(ack, bytes, sizeof(bytes)) == (ssize_t)sizeof(bytes) && fsync(ack) == 0;
        close(ack);
        // 완전히 쓴 파일만 공개하고 기존 ack를 덮어쓰지 않는다.
        bool published = written && link(pending, traceSealAckPath) == 0;
        unlink(pending);
        return published;
    }

    static void *traceSealWorker(void *unused) {
        (void)unused;
        while (getpid() == traceProcessID && atomic_load(&traceCaptureState) == 0) {
            if (!traceSealRequested()) { usleep(10000); continue; }
            os_unfair_lock_lock(&traceLock);
            if (atomic_load(&traceCaptureState) == 0 && traceEventFD >= 0) {
                // 기록과 봉인은 같은 lock에서 순서가 정해진다. 늦은 반환은 구간 밖이다.
                atomic_store(&traceCaptureState, 1);
                if (fsync(traceEventFD) == 0) (void)tracePublishSeal();
                atomic_store(&traceCaptureState, 2);
            }
            os_unfair_lock_unlock(&traceLock);
            break;
        }
        return NULL;
    }

    static void traceStartSealWorker(void) {
        const char *request = getenv("CARTOGRAPH_RUNTIME_TRACE_SEAL_REQUEST");
        const char *ack = getenv("CARTOGRAPH_RUNTIME_TRACE_SEAL_ACK");
        const char *nonce = getenv("CARTOGRAPH_RUNTIME_TRACE_SEAL_NONCE");
        if (request == NULL || ack == NULL || nonce == NULL || strlen(nonce) != 32
            || request[0] != '/' || ack[0] != '/'
            || strnlen(request, sizeof(traceSealRequestPath)) >= sizeof(traceSealRequestPath)
            || strnlen(ack, sizeof(traceSealAckPath)) >= sizeof(traceSealAckPath)) return;
        for (size_t index = 0; index < 32; index++) {
            if (!((nonce[index] >= '0' && nonce[index] <= '9') || (nonce[index] >= 'a' && nonce[index] <= 'f'))) return;
        }
        memcpy(traceSealNonce, nonce, 33);
        snprintf(traceSealRequestPath, sizeof(traceSealRequestPath), "%s", request);
        snprintf(traceSealAckPath, sizeof(traceSealAckPath), "%s", ack);
        pthread_t worker;
        if (pthread_create(&worker, NULL, traceSealWorker, NULL) == 0) pthread_detach(worker);
    }

    __attribute__((constructor))
    static void traceInstall(void) {
        const char *statusPath = getenv("CARTOGRAPH_RUNTIME_TRACE_STATUS");
        const char *eventPath = getenv("CARTOGRAPH_RUNTIME_TRACE_FILE");
        if (statusPath == NULL || eventPath == NULL || statusPath[0] == '\0' || eventPath[0] == '\0') {
            return;
        }
        traceStatusFD = open(
            statusPath,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        );
        if (traceStatusFD < 0 || !tracePrivateRegularFile(traceStatusFD)) {
            if (traceStatusFD >= 0) close(traceStatusFD);
            traceStatusFD = -1;
            return;
        }
        traceEventFD = open(
            eventPath,
            O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        );
        if (traceEventFD < 0 || !tracePrivateRegularFile(traceEventFD)) {
            if (traceEventFD >= 0) close(traceEventFD);
            close(traceStatusFD);
            traceEventFD = -1;
            traceStatusFD = -1;
            return;
        }
        traceProcessID = getpid();
        traceStartedAt = mach_absolute_time();
        traceResolveExecutablePath();

        Class objectClass = [NSObject class];
        Class objectMetaClass = object_getClass(objectClass);
        if (traceReplaceMethod(
            objectClass, @selector(performSelector:),
            (IMP)traceInstancePerformSelector0, &traceInstancePerform0
        )) traceHookMask |= 1 << 0;
        if (traceReplaceMethod(
            objectClass, @selector(performSelector:withObject:),
            (IMP)traceInstancePerformSelector1, &traceInstancePerform1
        )) traceHookMask |= 1 << 1;
        if (traceReplaceMethod(
            objectClass, @selector(performSelector:withObject:withObject:),
            (IMP)traceInstancePerformSelector2, &traceInstancePerform2
        )) traceHookMask |= 1 << 2;
        if (traceReplaceMethod(
            objectMetaClass, @selector(performSelector:),
            (IMP)traceClassPerformSelector0, &traceClassPerform0
        )) traceHookMask |= 1 << 3;
        if (traceReplaceMethod(
            objectMetaClass, @selector(performSelector:withObject:),
            (IMP)traceClassPerformSelector1, &traceClassPerform1
        )) traceHookMask |= 1 << 4;
        if (traceReplaceMethod(
            objectMetaClass, @selector(performSelector:withObject:withObject:),
            (IMP)traceClassPerformSelector2, &traceClassPerform2
        )) traceHookMask |= 1 << 5;
        if (traceReplaceMethod(
            [NSNotificationCenter class], @selector(addObserver:selector:name:object:),
            (IMP)traceAddObserver, &traceNotificationRegistration
        )) traceHookMask |= 1 << 6;

        if (atexit(traceFinish) != 0 || !traceWriteStatus(true)) {
            close(traceEventFD);
            close(traceStatusFD);
            traceEventFD = -1;
            traceStatusFD = -1;
            return;
        }
        traceStartSealWorker();
    }

    static void traceFinish(void) {
        if (getpid() != traceProcessID || traceStatusFD < 0) {
            return;
        }
        os_unfair_lock_lock(&traceLock);
        atomic_store(&traceCaptureState, 2);
        if (traceEventFD >= 0) {
            if (fsync(traceEventFD) == 0) {
                traceMarkComplete();
            }
            close(traceEventFD);
            traceEventFD = -1;
        }
        close(traceStatusFD);
        traceStatusFD = -1;
        os_unfair_lock_unlock(&traceLock);
    }
    """#
}
